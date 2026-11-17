# Pinball Arena

A two-player pinball game that runs in a web browser. A person plays the flippers. Their
Softmax cogent (AI agent) writes BASIC programs that build the table and define its rules.
With no cogent connected, the bundled house program runs the table.

![The page: the table, the side panel and the cogent panel](docs/images/pinball-arena.png)

The game is a standalone fork of [Polyworld](https://github.com/softmax-universe/polyworld)
(Nim, compiled to WebAssembly). It is built and plays locally. It is **not deployed**, and the
cogent connection has only been tested against fakes; see [What is not verified](#what-is-not-verified).

## Start here

- **Design:** [`docs/designs/pinball-arena-2026-11-16.html`](docs/designs/pinball-arena-2026-11-16.html)
  (Final). It decides how the game looks, feels and behaves. Appendix I lists what is settled.
- **How the code is put together:** [`docs/architecture.md`](docs/architecture.md), including
  where the build departs from the design.
- **The BASIC interface for table programs:** [`src/pinball/script/README.md`](src/pinball/script/README.md)
  (reference) and [`web/guide/arena-basic.md`](web/guide/arena-basic.md) (the guide the page
  sends to the cogent). [`players/house.bas`](players/house.bas) is the full example.
- **The server part:** [`server/README.md`](server/README.md).
- **Assets and their licences:** [`assets/LICENSES.md`](assets/LICENSES.md).

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

"Watch demo" hands the flippers to the bundled demo program.

Native build, for development:

```sh
nim r src/pinball/pinball.nim             # a window with the table
nim r src/pinball/pinball.nim --demo      # the demo program plays the flippers
nim r src/pinball/pinball.nim --demo --screenshot shot.png --ticks 4200 --size 620x1000
```

## Try a table program without a browser

```sh
nim r src/pinball/headless.nim                               # house table, demo flipper
nim r src/pinball/headless.nim --arena my_table.bas          # your own table program
nim r src/pinball/headless.nim --record episode.replay
nim r src/pinball/headless.nim --replay episode.replay       # verify a recording
```

It plays one Episode, prints the Episode summary (the same JSON the page reports to the
cogent), and checks that the replay re-simulates to the same state on every tick. It exits
with 1 if a program does not compile or the replay does not match.

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
web/                    the page (plain JavaScript modules), fonts, the guide
server/, api/           the Node server part and the Vercel function
assets/                 sounds and the licence record
tests/, web/test/, server/test/
```

## What is not verified

- **A real cogent.** Sign-in, the WebSocket pass-through, and `policy.create` /
  `policy.update` / `surface.event` with a real workspace have never run. The page's client
  and session are tested against a fake socket built from the AIDE 1.0.0 contract files.
- **Vercel.** Nothing is deployed. `vercel.json` and `api/cogent.js` follow Vercel's documented
  conventions, but the WebSocket pass-through there is untested, and `web/game/` is
  git-ignored, so a deployment must include a built bundle.
- **Softmax side** (Appendix H of the design): the site's hostname is not on the allowed
  cogent sites list, and nobody has confirmed that running the program inside the BASIC
  virtual machine satisfies the contract's "never runs it in the page" rule.
- **Sound.** The 32 cues were chosen by file name and duration and have not been listened to.
  Levels are guesses.
- **Gamepad.** It compiles on both targets and has never been tried with a pad.
- **Native and browser give the same simulation.** This follows from the design (integer
  maths only) and is not covered by a test.
