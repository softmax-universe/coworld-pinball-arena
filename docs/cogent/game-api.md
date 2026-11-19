# The game API

Every message between a cogent and the game: how to deploy a program (`policy.create`, `policy.update`), how to ask what is deployed (`policy.list`), the requests you can send (`surface.act`), and what the page sends you and expects back (`surface.event`). New here? Read [README.md](README.md) first. The BASIC that programs and `run` are written in is in [basic.md](basic.md), [arena.md](arena.md) and [flipper.md](flipper.md).

## The connection

The game runs in the person's browser. There is no game server. The page is the "frontend" of an AIDE 1.0.0 connection to your workspace, and everything below travels on that one connection as JSON-RPC 2.0. The game answers only while the person has the page open and is signed in.

| AIDE method | Who sends it | What the page does with it |
| --- | --- | --- |
| `policy.create`, `policy.update` | You | Stores a BASIC program and makes it play its seat ([Programs](#programs)) |
| `policy.list` | You | Answers with the programs you have deployed ([Which programs are deployed](#which-programs-are-deployed)) |
| `surface.act` | You | Carries out one request to the game and answers it ([Requests](#requests)) |
| `surface.event` | The page | Tells you what the game did. You answer it ([What the page sends you](#what-the-page-sends-you)) |
| `clarification.request` | You | Shows your question to the person. The page answers `{"accepted": true}` at once and sends the person's answer later as `clarification.response` |
| `browser.snapshot`, `browser.act` | You | Not supported: answered with the error `unsupported` |
| `chat.send` and the other chat and session methods | The page | The conversation between you and the person. The page puts nothing about the game into it |

### The scope

Every message of the game carries one scope, the Coworld scope of Pinball Arena:

```json
{"scope": "coworld", "coworld": "cow_8ef3f45c-7b8a-42ca-be02-208b261cbf76", "league": "league_9a3f459f-8223-4dc1-acd9-7292e46919dd"}
```

- The page sends this scope with everything it sends: the session it opens, chat, and every `surface.event`.
- **You must send the same scope** with `policy.create`, `policy.update` and `surface.act`. One with any other scope, or with the workspace scope, is answered with the error `forbidden` and does nothing.
- `policy.list` with another scope is answered with an empty list: the page holds no program that plays anywhere else.
- When you ask the person a question with `clarification.request`, the page repeats the scope of your question in its `clarification.response`.

These are the ids of the Coworld `pinball-arena` as registered on Softmax, and of its league. The Coworld id changes each time a new version is uploaded, so read the scope from a `surface.event` or from the session the page opened, and do not keep the ids in your notes as fixed.

## Programs

A program is a BASIC program that the game runs by itself: an Arena program 12 times a second, a Flipper program 60 times a second. It keeps its variables between runs and it reacts within a tick, with nothing in between.

### What you send

```json
{"jsonrpc": "2.0", "id": "<uuid>", "method": "policy.create",
 "params": {"name": "ramp-school",
            "scope": {"scope": "coworld", "coworld": "cow_8ef3f45c-7b8a-42ca-be02-208b261cbf76", "league": "league_9a3f459f-8223-4dc1-acd9-7292e46919dd"},
            "blob": {"kind": "text", "text": "' @effect next-episode\nif built = 0 then ..."}}}
```

- `policy.create` is for a new name and `policy.update` for a stored name. Both carry the whole source in `blob.text`, at most 256 KiB. `blob.kind` must be `"text"`.
- A name is 1 to 64 characters with no `:`. `house` (Arena) and `demo` (Flipper) are the built-in programs and cannot be replaced.
- **The seat is in the source.** A program is for the Arena seat unless one of the comment lines at its very top (before the first line of code) is exactly `' @seat flipper`. A program keeps the seat it was created with: to move a program to the other seat, create it under a new name.

### What the page answers

The result is `{"name": "ramp-school", "version": 1}`. A create is version 1 and each update adds 1. The result means the program is stored and chosen for its seat. It does not mean the program compiled: that is checked by the game a moment later, and a program that does not compile brings a [`program.failed`](#programfailed).

An error has its reason in `error.data.code`:

| Code | When |
| --- | --- |
| `conflict` | `policy.create` with a name that is stored or built in. Use `policy.update` |
| `forbidden` | A scope that is not the game's ([The scope](#the-scope)) |
| `not_found` | `policy.update` with a name that is not stored |
| `forbidden` | `policy.update` of `house` or `demo` |
| `too_large` | A source over 256 KiB |
| `unsupported` | A blob that is not text, or the page could not store the program (a bad name, or the browser's storage is full) |

### What the page does with the program

- It stores the program in the person's browser and makes it the active program of its seat, on a create and on every update. The person is not asked to approve. They see it in the list on the page and can pick another. Keep your own copy of every source: the store belongs to that one browser.
- An **Arena program** takes the table when its `' @effect` directive says: at the next Episode (the default), at the next ball, or now. The table always has an Arena program. The directives are in [arena.md](arena.md#taking-the-table).
- A **Flipper program** takes the flippers at once, and the person's keys do nothing while it plays. While a Flipper program is active, the next Episode starts by itself 5 seconds after one ends. With a person at the flippers, the next Episode starts when they press a button on the page or you send `restart`.
- A program that does not compile is not loaded, and whoever held the seat before keeps it.
- A program that fails while it runs never runs again. A failed Arena program leaves its table and rules as they are, and the rules keep working. A failed Flipper program leaves the flippers and the plunger released.

### Which programs are deployed

`policy.list` asks the page which programs it holds. Send it before you choose between `policy.create` and `policy.update`, and after a create or update whose answer never arrived, to learn whether it was applied.

```json
{"jsonrpc": "2.0", "id": "<uuid>", "method": "policy.list",
 "params": {"scope": {"scope": "coworld", "coworld": "cow_8ef3f45c-7b8a-42ca-be02-208b261cbf76", "league": "league_9a3f459f-8223-4dc1-acd9-7292e46919dd"}}}
```

The result is `{"items": [{"name": "ramp-school", "version": 3}, {"name": "catcher", "version": 1}]}`: every program you have deployed that the browser still holds, of both seats, in no set order. With none it is `{"items": []}`. With any scope but the game's it is `{"items": []}` too.

- The built-in programs `house` and `demo` are **not** in the list, though their names are taken: `policy.create` with one answers `conflict` and `policy.update` answers `forbidden`.
- The list has no seat, no source and no word on which program is active. The request `programs.list` ([The methods](#the-methods)) gives the seat and `active`, with the built-in programs, and `programs.get` gives the source.
- It changes nothing, so you may send it again at any time, also after a reconnect.
- `policy.list` was added to the AIDE 1.0.0 contract on 2026-11-18. If your workspace does not send it yet, use `programs.list`.

## Requests

### What you send

A `surface.act` whose `data` is one request to the game, `{"method": ..., "params": ...}`. `params` may be left out when the method has none.

```json
{"jsonrpc": "2.0", "id": "<uuid>", "method": "surface.act",
 "params": {"scope": {"scope": "coworld", "coworld": "cow_8ef3f45c-7b8a-42ca-be02-208b261cbf76", "league": "league_9a3f459f-8223-4dc1-acd9-7292e46919dd"},
            "data": {"method": "run", "params": {"seat": "flipper", "source": "flip(left, 1)"}}}}
```

### What the page answers

The result's `data` holds the answer of the game: `result` when the request was carried out, `error` when it was refused.

```json
{"jsonrpc": "2.0", "id": "<uuid>", "result": {"data": {"result": {"output": [], "error": null}}}}
{"jsonrpc": "2.0", "id": "<uuid>", "result": {"data": {"error": {"code": "not_found", "message": "No program named lanes is stored."}}}}
```

- A refusal by the game is a normal result with `data.error`. Its codes: `invalid` (a bad param, or a program of the other seat), `not_found`, `forbidden` (a built-in program cannot be removed).
- A `method` the game does not have is answered with the AIDE error `unsupported`.
- A scope that is not the game's is answered with the AIDE error `forbidden`.
- `run` and `state` are answered on the game's next frame, about 1/60 s after the request reaches the page. The other methods are answered at once.
- A request belongs to the connection it arrived on. If the connection closes before the page has answered, no answer is sent, and the request must not be assumed done or not done: read `state`.
- You may send requests without waiting for earlier answers. They are carried out in the order they arrive.

### The methods

| Method | Params | Result |
| --- | --- | --- |
| `run` | `{seat, source}` | `{output, error}`. Runs lines of BASIC once, now. `seat` is `"arena"` or `"flipper"` |
| `state` | | The table as it is now |
| `subscribe`, `unsubscribe` | | `{}`. Turns `game.messages` on or off |
| `restart` | | `{}`. Starts a new Episode at once |
| `programs.list` | | `{programs: [{name, seat, version, builtIn, active}]}`. `active` marks the program chosen for its seat. A table program that is chosen may still be waiting for the next Episode or ball: `state` says who plays now |
| `programs.get` | `{name}` | The same fields and `source` (null for a built-in program) |
| `programs.activate` | `{seat, name}` | `{seat, name}`. A stored program plays that seat. `{"seat": "flipper", "name": null}` gives the flippers back to the person |
| `programs.remove` | `{name}` | `{}`. If it was active, the seat goes back to `house` (Arena) or to the person (Flipper) |

## Direct control

`run` runs the lines you send once, at once, with the BASIC calls of the seat you name. The active program keeps running beside them. Everything a program can call, `run` can call: `flip`, `plunger` and `nudge` for the Flipper seat; `create`, `move`, `setting`, `fsm`, `edge`, `doscore`, `ready` and the rest for the Arena seat.

```json
{"method": "run", "params": {"seat": "flipper", "source": "flip(left, 1)"}}
{"method": "run", "params": {"seat": "arena", "source": "b = create(kind_popbumper, 240, 400, 0, 100, 1, 0)\nprint b"}}
```

- The lines start with fresh variables on every `run`. To keep a piece id or an FSM id, `print` it and read it from `output`, or read `state`.
- `output` is the lines that were printed. `error` is null, or `{stage, message}` with `stage` `compile`, `run` or `budget`. What the lines did before a run-time error stays done.
- The limits of the seat apply as they do to a program: the build budget, the keep-out zones, and during play the edit rate of 4 a second ([arena.md](arena.md#the-table), "Limits"). One `run` may use 200,000 instructions for the Arena seat and 50,000 for the Flipper seat.
- A `run` for the Flipper seat that stops with a run-time error releases both flippers and the plunger.
- **What `run` builds does not outlast the Episode.** Every Episode starts from an empty table that the active Arena program builds again, and a program that takes over during an Episode clears the table first. Put what should stay into a program.
- To build a table by direct control alone, deploy an Arena program that is only the comment `' @effect now`: the table is then empty. `run` your edits. If the Episode is in its build phase, call `ready()` when the table is built, or the first ball waits the full 10 seconds.
- Once an Episode is over, every call is refused (it returns `-reject_notallowed`) until the next Episode starts.
- The game answers `run` and `state` on its next frame, about 1/60 s, plus the time the request takes to reach the page. A program inside the game is faster and steadier. Use direct control to try things and to make single changes, and a program for anything that must react to the ball.

## State

`state` gives the table as one object:

| Field | Holds |
| --- | --- |
| `tick`, `phase`, `ballNumber`, `score`, `clockSeconds` | As in the BASIC view. `phase` is `build`, `play` or `over` |
| `quest`, `award` | The text in the two message boxes |
| `ballSaveActive`, `tiltWarnings`, `tilted` | |
| `budgetLeft`, `rejectCount` | Build budget not yet spent. Edits refused so far in the Episode |
| `flippers` | `{left: {pressed, angle}, right: {pressed, angle}}` |
| `plunger` | `{pressed, pull}` |
| `balls` | One `{id, x, y, vx, vy, level, state}` per ball. `state` is `free`, `held` or `ontrack` |
| `pieces` | One `{id, kind, x, y, rotation, size, level, group, phase, lamp, down, face, hits}` per piece. `kind`, `phase` and `lamp` are the BASIC constants without their prefix (`popbumper`, `solid`, `flashing`). `hits` counts the touches in this Episode |
| `fsms` | One `{id, node, nodes, stopped}` per FSM: its current node and how many nodes it has |
| `programs` | `{arena: {name, version}, flipper: {name, version} or null}`: the programs that hold the seats now. `flipper` is null when a person plays. A built-in program has version 0 |

Units are those of the guides: millimetres, mm/s, degrees.

## What the page sends you

Everything the game tells you arrives as a `surface.event`: a request from the page, with what happened in `data` and the kind of thing in `data.kind`.

```json
{"jsonrpc": "2.0", "id": "<uuid>", "method": "surface.event",
 "params": {"scope": {"scope": "coworld", "coworld": "cow_8ef3f45c-7b8a-42ca-be02-208b261cbf76", "league": "league_9a3f459f-8223-4dc1-acd9-7292e46919dd"},
            "data": {"kind": "episode.summary", "score": 41200, "endReason": "lastBallDrained", "...": "..."}}}
```

### What the page expects from you

- **Answer every `surface.event`**, with the result `{"data": {}}`. The page does not read what is in `data`, so there is nothing to put there. There is no way to refuse one usefully: any error but the three below makes the page drop the event.
- **Answer promptly.** The page sends one `game.messages` event at a time and waits for your answer before it sends the next. Until you answer, what happens on the table piles up into the next event. An event that is never answered stops the messages until the connection closes.
- **Reports are sent again; treat a repeated `id` as the same report.** If an `episode.summary` or a `program.failed` is answered with the error `unavailable`, `starting` or `paused`, or the connection is lost before your answer arrives, the page sends the same event again under the same `id` once the connection or the workspace is back. Do not count it twice. A report made while there is no connection waits and is sent when there is one; a report is lost only if the person closes or reloads the page first.
- **`game.messages` are never sent again.** One that fails is dropped, and the next one carries only what happened after it. The table as it is now is always in `state`.
- **You need not react.** Nothing in the game waits for you to act on an event.

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

Sent only after the request `subscribe`, until `unsubscribe` or the end of the connection. `data` is `{"kind": "game.messages", "messages": [...]}`. The messages are in the order they happened, and several are sent together when they happen close to each other or while the page waits for your last answer. A message is one of:

| `type` | When | Fields |
| --- | --- | --- |
| `hud` | The display changed | `phase`, `ballNumber`, `ballsPerEpisode`, `score`, `quest`, `award`, `clockSeconds`, `tiltWarnings`, `tilted`, `ballSaveActive` |
| `events` | A tick had table events | `tick`, `events`: one `{kind, value}` each, with `component`, `group`, `level`, `ball` and `strength` when they are not 0. `kind` is the `ev_` constant without its prefix (`hit`, `balldrained`). [arena.md](arena.md#rules) lists them under "Events" |
| `programLoaded` | A program compiled and was taken | `seat`, `name`, `version`, `effect` |

The messages do not carry the positions of the balls: read `state` for those. A subscription ends when the connection does, so subscribe again after a reconnect.
