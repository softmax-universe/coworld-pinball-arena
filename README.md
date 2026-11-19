# Pinball Arena

A two-player pinball game that runs in a web browser. A person plays the flippers. Their
Softmax cogent (AI agent) builds the table and makes its rules, by deploying BASIC programs
or by direct control. With no cogent connected, the bundled house program runs the table.
The cogent can play the flippers too, the same two ways.

![The illustrated playfield and cabinet console](docs/images/pinball-arena.png)

The game is a standalone fork of [Polyworld](https://github.com/softmax-universe/polyworld)
(Nim, compiled to WebAssembly). It is live at **https://pinball-arena.vercel.app** for signed-out
play. Nobody has signed in there yet, and the cogent connection has only been tested against
fakes; see [What is not verified](#what-is-not-verified).

> **If you are a cogent** who will build tables or play here, start with
> [`docs/cogent/README.md`](docs/cogent/README.md). It is the getting-started guide: what the
> game is, what you can send, where every fact is, and what to save in your own knowledge
> base. The rest of this page is for people who run and change the code.

The game is registered on Softmax as the Coworld `pinball-arena`. Softmax can also run an
episode with no browser: a BASIC program plays the flippers on the house table for a score.
[`play.md`](play.md) says how to submit one, and [`coworld/README.md`](coworld/README.md)
describes the package.

## The two seats

| Seat | Who holds it | Aim |
| --- | --- | --- |
| **Flipper player** | A person at the page, or the cogent | The highest score in the Episode |
| **Arena player** | A BASIC table program (the bundled `house` at first), with the cogent's direct control beside it | That the Flipper player has fun and gets better. It has no score and is not trying to win |

The Flipper player works the two flippers, the plunger and nudges. The Arena player builds
the table and makes every rule: nothing scores unless a rule says so. An Episode is a build
phase (10 seconds at most), then three balls, and at most 8 minutes of play.

## How the cogent reaches the game

The game runs in the browser, so there is no game server. Everything the cogent does goes
over its one AIDE 1.0.0 connection with the page: `policy.create` and `policy.update` deploy
a program for a seat, `policy.list` says which are deployed, `surface.act` carries a request to the game (run BASIC calls now, read
the table, manage programs, subscribe), and `surface.event` carries what the game tells the
cogent. The page puts nothing about the game into the chat.
[`docs/cogent/game-api.md`](docs/cogent/game-api.md) is the one reference for these messages.

## Where the documentation is

Each fact is written down once, in the place below.

| Topic | Where |
| --- | --- |
| Getting started as a cogent, and what to keep in a cogent's knowledge base | [`docs/cogent/README.md`](docs/cogent/README.md) |
| The messages between cogent and game (`policy.*`, `surface.*`), the state, the Episode summary | [`docs/cogent/game-api.md`](docs/cogent/game-api.md) |
| BASIC for both seats: how a program runs, the dialect, the view, constants, failure, limits | [`docs/cogent/basic.md`](docs/cogent/basic.md) |
| The Arena seat: the table, pieces, rules, examples, the house table | [`docs/cogent/arena.md`](docs/cogent/arena.md) |
| The Flipper seat: calls, mechanics, an example program | [`docs/cogent/flipper.md`](docs/cogent/flipper.md) |
| How the code is put together, the messages between the game and the page, and where the build departs from the design | [`docs/architecture.md`](docs/architecture.md) |
| The design (Final): how the game looks, feels and behaves. Appendix I lists what is settled | [`docs/designs/pinball-arena-2026-11-16.html`](docs/designs/pinball-arena-2026-11-16.html) |
| The script hosts, for people who change them | [`src/pinball/script/README.md`](src/pinball/script/README.md) |
| The server part: sign-in and the cogent's WebSocket | [`server/README.md`](server/README.md) |
| Running a Flipper program on Softmax with no browser: write, test, upload and submit | [`play.md`](play.md) |
| The Coworld package: what is registered, how an episode runs, how to upload again | [`coworld/README.md`](coworld/README.md) |
| Assets and their licences | [`assets/LICENSES.md`](assets/LICENSES.md) |
| Setting up, playing, testing and deploying | This page |

The full example programs are [`players/house.bas`](players/house.bas) and
[`players/demo_flipper.bas`](players/demo_flipper.bas).

## Set up

You need Nim 2.2.10 or newer, [nimby](https://github.com/treeform/nimby), Node 24, and for the
browser build an [emsdk](https://emscripten.org/docs/getting_started/downloads.html)
(built with Emscripten 6.0.12).

```sh
mkdir -p deps && cd deps && nimby sync ../nimby.lock && cd ..
```

This checks out the pinned Nim packages into `deps/` (git-ignored). `config.nims` adds them to
the compiler's path. There are no npm dependencies.

## Play

```sh
tools/build_web.sh        # builds web/game/pinball.{js,wasm,data}, about 10 s
npm run dev               # serves web/ on http://localhost:8080
```

`tools/build_web.sh` finds `emcc` on the path, or sources the emsdk at `$EMSDK`
(default `~/coding/tools/emsdk`). Signed-out play needs no server part: any static file
server over `web/` works.

Click the table to give it the keyboard.

| Action | Keyboard | Gamepad |
| --- | --- | --- |
| Left flipper | Z or Left Shift | Left trigger or bumper |
| Right flipper | / or Right Shift | Right trigger or bumper |
| Plunger | Space (hold to pull, release to fire) | Right stick down, then release |
| Nudge | X (left), . (right), Up | Left stick flick |

“Watch demo” hands the flippers to the bundled demo program. The **Cogent terminal**
below the scoreboard holds the chat. On phones, **Cogent**
opens the terminal and **Table** returns keyboard focus to the flippers.

The Music button cycles through Off, Space Echo, and Space Adventure. Music starts off on
page load. Both tracks loop beneath the table effects.

The table uses Orbital finishes, 29 recorded cabinet effects and five electronic program
effects. Game over rings a single low bell.

Native build, for development:

```sh
nim r src/pinball/pinball.nim             # a window with the table
nim r src/pinball/pinball.nim --demo      # the demo program plays the flippers
nim r src/pinball/pinball.nim --demo --screenshot shot.png --ticks 4200 --size 620x1000
```

## Deploy

The site is the Vercel project `pinball-arena`. Vercel cannot build the game, so a deployment
is made from a machine that has built it:

```sh
tools/build_web.sh
vercel deploy --prod
```

`.vercelignore` decides what is uploaded: `web/` (with the built `web/game/`), `api/`,
`server/`, `vercel.json` and `package.json`. The project has `COGENT_SECRET` and `SITE_ORIGIN`
set for production; see [`server/README.md`](server/README.md).

## Try a program without a browser

```sh
nim r src/pinball/headless.nim                               # house table, demo flipper
nim r src/pinball/headless.nim --arena my_table.bas          # your own table program
nim r src/pinball/headless.nim --flipper my_flipper.bas      # your own Flipper program
nim r src/pinball/headless.nim --record episode.replay
nim r src/pinball/headless.nim --replay episode.replay       # verify a recording
nim r src/pinball/headless.nim --frames frames.json          # a small picture of the Episode for a viewer
```

It plays one Episode, prints the Episode summary (the same JSON the page reports to the
cogent; its fields are in [`docs/cogent/game-api.md`](docs/cogent/game-api.md#episodesummary)), and checks that the replay re-simulates to the same state on every tick. It exits
with 1 if a program does not compile or the replay does not match. A program that fails
while running is printed to standard error, and the summary carries the error. A Flipper
program needs no `' @seat flipper` line here: `--flipper` says which seat it is for.

## Test

```sh
tools/test.sh
```

Runs every `tests/test_*.nim` and then the JavaScript tests (`npm test`). The Nim tests are
built with `-d:fixedChecks`, which turns a fixed-point overflow into a failure.

## Layout

```
src/pinball/sim/        the simulation: fixed-point, no floats, no drawing
src/pinball/script/     the BASIC hosts for the two seats
src/pinball/game.nim    the driver: Episodes, table programs, replay, summary
src/pinball/view/       drawing, sound, input, the bridge to the page
src/pinball/pinball.nim the windowed and browser entry point
src/pinball/headless.nim the command-line runner
src/polyworld/          engine modules kept from Polyworld
players/                house.bas and demo_flipper.bas, built into the game
web/                    the page (plain JavaScript modules), fonts
docs/cogent/            for a cogent: getting started, the game API, BASIC, both seats
docs/                   architecture, the design, the screenshot
server/, api/           the Node server part and the Vercel function
coworld/                the Coworld package: the game server for episodes that Softmax runs
Dockerfile, compose.yaml, coworld_manifest_template.json   the Coworld's image and manifest
play.md                 how to run a Flipper program on Softmax
assets/                 sounds and the licence record
tests/, web/test/, server/test/
```

## What is not verified

- **A real cogent.** Sign-in, the WebSocket pass-through, chat, `policy.create` /
  `policy.update` / `policy.list`, `surface.act` and `surface.event` with a real workspace have never run.
  The page's client and session are tested against a fake socket built from the AIDE 1.0.0
  contract files. The game API itself (programs for both seats, `run`, `state`, the game's
  messages) was tried against the real game in a browser, over a transport that has since
  been removed, and not yet through an AIDE connection.
- **The Coworld scope with a real workspace.** The page uses the AIDE scope
  `{scope: "coworld", coworld, league}` with the ids of the registered Coworld
  (`GAME_SCOPE` in `web/js/main.js`). No workspace has been asked to accept them yet.
- **Hosted episodes beyond certification.** The Coworld passed local and hosted
  certification with the demo player, and an example program was uploaded and submitted to
  the league. The league runs nothing until the Softmax team sets it up, so no submitted
  program has played a hosted episode yet. The game's page on softmax.com waits for review.
  `coworld/server.py` has no tests of its own.
- **`policy.list` on the relay.** The page answers it as the AIDE 1.0.0 contract defines it.
  The request was added to the contract on 2026-11-18, and no relay has sent it to the page yet.
- **That a cogent finds and uses the documentation.** The page sends the cogent no
  instructions, so it knows the game only if it has this repository and reads
  `docs/cogent/`. No cogent has done so yet.
- **How fast and how often the cogent can act.** `run` and `state` are answered within one
  frame of the page. How long a `surface.act` takes to arrive, and how many `surface.event`s
  the AIDE relay lets through, has not been measured.
- **The WebSocket pass-through on Vercel.** The deployed function answers the cogent routes,
  and refuses a WebSocket with no session (401) or a foreign origin (403). An accepted
  connection has never been made there, because nobody has signed in there yet.
- **Starting a workspace from the site.** The page creates a workspace for an account that
  has none and wakes a sleeping one. This follows the calls of Softmax's own client and is
  tested against a fake; it has not run against Softmax.
- **Softmax side** (Appendix H of the design): Softmax has put the site's hostname on its
  list of allowed cogent sites, but a sign-in has not been tried, and nobody has confirmed that running the program inside the BASIC
  virtual machine satisfies the contract's "never runs it in the page" rule.
- **Sound.** The 32 cues were chosen by file name and duration and have not been listened to.
  Levels are guesses.
- **Gamepad.** It compiles on both targets and has never been tried with a pad.
- **Native and browser give the same simulation.** This follows from the design (integer
  maths only) and is not covered by a test.
