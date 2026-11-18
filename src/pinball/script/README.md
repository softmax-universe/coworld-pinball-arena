# The BASIC interface of the two seats

Reference for what a BASIC program can see and call in Pinball Arena. The
code is in this folder:

| File | What it holds |
| --- | --- |
| `hosts.nim` | `loadScript`, `decide`, the budgets |
| `base.nim` | the `Script` type and `give`, where a call becomes a command |
| `view.nim`, `view.bas` | the view: named numbers and the `balls` / `pieces` records |
| `common_api.nim` | constants and maths, for both seats |
| `flipper_api.nim` | the Flipper seat calls |
| `arena_api.nim` | the Arena seat calls |

The language is Bassy BASIC (`deps/bassy/docs/language.md`).

## How a program runs

- The program runs from its first line to its end once per decision. The
  Arena program decides 12 times a second (every 10 ticks), the Flipper
  program 60 times a second (every 2 ticks). One tick is 1/120 s.
- Variables and arrays keep their values between decisions. A variable that
  was never assigned is 0, so `if built = 0 then ... built = 1` runs a block
  once.
- Before each decision the host fills the view (below). The view is not
  updated during a decision: a piece made by `create` shows up in `pieces`
  on the next decision.
- A call that changes the table takes effect at once and returns its outcome.
- `PRINT` goes to a private log. The host keeps the last 16 printed lines.

## Numbers

- A value is an integer (32 bits) or a fixed-point number (16.16: about
  -32768 to 32767, in steps of 1/65536). A literal with a `.` is fixed-point.
  There are no floats.
- Positions are millimetres: `x` 0..520 to the right, `y` 0..1080 toward the
  player (the drain is at the largest `y`). Speeds are mm/s. Angles are
  degrees: 0 points along +x and angles grow clockwise on screen.
- An integer outside -32768..32767 cannot be mixed with a fixed-point number
  or passed where a fixed-point argument is expected. That is a run-time
  error (`BASIC integer is outside the fixed-point range`).
- Flags in the view are 1 or 0.

## The view (both seats)

Read-only named numbers. Assigning to one is a compile error.

| Name | Type | Meaning |
| --- | --- | --- |
| `tick` | integer | Ticks since the Episode began |
| `phase` | integer | 0 build phase, 1 play, 2 over |
| `ballnumber` | integer | 1..3 while playing |
| `score` | integer | The Flipper score, at most 2147483647 |
| `clockseconds` | integer | Whole seconds left on the Episode clock |
| `ballcount` | integer | Balls listed in `balls`, 0..6 |
| `piececount` | integer | Pieces listed in `pieces`, 0..128 |
| `leftangle`, `rightangle` | fixed | Flipper angle in degrees above its rest position |
| `leftpressed`, `rightpressed` | integer | 1 while the flipper is pressed |
| `plungerpull` | fixed | 0 at rest .. 1 fully pulled |
| `tiltwarnings` | integer | Tilt warnings on this ball |
| `tilted` | integer | 1 while the flippers are dead from a tilt |

Two record arrays. Only the entries below the count are current; the others
keep old values.

`balls(0..5)`, valid for `0 .. ballcount - 1`:

| Field | Type | Meaning |
| --- | --- | --- |
| `.id` | integer | |
| `.x`, `.y` | fixed | Position |
| `.vx`, `.vy` | fixed | Speed |
| `.level` | integer | 1 playfield, 2 and 3 raised track |
| `.state` | integer | `state_free` 0, `state_held` 1, `state_ontrack` 2 |

`pieces(0..127)`, valid for `0 .. piececount - 1`, in the order the pieces
were made. A removed piece leaves the list at once, while it is still fading
out on screen.

| Field | Type | Meaning |
| --- | --- | --- |
| `.id` | integer | |
| `.kind` | integer | A `kind_` constant |
| `.x`, `.y` | fixed | Position. During a move, the old place until the piece has faded out |
| `.rotation` | fixed | Degrees |
| `.size` | integer | Percent of the normal size, 50..200 |
| `.level` | integer | |
| `.group` | integer | 0 is no group |
| `.phase` | integer | `phase_beamingin` 0 (a hologram), `phase_solid` 1, `phase_fadingout` 2 (leaving its old place before a move) |
| `.lamp` | integer | A `lamp_` constant |
| `.down` | integer | Drop target: 1 when knocked down |
| `.face` | integer | Toggle target: 0 or 1 |

