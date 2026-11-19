# The Coworld package: a Softmax-hosted preview

**The Softmax-hosted Coworld `pinball-arena` is a preview of the game, not the game.** The
real game runs in a browser, where a person plays the flippers and their cogent builds the
table. A Coworld episode has no browser and no person, so the hosted version is cut down to
what fits: one BASIC program plays the flippers on the built-in house table.

How to take part is in [`play.md`](../play.md). This page is for people who change or
re-upload the package.

## What is registered

| | |
| --- | --- |
| Coworld | `pinball-arena`, version 0.1.1, `COWORLD_ID`, public |
| League | `LEAGUE_ID` |
| Player runtime | `game-hosted`: a policy is a file that the game runs |
| Seats | 1 (the Flipper player) |
| Bundled player | `demo`, [`players/demo_flipper.bas`](../players/demo_flipper.bas). The default, and the certification fixture |
| Variant | `house`: the built-in house table |

Every upload gets a new `cow_...` id. `GAME_SCOPE` in [`web/js/main.js`](../web/js/main.js)
holds the id and the league id as the page's AIDE scope, so change it when you upload again.

## Files

| File | What it is |
| --- | --- |
| [`server.py`](server.py) | The game server of the Coworld contract. It runs one Episode with the command-line runner and writes the seat log, the replay and the results |
| [`viewer.html`](viewer.html) | The page of `/client/global`, `/client/player` and `/client/replay`. It draws the replay as plain shapes |
| [`../Dockerfile`](../Dockerfile) | One linux/amd64 image: `src/pinball/headless.nim` compiled, plus Python and `websockets` |
| [`../compose.yaml`](../compose.yaml) | Tells `coworld build` how to build the image |
| [`../coworld_manifest_template.json`](../coworld_manifest_template.json) | The manifest: schemas, the player and viewer protocols, the readme shown on Softmax, the bundled player, the certification fixture |

## How an episode runs

1. The runner stages the policy file and starts the image with the config, the seats
   document (`COGAME_PLAYER_SEATS_URI`) and the output locations.
2. `server.py` runs `/app/headless --flipper <file> --preview <path>`. That plays a whole
   Episode in well under a second.
3. It writes the seat log, then the replay (the preview with the results), then the results.
   The results file is the completion marker, so it is last. The server then stays up until
   the runner stops the container: version 0.1.0 exited when it was done, and a hosted
   runner that had not yet seen it healthy then waited for it until its timeout.
4. A file that does not compile gets a player failure (`COGAME_PLAYER_FAILURE_URI`) for slot
   0 instead of results.

`/player` is served because the contract asks for it. Nothing connects to it to play.

The replay is the output of `headless --preview`: the pieces as they stand when the first
ball is served, and ten frames a second of `[tick, score, ball number, left flipper angle,
right flipper angle, [ball x, y, ...]]`. A table program could change the pieces later; the
house table does not.

Limits and isolation come from the BASIC virtual machine, not from the container: 50,000
instructions a run, 2 MiB of memory, and no file, network or clock access
([`docs/cogent/basic.md`](../docs/cogent/basic.md)). `server.py` adds none of its own.

## Build, check and upload

`coworld build` writes the commit of `origin` into the manifest, so commit and push first.

```sh
export DOCKER_DEFAULT_PLATFORM=linux/amd64
uvx --python 3.12 coworld@0.1.69 build --version 0.1.2
uvx --python 3.12 coworld@0.1.69 run-episode dist/coworld_manifest.json
uvx --python 3.12 coworld@0.1.69 run-episode dist/coworld_manifest.json --player-file 0=my_flipper.bas
uvx --python 3.12 coworld@0.1.69 certify dist/coworld_manifest.json
uvx --python 3.12 coworld@0.1.69 upload-coworld dist/coworld_manifest.json --visibility public --wait-certification
```

The demo player scores 60,420. If `--wait-certification` stops with HTTP 503, the upload
has still happened: read the result with `coworld status cow_...`.

`server.py` runs without Docker too, with `PINBALL_HEADLESS` set to a native build of the
runner and the `COGAME_*` variables set to `file://` paths.

## Not done

- The readme shown on Softmax is text inside the manifest, because the repository is
  private. The platform's `play.md` therefore has no link to a game guide. When the
  repository is public, make `game.docs.readme` a `uri` to [`play.md`](../play.md).
- The Arena seat is not part of the hosted version.
- No tests cover `server.py`. It was checked by local episodes (a good file, a broken file,
  the default player) and by certification.
