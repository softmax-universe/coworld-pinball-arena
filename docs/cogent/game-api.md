# Pinball Arena payload reference

## Programs

Submit the complete [Pinball Arena BASIC source](basic.md) as a text policy with `policy.create` or `policy.update`. The source limit is 256 KiB. The leading comments select the seat on creation. Updates keep that seat.

| Program | When it takes effect |
| --- | --- |
| Arena (default) | At the next Episode by default. The `' @effect next-ball` and `' @effect now` directives change when the game switches tables. [Arena directives](arena.md#taking-the-table) |
| Flipper (`' @seat flipper`) | As soon as the program compiles. [Flipper example](flipper.md#an-example) |

A returned version identifies the source stored in the browser. Compilation happens afterward and can produce a [program failure](#programfailed). The built-in `house` and `demo` names are reserved. In the game's scope, `policy.list` lists only deployed programs. Use `programs.list` for built-ins and seat assignments.

## Requests

For `surface.act`, request `data` contains a Pinball `method` and, when needed, a `params` object. Reply `data` contains either `result` or `error`. On a fresh table, listing programs returns the two built-ins.

```json
{"method":"programs.list"}
```

```json
{"result":{"programs":[
  {"name":"house","seat":"arena","version":0,"builtIn":true,"active":true},
  {"name":"demo","seat":"flipper","version":0,"builtIn":true,"active":false}
]}}
```

Requesting an unknown program with `{"method":"programs.get","params":{"name":"lanes"}}` returns the following error.

```json
{"error":{"code":"not_found","message":"No program named lanes is stored."}}
```

Other game error codes include `invalid` for bad arguments, `forbidden` for removing a built-in, and `failed` for an unexpected failure. An unknown Pinball method produces the AIDE error `unsupported`.

### The methods

| Method | Params | Result |
| --- | --- | --- |
| `run` | `{seat, source}` | `{output, error}`. Runs lines of BASIC once, now. `seat` is `"arena"` or `"flipper"` |
| `state` | | The table as it is now |
| `subscribe`, `unsubscribe` | | `{}`. Turns `game.messages` on or off |
| `restart` | | `{}`. Send `{"method":"restart"}` to reset the score and start a new Episode immediately using the latest Arena program that compiled. The Flipper seat keeps its controller. |
| `programs.list` | | `{programs: [{name, seat, version, builtIn, active}]}`. `active` marks the program chosen for its seat. A table program that is chosen may still be waiting for the next Episode or ball: `state` says who plays now |
| `programs.get` | `{name}` | The same fields and `source` (null for a built-in program) |
| `programs.activate` | `{seat, name}` | `{seat, name}`. A stored program plays that seat. `{"seat": "flipper", "name": null}` gives the flippers back to the person |
| `programs.remove` | `{name}` | `{}`. If it was active, the seat goes back to `house` (Arena) or to the person (Flipper) |

## Direct control

The `run` method executes BASIC once with fresh variables and the calls available to the specified seat. Its `result.output` is an array of printed lines. Its `result.error` is null on success or an object with `stage` (`compile`, `run`, or `budget`) and a text `message`. Edits made before a run-time error stay in effect for the current Episode. Submit a policy for a table that should be rebuilt each Episode.

## State

`state` gives the table as one object:

| Field | Holds |
| --- | --- |
| `tick`, `phase`, `ballNumber`, `score`, `clockSeconds` | As in the BASIC view. `phase` is `build`, `play` or `over` |
| `quest`, `award` | The text in the two message boxes |
| `ballSaveActive`, `tiltWarnings`, `tilted` | Whether ball save is active, the number of tilt warnings, and whether the table is tilted |
| `budgetLeft`, `rejectCount` | Build budget not yet spent. Edits refused so far in the Episode |
| `flippers` | `{left: {pressed, angle}, right: {pressed, angle}}` |
| `plunger` | `{pressed, pull}` |
| `balls` | One `{id, x, y, vx, vy, level, state}` per ball. `state` is `free`, `held` or `ontrack` |
| `pieces` | One `{id, kind, x, y, rotation, size, level, group, phase, lamp, down, face, hits}` per piece. `kind`, `phase` and `lamp` are the BASIC constants without their prefix (`popbumper`, `solid`, `flashing`). `hits` counts the touches in this Episode |
| `fsms` | One `{id, node, nodes, stopped}` per FSM: its current node and how many nodes it has |
| `programs` | `{arena: {name, version}, flipper: {name, version} or null}`: the programs that hold the seats now. `flipper` is null when a person plays. A built-in program has version 0 |

Positions are in millimetres, velocities in mm/s, and angles in degrees. The y coordinate increases toward the flippers.

## What the page sends you

The page introduces itself with an unscoped `surface.event` carrying
`{"kind":"client_guide","guide":"…"}`. The guide describes the open game and links to the
BASIC and payload references. The registration reply has `data` of `{"registered":true}`.

Game events carry the table's scope. Their `data.kind` identifies one of the three formats below.
Each game event uses an empty object (`{}`) as its reply data. The page can retry an episode summary or failure report with the same request ID. Subscribed updates are batched in order and are not replayed.

### `episode.summary`

Sent once at the end of every Episode, whether you are subscribed or not. `data` is `{"kind": "episode.summary", ...}` with these fields:

| Field | Holds |
| --- | --- |
| `program` | `{name, version}` of the program that held the Arena seat |
| `score` | The Flipper player's final score |
| `endReason` | `lastBallDrained` or `clock` |
| `balls` | One `{seconds}` per ball: how long it lasted |
| `components` | One `{id, kind, group, hits}` per piece on the table that the ball touched. `id` is what `create` returned, `kind` is as in BASIC without the prefix (`popbumper`). Untouched and removed pieces are not listed |
| `rules` | One `{fsm, node, count}` per rule node that was entered, with how often |
| `rejectedEdits` | One `{second, reason, edit}` per refused edit, such as `{"second": 0.0, "reason": "keepOut", "edit": "create"}` |
| `scriptError` | `null`, or `{stage, message, output}`: `stage` is `compile`, `run` or `budget`, and `output` is the last 16 lines the program printed |
| `flipper` | `null` when a person played the flippers, else `{name, version, scriptError}` of the Flipper program |

### `program.failed`

Sent once when a program does not compile, or stops while running, whether you are subscribed or not. `data` is `{"kind": "program.failed", seat, name, version, stage, message, output}`: the seat (`arena` or `flipper`), the program, the stage (`compile`, `run` or `budget`), the error message, and the last 16 lines the program printed. [basic.md](basic.md#failure) says what each stage means.

### `game.messages`

Sent only after the request `subscribe`, until `unsubscribe` or the end of the connection. `data` is `{"kind": "game.messages", "messages": [...]}`. The messages are in the order they happened, and several are sent together when they happen close to each other or while the page waits for your last answer. For example, a batch containing a program-load notice has this shape.

```json
{"kind":"game.messages","messages":[
  {"type":"programLoaded","seat":"arena","name":"ramp-school","version":1,"effect":"next-ball"}
]}
```

Each item in the batch has one of these types.

| `type` | When | Fields |
| --- | --- | --- |
| `hud` | The display changed | `phase`, `ballNumber`, `ballsPerEpisode`, `score`, `quest`, `award`, `clockSeconds`, `tiltWarnings`, `tilted`, `ballSaveActive` |
| `events` | A tick had table events | `tick`, `events`: one `{kind, value}` each, with `component`, `group`, `level`, `ball` and `strength` when they are not 0. `kind` is the `ev_` constant without its prefix (`hit`, `balldrained`). [arena.md](arena.md#rules) lists them under "Events" |
| `programLoaded` | A program compiled | `seat`, `name`, `version`, `effect` (`now`, `next-ball`, or `next-episode`). A table program can still be waiting to take effect |

The messages do not carry the positions of the balls: read `state` for those. A subscription ends when the connection does, so subscribe again after a reconnect.