The names `BallView`, `PieceView`, `balls` and `pieces` are taken by the host
prelude. A program can write to the two arrays, and the host overwrites them
before the next decision.

### Arena seat only

| Name | Type | Meaning |
| --- | --- | --- |
| `budgetleft` | integer | Build budget not yet spent |
| `fsmcount` | integer | FSMs on the table |
| `rejectcount` | integer | Edits rejected so far in the Episode: edits from this seat's calls and edits made by rule results. Rejected FSM calls are not counted |
| `lastreject` | integer | The `reject_` reason of the latest of those, or 0 |
| `fsmnode(fsm)` | call | The current node of an FSM, or -1 when there is no such FSM. Unlike the names above it reads the table as it is now |

In a Flipper program these names are ordinary unassigned variables (0).

## Constants (both seats)

Read-only. Each name is a prefix plus the Nim enum value name without its own
prefix, in lower case (`ckPopBumper` becomes `kind_popbumper`). They are
generated from the enums in `sim/types.nim`, which is the list to trust.

| Prefix | Enum | Names, numbered from 0 |
| --- | --- | --- |
| `kind_` | `ComponentKind` | `none popbumper passivebumper slingshot standuptarget droptarget toggletarget spinner rollover captiveball saucer scoop balllock kicker kickback magnet gate diverter uppost wall rubberpost mouth track insert flasher` |
| `ev_` | `EventKind` | `none hit drop bankcomplete reset flip spin rollover captured released locked fired usedup relit grabbed passed switched raised lowered trackentered trackcompleted trackfailed flipperup flipperdown flipperfullyraised plungerpulled balllaunched nudge tiltwarning tilt balldrained ballsaved balladded ballcountchanged ballchangedlevel componentcreated componentremoved editrejected fsmsignal scriptsignal clockthreshold buildphaseended episodeending programloaded` |
| `set_` | `Setting` | `strength direction holdticks travelticks exitx exity capacity radius mode enabled position length curve bounce style widtha widthb moutha mouthb controlax controlay controlbx controlby colour lamp` |
| `cue_` | `SoundCue` | `none ping bell chime thunk clack pop sling spinner rollover drop resetbank launch drain ballsave extraball kick hole lock magnet gate beamin fadeout sweepup sweepdown fanfare jackpot queststart questfail warning tilt gameover programloaded` |
| `lamp_` | `LampState` | `off on flashing` |
| `colour_` | `LampColour` | `yellow red green blue white` |
| `slot_` | `PanelSlot` | `quest award` |
| `nudge_` | `NudgeDirection` | `left right up` |
| `reject_` | `RejectReason` | `none keepout overbudget toomanypieces overlap ratelimit unknowntarget badvalue limit notallowed` |
| `state_` | `BallState` | `free held ontrack` |
| `phase_` | `ComponentPhase` | `beamingin solid fadingout` |

Also `left` = 0 and `right` = 1, the flipper sides.

## Maths (both seats)

Bassy has no built-in maths. These are all there is. There is no `^`.

| Call | Returns |
| --- | --- |
| `abs(x)` | The absolute value. Integer for an integer, else fixed |
| `min(a, b)`, `max(a, b)` | Integer when both are integers, else fixed |
| `floor(x)` | The largest integer not above `x` |
| `sqrt(x)` | Fixed, rounded down. A negative `x` is a run-time error |
| `sin(degrees)`, `cos(degrees)` | Fixed |
| `atan2(y, x)` | Fixed, the angle of the direction (x, y) in degrees, -180..180. `atan2(0, 0)` is 0 |
| `rnd(n)` | An integer 0..n-1 (0 when `n` is below 2). Each program has its own generator with a fixed seed, so a program draws the same numbers in every Episode |

`sqrt`, `sin`, `cos` and `atan2` take fixed-point arguments, so an integer
argument must be within -32768..32767. Results are close but not exact:
`atan2(1, 1)` is 45.00021.

## What a call returns

