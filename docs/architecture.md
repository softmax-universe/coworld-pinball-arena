# Architecture

How Pinball Arena is put together, and where the build departs from the
[design document](designs/pinball-arena-2026-11-16.html). The design decides what the game
is; this file describes the code as it stands.

## The layers

```
web page (web/)                 HTML side panel, chat panel, table programs, AIDE client
   |  JSON strings both ways (the bridge)
view (src/pinball/view/)        draws the table, plays sound, reads keys and gamepad
   |  reads game.table; calls tick, humanInput, receiveMessage, takeMessages
driver (src/pinball/game.nim)   Episodes, which program holds each seat, replay, summary
   |  loadScript / decide          |  apply(command) / step
script hosts (script/)          simulation (sim/)
```

Each layer only knows the one below it. The simulation knows nothing about BASIC, drawing or
the page.

## The simulation (`src/pinball/sim/`)

All state is one `Table` value, defined in `types.nim`. The other modules are behaviour over
`var Table`. There are two entry points, in `simulation.nim`:

- `apply(table, command)` carries out one `Command` from a player. Commands are the only
  input of the simulation.
- `step(table)` advances one tick (1/120 s), in this order: beam-ins, magnet forces, physics,
  track, component reactions, Episode bookkeeping, rules.

Rules that hold everywhere in `sim/`:

- **No floats.** Maths is `Fixed` (Q16.16, from fixxy) or integers, so the same commands on
  the same ticks give the same `stateHash` on every machine. `Fixed * Fixed` wraps above
  32767, so code never multiplies two lengths; tests are built with `-d:fixedChecks` to
  catch a wrap.
- **Units.** Millimetres, mm/s, degrees (0 is +x, clockwise on screen), ticks. `y` grows
  toward the player.
- **Events.** An event raised during the physics of a tick uses `emit` and the rules see it
  the same tick. An event raised by a command, an edit or a rule result uses `emitNext` and
  is delivered on the next tick, so a rule can never react to its own results within a tick.

| Module | What it owns |
| --- | --- |
| `layout.nim` | The fixed table: walls, arch, shooter lane, lane guides, flipper geometry, the drain line, keep-out zones. |
| `geometry.nim` | Capsule collision helpers. |
| `physics.nim` | Balls, flippers, plunger, nudge and tilt. It knows only `Collider`s (capsules) and reports each touch of a component as a `Contact`. |
| `catalogue.nim` | Cost, size and default settings per component kind (Appendix A). Tune numbers here. |
| `shapes.nim` | The collision shape of each kind. |
| `components.nim` | What each kind does when touched, and the events it raises. |
| `editing.nim` | Beam-in, fade-out, moves, build budget, piece cap, keep-out, overlap, edit rate. |
| `tracks.nim` | Mouths and track curves. |
| `episode.nim` | Build phase, three balls, ball save, extra balls, multiball, clock, ball search. |
| `rules.nim` | The FSMs and their results. |

Every tuning value is a named constant with its unit at the top of the module that uses it.
They are starting values for playtest.

### Simplifications worth knowing

- **Physics** integrates in 8 substeps per tick. A flipper is a moving collider driven by a
  power stroke, a weaker hold and a return spring, and it bounces a little off its top stop.
  Flip shots, the cradle, the live catch and the drop catch come from that model; there are
  no special cases for them.
- **A ball on a track moves in one dimension** along the centre line of a cubic Bezier
  between the two mouths. The slope, a ramp's climb and a little friction change its speed.
  Its level is the higher of the two mouths' levels. Two balls on one track pass through
  each other.
- **Things on a raised track** (rollover, spinner, gate) are found by their position on the
  curve and reported as contacts, so `components.nim` treats them like any other touch.
- **A captive ball** is a short lane ending in a rubber post. The trapped ball is not simulated.

## Script hosts (`src/pinball/script/`)

`loadScript(seat, source)` compiles a Bassy BASIC program; `decide(script, table)` runs it
once from the top with a fresh instruction budget. Variables persist between decisions. Each
BASIC call that changes the table becomes a `Command`, is applied at once, and is appended to
`script.issued`. A run-time error or a budget overrun stops the program for good: an Arena
program's table freezes and its rules keep running; a Flipper program's flippers go limp.

[`script/README.md`](../src/pinball/script/README.md) is the exact interface. The constants a
program sees (`kind_popbumper`, `ev_hit`, ...) are generated from the Nim enums.

## The driver (`src/pinball/game.nim`)

- **Seats.** The Arena seat holds a `playing` program and a `waiting` one (the newest that
  compiled). A program takes the seat when its first comment lines say: `' @effect
  next-episode` (the default), `' @effect next-ball` or `' @effect now`. `' @table house`
  runs the bundled house program for one decision first; `' @table blank` is the default.
  Seating always gives a `cmdClearArena` command, which also raises `evProgramLoaded`.
- **Decisions.** The Arena program decides every 10th tick. In demo mode the bundled demo
  Flipper program decides every 2nd tick; otherwise a person's commands arrive through
  `humanInput`.
