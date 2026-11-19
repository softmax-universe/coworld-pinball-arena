"""The Coworld game server of Pinball Arena: a preview of the game on Softmax.

The real game runs in a browser at https://pinball-arena.vercel.app, where a
person plays the flippers and their cogent builds the table. This server is
the Softmax-hosted preview: one seat, the Flipper seat, played by a BASIC
program on the bundled house table, with nobody watching live.

An episode here is one run of the command-line runner (`/app/headless`, built
from src/pinball/headless.nim). The server stages the seat's BASIC file, runs
the Episode as fast as the machine goes, and writes the score.

It implements the Coworld game contract for game-hosted players (roles/GAME.md
and PLAYER_RUNTIMES.md in the coworld package): config from COGAME_CONFIG_URI,
the seat file and log from COGAME_PLAYER_SEATS_URI, /healthz, /player,
/global, the /client/* pages, the replay to COGAME_SAVE_REPLAY_URI, results to
COGAME_RESULTS_URI, a player failure to COGAME_PLAYER_FAILURE_URI, and replay
mode when COGAME_LOAD_REPLAY_URI is set.

The server is synchronous: `websockets.sync` runs one thread per connection
and answers WebSocket Ping frames itself.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import tempfile
import threading
from http import HTTPStatus
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse
from urllib.request import Request as UrlRequest
from urllib.request import urlopen

from websockets.exceptions import ConnectionClosed
from websockets.http11 import Request, Response
from websockets.sync.server import Server, ServerConnection, serve

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
logger = logging.getLogger("pinball-arena.game")
# websockets logs every plain HTTP response (such as /healthz) as "connection rejected (200 OK)".
logging.getLogger("websockets.server").setLevel(logging.WARNING)

GAME_HOST = os.environ.get("COGAME_HOST", "0.0.0.0")
GAME_PORT = int(os.environ.get("COGAME_PORT", "8080"))
HEADLESS = os.environ.get("PINBALL_HEADLESS", "/app/headless")
# A real Episode takes a few seconds. This only stops a runner that hangs.
EPISODE_TIMEOUT_SECONDS = 600
# Some CDNs reject urllib's default User-Agent, so hosted artifact requests set their own.
HTTP_USER_AGENT = "coworld-pinball-arena/0.1"
VIEWER_PAGE = (Path(__file__).parent / "viewer.html").read_text()
# Browser page path -> the WebSocket route that page reads from.
CLIENT_PAGES = {"/client/player": "/player", "/client/global": "/global", "/client/replay": "/replay"}


def read_uri(uri: str) -> bytes:
    parsed = urlparse(uri)
    if parsed.scheme in ("http", "https"):
        with urlopen(UrlRequest(uri, headers={"User-Agent": HTTP_USER_AGENT}), timeout=30) as response:
            return response.read()
    return Path(unquote(parsed.path)).read_bytes()


def write_uri(uri: str, data: bytes, content_type: str, method_env_var: str = "") -> None:
    parsed = urlparse(uri)
    if parsed.scheme in ("http", "https"):
        request = UrlRequest(uri, data=data, method=os.environ.get(method_env_var, "PUT").upper())
        request.add_header("Content-Type", content_type)
        request.add_header("User-Agent", HTTP_USER_AGENT)
        with urlopen(request, timeout=60):
            return
    path = Path(unquote(parsed.path))
    path.parent.mkdir(parents=True, exist_ok=True)
    # Written beside the target and renamed, so a reader never sees half a file.
    partial = path.with_name(path.name + ".partial")
    partial.write_bytes(data)
    partial.rename(path)


def write_json(uri: str, payload: dict, method_env_var: str = "") -> None:
    write_uri(uri, json.dumps(payload).encode(), "application/json", method_env_var)


REPLAY_MODE = "COGAME_LOAD_REPLAY_URI" in os.environ
if REPLAY_MODE:
    REPLAY = json.loads(read_uri(os.environ["COGAME_LOAD_REPLAY_URI"]))
    CONFIG = {"tokens": [], "players": []}
else:
    REPLAY = {}
    CONFIG = json.loads(read_uri(os.environ["COGAME_CONFIG_URI"]))

TOKENS = CONFIG["tokens"]
PLAYER_NAMES = [player["name"] for player in CONFIG["players"]]

# What the global viewer shows: "running", then the replay of the finished Episode.
episode: dict = {"type": "state", "status": "running", "player_names": PLAYER_NAMES}
episode_done = threading.Event()
stopping = threading.Event()


def handle_http(connection: ServerConnection, request: Request) -> Response | None:
    """Answer plain HTTP routes; returning None lets the WebSocket handshake continue."""
    path = urlparse(request.path).path
    if path == "/healthz":
        return connection.respond(HTTPStatus.OK, "ok\n")
    if path in CLIENT_PAGES:
        response = connection.respond(HTTPStatus.OK, VIEWER_PAGE.replace("{socket_path}", CLIENT_PAGES[path]))
        response.headers["Content-Type"] = "text/html; charset=utf-8"
        return response
    if path == "/player" and player_slot(request) is None:
        return connection.respond(HTTPStatus.FORBIDDEN, "unknown slot or wrong token\n")
    if path in ("/player", "/global", "/replay"):
        return None
    return connection.respond(HTTPStatus.NOT_FOUND, "not found\n")


def player_slot(request: Request) -> int | None:
    """Return the slot a /player request authenticates as, or None when its slot or token is wrong."""
    query = parse_qs(urlparse(request.path).query)
    slot_text = query.get("slot", [""])[0]
    token = query.get("token", [""])[0]
    if not slot_text.isdigit() or int(slot_text) >= len(TOKENS) or TOKENS[int(slot_text)] != token:
        return None
    return int(slot_text)


def handle_websocket(connection: ServerConnection) -> None:
    path = urlparse(connection.request.path).path
    try:
        if path == "/replay":
            connection.send(json.dumps({"type": "replay", **REPLAY}))
            stopping.wait()
        else:
            # The player is a file that the game runs, so /player has nothing to exchange:
            # like /global it only shows the Episode.
            connection.send(json.dumps(episode))
            while not episode_done.is_set() and not stopping.is_set():
                episode_done.wait(timeout=1.0)
            connection.send(json.dumps(episode))
    except ConnectionClosed:
        pass


def play_episode(flipper_file: Path) -> tuple[dict | None, dict, str]:
    """Runs one Episode on the house table with this Flipper program.

    Returns the Episode summary, the preview for the viewer, and what the runner wrote to
    standard error (a program failure is there). The summary is None when the program did not
    compile, which is the one way a player file can fail outright.
    """
    with tempfile.TemporaryDirectory() as scratch:
        preview_path = Path(scratch) / "preview.json"
        run = subprocess.run(
            [HEADLESS, "--flipper", str(flipper_file), "--preview", str(preview_path)],
            capture_output=True,
            text=True,
            timeout=EPISODE_TIMEOUT_SECONDS,
        )
        if run.returncode != 0:
            if '"stage": "compile"' in run.stderr:
                return None, {}, run.stderr
            raise RuntimeError(f"the episode runner failed with exit code {run.returncode}: {run.stderr[-2000:]}")
        return json.loads(run.stdout), json.loads(preview_path.read_text()), run.stderr


def seat_log(summary: dict | None, runner_errors: str) -> str:
    """The private log of the seat: how the Episode went for its program, and any failure."""
    if summary is None:
        return "The Flipper program did not compile, so no Episode was played.\n" + runner_errors
    lines = [
        f"score: {summary['score']}",
        f"end: {summary['endReason']}",
        "balls: " + ", ".join(f"{ball['seconds']} s" for ball in summary["balls"]),
    ]
    error = summary["flipper"]["scriptError"]
    if error is None:
        lines.append("The Flipper program ran to the end of the Episode without an error.")
    else:
        lines.append(f"The Flipper program stopped ({error['stage']}): {error['message']}")
        lines.append("From then on nobody worked the flippers. Its last printed lines:")
        lines.extend(error["output"])
    return "\n".join(lines) + "\n"


def finish_episode(server: Server) -> None:
    """Plays the Episode, then writes the seat log, the replay and the results, and stops the server."""
    seat = json.loads(read_uri(os.environ["COGAME_PLAYER_SEATS_URI"]))["seats"][0]
    summary, preview, runner_errors = play_episode(Path(unquote(urlparse(seat["file_uri"]).path)))
    write_uri(seat["log_uri"], seat_log(summary, runner_errors).encode(), "text/plain; charset=utf-8")

    if summary is None:
        logger.info("the Flipper program did not compile")
        failure = {"message": "The Flipper program of slot 0 did not compile.", "failed_policy_index": 0}
        write_json(os.environ["COGAME_PLAYER_FAILURE_URI"], failure)
        episode.update(status="failed", failure=failure)
    else:
        results = {
            "scores": [summary["score"]],
            "end_reason": summary["endReason"],
            "ball_seconds": [ball["seconds"] for ball in summary["balls"]],
            "flipper_error": summary["flipper"]["scriptError"] is not None,
        }
        logger.info("episode finished, score=%s", summary["score"])
        replay = {"player_names": PLAYER_NAMES, "results": results, **preview}
        write_json(os.environ["COGAME_SAVE_REPLAY_URI"], replay, "COGAME_SAVE_REPLAY_METHOD")
        # Results are the completion marker, so they are written last.
        write_json(os.environ["COGAME_RESULTS_URI"], results, "COGAME_RESULTS_METHOD")
        episode.update(status="done", **replay)
    episode_done.set()
    server.shutdown()


def main() -> None:
    with serve(handle_websocket, GAME_HOST, GAME_PORT, process_request=handle_http) as server:

        def stop(_signal_number: int, _frame: object) -> None:
            stopping.set()
            server.shutdown()

        # Python running as PID 1 in a container ignores SIGTERM unless a handler is installed.
        signal.signal(signal.SIGTERM, stop)
        if REPLAY_MODE:
            logger.info("serving a replay on port %d", GAME_PORT)
        else:
            logger.info("playing the episode; viewers on port %d", GAME_PORT)
            threading.Thread(target=finish_episode, args=(server,), daemon=True).start()
        server.serve_forever()


if __name__ == "__main__":
    main()