Every call that changes the table returns:

- a positive number when the command was accepted: the new piece id, FSM id
  or node index for calls that make one, and 1 for the others;
- `-reason` when it was rejected, where `reason` is a `reject_` constant.
  For example `if create(...) = -reject_overbudget then`.

A call may be used as a statement (`doscore(rule, award, 5)`) or in an
expression (`bumper = create(...)`).

Arguments named `id`, `group`, `fsm`, `node`, `number`, `count`, `level`,
`size`, `percent`, `amount` and all constants must be whole numbers. A
fraction there is a run-time error. An argument that must be one of a set of
constants (a kind, event, setting, cue, lamp state, colour, slot, side or
nudge direction) and is not one of them is a run-time error too
(`99 is not a ComponentKind`). `pressed` is true for any value that is not 0.

## Flipper seat calls

| Call | Effect |
| --- | --- |
| `flip(side, pressed)` | Press or release a flipper. `side` is `left` or `right` |
| `plunger(pressed)` | Pull the plunger (1) or let it go (0) |
| `nudge(direction)` | Nudge the table: `nudge_left`, `nudge_right` or `nudge_up` |

Each is one command and returns 1, or `-reject_notallowed` when the Episode
is over.

## Arena seat calls

### Pieces

Each is one command unless it says otherwise.

| Call | Effect and return value |
| --- | --- |
| `create(kind, x, y, rotation, size, level, group)` | Make a piece. `size` is percent (0 means 100). `level` 1..3 (0 means 1). `group` 0 for none. Returns the piece id |
| `move(id, x, y)` | Move a piece. It fades out and beams in at the new place |
| `rotate(id, degrees)` | Set the rotation, -360..360 |
| `resize(id, percent)` | Set the size, 50..200 |
| `remove(id)` | Delete a piece |
| `removegroup(group)` | Delete every piece of a group |
| `setting(id, which, value)` | Set one setting. `which` is a `set_` constant |
| `groupsetting(group, which, value)` | Set one setting on every piece of a group |
| `reset(id)` | Raise a drop target again, or relight a kickback |
| `resetgroup(group)` | The same for every piece of a group |
| `track(moutha, mouthb, cax, cay, cbx, cby)` | Make a track between two mouth pieces, with the two control points of its curve. All four control values 0 give a straight line. Seven commands: the track piece, then `set_moutha`, `set_mouthb`, `set_controlax`, `set_controlay`, `set_controlbx`, `set_controlby`. Returns the track id, or the reason of the first rejected command; a track piece made before that stays on the table |

A rejected edit (from a piece call, or from a rule result when it runs) is
logged in the table and counted in `rejectcount`.

### Rules

An FSM starts with node 0, its initial node.

| Call | Effect and return value |
| --- | --- |
| `fsm()` | Make an FSM. Returns its id |
| `node(fsm)` | Add a node. Returns its index (1, 2, ...) |
| `edge(fsm, fromnode, tonode, event, component, group, count)` | Add an edge that fires on the `count`-th (1..255) matching event since the FSM entered `fromnode`. `event` is an `ev_` constant. `component` 0 matches any piece and `group` 0 any group |
| `edgex(fsm, fromnode, tonode, event, component, group, count, level, value, minstrength)` | The same with three more filters: `level` (0 any), `value` (-1 any; the meaning depends on the event) and `minstrength` (the least impact speed in mm/s) |
| `timeout(fsm, fromnode, tonode, seconds)` | Add an edge that fires after `seconds` in `fromnode`. `seconds` may have a fraction and must be at least one tick |
| `final(fsm, node)` | Mark a node final: entering it stops the FSM |
| `fsmreset(fsm)` | Back to node 0, counts cleared, running again |
| `fsmremove(fsm)` | Delete an FSM |
| `signal(number)` | Raise script signal 0..15. FSMs see it on the next tick as `ev_scriptsignal` with that `value` |

### Results of a node

Each adds one result to node `n` of FSM `f`. The results of a node run in
the order they were added, each time the FSM enters the node. Each call is
one command and returns 1.