- **Replay** (`replay.nim`). Every command either seat gives is recorded with its tick,
  rejected ones included (a rejected edit is logged in the table, which is hashed), with the
  table hash after each tick. `verify` re-simulates from the commands alone; no BASIC runs.
- **Summary** (`summary.nim`). The JSON the page reports to the cogent after each Episode.

## The view (`src/pinball/view/`)

The view reads the table and never writes it. `pinball.nim` runs the driver at 120 Hz with a
fixed-step accumulator and draws with windy and OpenGL (WebGL2 in the browser). Meshes are
built in code (`meshes.nim`, `pieces.nim`); the playfield art is generated
(`playfieldart.nim`). The canvas shows only the table: all text is HTML on the page.

`sound.nim` maps events and rule cues to the files in `assets/sounds/`, with a gain and a
cooldown per cue. `input.nim` turns keys and the gamepad (paddy) into `Command`s.

### Engine modules kept from Polyworld (`src/polyworld/`, commit `be1706dc`)

| File | Change from upstream |
| --- | --- |
| `hashes.nim`, `rngs.nim`, `sounddevices.nim` | None. |
| `shapes.nim` | An additive blend option. |
| `shadows.nim` | Cut down to one fixed light and one shadow map. |
| `toon.nim` | Rewritten to draw plain meshes instead of glTF node trees. Keeps the shading model; adds chrome, hologram and dissolve materials. |

The engine's window, HUD and transport modules are not used: they pull in the terrain engine
and need the private `polyworld_art` repository. This game ships only its own assets.

## The bridge between the game and the page

JSON strings in both directions (`view/bridge.nim`, `web/js/game-bridge.js`).

Game to page, through `Module.pinballMessage(json)`:

| `type` | Sent | Fields |
| --- | --- | --- |
| `hud` | When it changes | `phase`, `ballNumber`, `ballsPerEpisode`, `score`, `quest`, `award`, `clockSeconds` (left), `tiltWarnings`, `tilted`, `ballSaveActive` |
| `floating` | When it changes | `items`: `x`, `y` (fractions of the canvas), `text`, `colour`, `kind` (`text`, `message`, `score`) |
| `episode` | Once per Episode | `summary` |
| `programLoaded` | A program compiled | `name`, `version`, `effect` |
| `programError` | Once per failure | `name`, `version`, `stage` (`compile`, `run`, `budget`), `message`, `output` |

Page to game, pushed onto `Module.pinballInbox` and taken by the game once per frame (the
game pulls because its main loop is suspended between frames):

| `type` | Fields |
| --- | --- |
| `program` | `name`, `version`, `source` (no source with `"name":"house"` selects the bundled program) |
| `restart` | |
| `flipper` | `mode`: `human` or `demo` |

The table box in `web/styles.css` has the same aspect as `DesignAspect` in
`view/tableview.nim`. Change them together.

## The page (`web/`)

Plain ES modules, no framework, no build step, no dependencies.

- `aide-client.js`: the AIDE 1.0.0 wire layer over a WebSocket. Hand-written, because the
  released `@softmax-universe/aide` client handles chat only and answers every request from
  the agent with `unsupported`.
- `cogent-session.js`: what Appendix D of the design asks for. It has no timers;
  `cogent-connection.js` owns reconnecting.
- `programs.js`: the stored table programs (16, in `localStorage`).
- `game-bridge.js`, `side-panel.js`, `chat-panel.js`, `programs-panel.js`, `main.js`: the UI.
- `test/fake-game.js`: a stand-in for the game, loaded with `?fake-game`.

The server part is described in [`server/README.md`](../server/README.md).

## Where the build departs from the design

| Design | Build | Why |
| --- | --- | --- |
| `policy.create` / `policy.update` carry a name and the text. | The params are `{name, blob: {kind: "text", text}}`. | The AIDE 1.0.0 contract says so. |
| The page uses Softmax's client library for the wire format. | A hand-written client. | The released client cannot receive policy or surface messages. |
| The side panel is part of the game's view. | The side panel and all text are HTML; the canvas is the table only. | No font atlas or engine HUD, and crisp text at any size. |
| "Can spin off a flipper tip." | Ball spin is not modelled (`Ball.spin` stays 0). | Left out to keep the physics simple. |
| The diverter raises "passed". | It raises only "switched". | Not implemented. |
| Tracks on the same level may not overlap. | Not checked. | A track is a centre line, so an overlap is only a visual matter. |
| A ball leaving a raised mouth lands on the level below. | It lands on level 1, unless another track's mouth is there to catch it. | Raised levels hold only track. |
| A ball lock holds a ball until a rule releases it. | Also: locking the only ball in play serves a new ball, and locked balls do not keep a ball number alive. | Otherwise a lock can stall the Episode. |
| Post pass must work. | No test covers it. | It needs a person at the table. |
| Sounds from CC0 packs and recordings of real machines. | Kenney CC0 packs only. | Freesound downloads need an account. |
| A pre-rendered, airbrushed look. | Lit procedural solids, fake chrome, glow from additive discs. No bloom. | Kept to simple means. |

The BASIC budgets the design left open are set in `script/hosts.nim`: 200,000 instructions per
Arena decision, 50,000 per Flipper decision, 2 MiB of memory, 256 KiB of source.