| Call | Result |
| --- | --- |
| `doscore(f, n, amount)` | Add `amount` to the score (negative subtracts). Up to 1,000,000 either way |
| `dosound(f, n, cue)` | Play a `cue_` sound |
| `dolamp(f, n, component, state)` | Set the lamp of a piece to a `lamp_` state |
| `dolampgroup(f, n, group, state)` | Set the lamps of a group |
| `doflash(f, n)` | Pulse the flashers |
| `doburst(f, n, component)` | Particle burst at a piece |
| `domessage(f, n, slot, text$)` | Show text in a side-panel box: `slot_quest` or `slot_award` |
| `dosignal(f, n, number)` | Raise FSM signal 0..15 (`ev_fsmsignal`, seen on the next tick) |
| `docreate(f, n, kind, x, y, rotation, size, level, group)` | The edit `create` makes |
| `domove(f, n, id, x, y)` | The edit `move` makes |
| `doremove(f, n, id)` | The edit `remove` makes |
| `doremovegroup(f, n, group)` | The edit `removegroup` makes |
| `dosetting(f, n, id, which, value)` | The edit `setting` makes |
| `dogroupsetting(f, n, group, which, value)` | The edit `groupsetting` makes |
| `doreset(f, n, id)` | The edit `reset` makes |
| `doresetgroup(f, n, group)` | The edit `resetgroup` makes |
| `doaddball(f, n)` | Serve another ball (multiball) |
| `dorelease(f, n, component)` | Release the balls a piece holds |
| `dosave(f, n, seconds)` | Start a ball save of `seconds` (may have a fraction) |
| `doextraball(f, n)` | Award an extra ball |

Adding a result checks only its own values (score size, signal number,
text). Text is at most 40 characters from capitals, digits, space and
`! ? . , : ; ' " - + * / % & # = < > ( )`; other text is rejected with
`reject_badvalue`. The pieces it names are not checked then, because a rule may name a
piece that is built later. An edit result is checked when it runs, by the
same rules as a direct edit except the edit rate; one that cannot be applied
is skipped and counted in `rejectcount`.

## Calls of the other seat

A seat does not have the other seat's calls, and such a program never runs:

- used in an expression (`x = flip(left, 1)` in an Arena program), the call
  compiles and is a run-time error on the decision that reaches it
  (`BASIC indexed value must be a returned array`);
- used as a statement (`flip(left, 1)`), it is a compile error.

A misspelled call fails the same two ways.

## Failure

| Status | When | Then |
| --- | --- | --- |
| `scriptCompileError` | The source does not compile, is longer than 256 KiB, or needs more than 2 MiB | The program never runs. The message names the line in the author's source (`line 3, column 14: ...`) when Bassy gives one |
| `scriptFailed` | A run-time error: division by zero, an array index out of range, a bad argument, more printing than the print limit, ... | The program never runs again. Bassy gives no line number for run-time errors |
| `scriptOverBudget` | One decision used more than the instruction budget (or the work budget, see below) | The program never runs again |

What the program did before the error stays done, and lines it printed are
kept. After an Arena program stops, the table stays as it is and its rules
keep running. When a Flipper program stops, the host releases both flippers
and the plunger.

## Budgets

| Limit | Value |
| --- | --- |
| Instructions per decision, Arena | 200,000 |
| Instructions per decision, Flipper | 50,000 |
| Work units per decision | 20 times the instruction budget. An instruction costs 1, a call of the functions on this page 16 more, and a string operation its length in bytes, so only a program that works on long strings reaches this before the instruction budget. It is reported as `scriptOverBudget` too |
| Memory | 2 MiB |
| Source | 256 KiB |
| Printing per decision | 2,048 bytes and 256 print items (each value or string in a `PRINT`, and each line end, is one item) |
| Kept output | The last 16 lines |

## For the driver

- `loadScript(seat, source)` returns a `Script`. Check `status` and `error`.
- `decide(script, table)` runs one decision. It does nothing once the status
  is not `scriptRunning`.
- `script.issued` holds every command the program gave during the latest
  decision, in order, with `seat` and `tick` set, rejected ones included. A
  replay must apply them all, because a rejected edit is logged in the table
  and is part of its state hash. The releases of a failed Flipper program
  are in `issued` on the decision that failed.
- `script.output` holds the last 16 printed lines, oldest first.
