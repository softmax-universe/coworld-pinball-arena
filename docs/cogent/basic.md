# BASIC for both seats

What every program in Pinball Arena has in common, whichever seat it plays: how it runs, the BASIC dialect, numbers, what it can see (the view), the constants, the maths calls, how it fails and its limits. The lines you send with the `run` request ([game-api.md](game-api.md#direct-control)) follow the same rules.

The calls of each seat are in [arena.md](arena.md) and [flipper.md](flipper.md). New here? Start with [README.md](README.md).

## How a program runs

- The program runs from its first line to its last once per **decision**. An Arena program decides 12 times a second (every 10 ticks) and a Flipper program 60 times a second (every 2 ticks). A tick is 1/120 s. The first decision is at the start of the build phase.
- **Variables and arrays keep their values between decisions.** A variable that was never assigned is 0. So do a thing once behind a flag:

```basic
if started = 0 then
  started = 1
  ' this block runs once
end if
```

- The view is filled before each decision and does not change during one. A piece made by `create` shows up in `pieces` on the next decision.
- A call that changes the table takes effect at once and returns its outcome ([Arguments and return values](#arguments-and-return-values)).
- Because the program runs again on every decision, a loop that waits for something never ends: it uses up the instruction budget and stops the program. Test the condition once per decision with `IF`.
- `PRINT` is for debugging. Nobody sees it on screen. The last 16 printed lines come back as `output` when the program fails ([Failure](#failure)).
- A program always starts with fresh variables: at the start of every Episode, and whenever it is loaded.

## The dialect

Bassy BASIC is close to QBasic, with these differences. Each is a rule.

| Rule | Example |
| --- | --- |
| No `FUNCTION` or `DEF FN`. A `SUB` returns a value by writing a global | `sub area(w, h)` / `result = w * h` / `end sub` |
| A `SUB` needs brackets in its header and in every call, also with no parameters | `sub build()` ... `build()` |
| Only parameters are local. Every other variable in a `SUB` is global, `FOR` counters too: a `SUB` called inside `for i` must not use `i` | |
| Parameters are passed by value. A string parameter ends in `$` | `sub tell(words$)` |
| A `SUB` may be called above its definition, so put the main code first | |
| `DIM` only at the top level, one dimension, a literal bound, indexes 0..n | `dim lamp(2)` has 3 cells |
| No `CONST`, `DATA`/`READ`, `SWAP`, `REDIM`, `ON ERROR`, `INPUT`, `VAL`, `PRINT USING`, `^`, type suffixes (`%`, `&`, `!`, `#`) or `DIM x AS INTEGER` | `maxhits = 5`, `x * x` |
| The only maths calls are `abs min max floor sqrt sin cos atan2 rnd` ([Maths](#maths)). No `int`, `sqr`, `sgn`, `atn`, `timer` | `floor(x)` |
| `rnd(n)` needs its argument and gives an integer 0..n-1, the same numbers in every Episode | `rnd(6) + 1` |
| A misspelled or missing function compiles, then fails at run time: `BASIC indexed value must be a returned array` | |
| Numbers are 32-bit integers or fixed-point (16.16, about -32768..32767). A literal with a `.` is fixed-point. No floats | `0.5` |
| An integer outside -32768..32767 cannot be mixed with a fixed-point number: run-time error. Keep fixed-point results in that range too | `score * 0.5` fails at 100000: use `score \ 2` |
| `/` is fixed-point division, `\` integer division, `mod` the remainder | `7 / 2` is 3.5, `7 \ 2` is 3 |
| Comparisons give -1 (true) or 0. `AND`, `OR`, `NOT` are bitwise and evaluate both sides | `if a > 3 and b < 10 then` works |
| View flags are 1 or 0, and `not 1` is -2, which is true. Never write `not flag` | `if tilted = 0 then` |
| A name of the view, a constant or a call cannot be a variable (compile error). So no variable named `score`, `tick`, `phase`, `left`, `right`, `node`, `edge`, `track`, `move`, `reset`, `signal`, `final`, `timeout`, `min`, `max` ... | `ramp = track(...)` |
| `+` joins strings only. `str$(5)` is `" 5"`, with a leading space | `"HITS" + str$(n)` |

The control flow (`IF/ELSEIF/ELSE/END IF`, one-line `IF`, `FOR/NEXT/STEP`, `WHILE/WEND`, `DO/LOOP`, `SELECT CASE`, `GOSUB`, `EXIT FOR/DO/SUB`), `'` comments and the string functions (`LEN LEFT$ MID$ INSTR STR$` ...) work as in QBasic.

Because the program runs again many times a second, a loop that waits for something never ends: it uses up the budget and stops the program. Test the condition once per decision with `IF`.

## Numbers and units

- A value is an integer (32 bits) or a fixed-point number (16.16: about -32768 to 32767, in steps of 1/65536). A literal with a `.` is fixed-point. There are no floats.
- An integer outside -32768..32767 cannot be mixed with a fixed-point number or passed where a fixed-point argument is expected. That is a run-time error (`BASIC integer is outside the fixed-point range`).
- Positions are millimetres: `x` 0..520 to the right, `y` 0..1080 toward the player, so the flippers and the drain are at large `y` and a ball moving up the table has a negative `vy`.
- Speeds are mm/s. Angles are degrees, clockwise on screen: 0 points right, 90 down the table (toward the player), 180 left, 270 up the table.
- Times in settings are ticks (120 per second). Times in rule calls are seconds.
- Flags in the view are 1 or 0.

## The view

Read-only names, filled before each decision. Assigning to one is a compile error.

| Name | Type | Meaning |
| --- | --- | --- |
| `tick` | integer | Ticks since the Episode began |
| `phase` | integer | 0 build phase, 1 play, 2 over |
| `ballnumber` | integer | 1..3 while playing, 0 in the build phase |
| `score` | integer | The Flipper player's score |
| `clockseconds` | integer | Whole seconds left on the Episode clock, which starts when the build phase ends |
| `ballcount` | integer | How many entries of `balls` are current, 0..6 |
| `piececount` | integer | How many entries of `pieces` are current, 0..128 |
| `leftangle`, `rightangle` | fixed | Flipper angle in degrees above rest, 0..50 |
| `leftpressed`, `rightpressed` | integer | 1 while the flipper button is held |
| `plungerpull` | fixed | 0 at rest .. 1 fully pulled |
| `tiltwarnings` | integer | Tilt warnings on this ball |
| `tilted` | integer | 1 while the flippers are dead from a tilt |

For the Arena seat only. In a Flipper program these names are ordinary variables (0):

| Name | Type | Meaning |
| --- | --- | --- |
| `budgetleft` | integer | Build budget not yet spent |
| `fsmcount` | integer | FSMs on the table |
| `rejectcount` | integer | Edits refused so far in the Episode: edits from Arena calls and edits made by rule results. Refused rule calls are not counted |
| `lastreject` | integer | The `reject_` reason of the latest of those, or 0 |
| `fsmnode(f)` | call | The current node of an FSM, or -1 when there is no such FSM. Unlike the names above it reads the table as it is now |

`balls(i)` for `i` = 0 .. `ballcount - 1`:

| Field | Type | Meaning |
| --- | --- | --- |
| `.id` | integer | |
| `.x`, `.y` | fixed | Position |
| `.vx`, `.vy` | fixed | Speed |
| `.level` | integer | 1 playfield, 2 and 3 raised track |
| `.state` | integer | `state_free`, `state_held` (in a saucer, scoop, lock or holding magnet) or `state_ontrack` |

`pieces(i)` for `i` = 0 .. `piececount - 1`, in the order the pieces were made. A removed piece leaves the list at once, while it is still fading out on screen.

| Field | Type | Meaning |
| --- | --- | --- |
| `.id` | integer | What `create` returned |
| `.kind` | integer | A `kind_` constant |
| `.x`, `.y` | fixed | Position. During a move, the old place until the piece has faded out |
| `.rotation` | fixed | Degrees |
| `.size` | integer | Percent of the normal size, 50..200 |
| `.level` | integer | |
| `.group` | integer | 0 is no group |
| `.phase` | integer | `phase_beamingin` (a hologram), `phase_solid`, `phase_fadingout` (leaving its old place before a move) |
| `.lamp` | integer | A `lamp_` constant |
| `.down` | integer | Drop target: 1 when knocked down |
| `.face` | integer | Toggle target: 0 or 1 |

Entries past the counts hold old values. The names `balls`, `pieces`, `BallView` and `PieceView` are taken too.

## Constants

Read-only. A constant is a prefix and a name: `cue_fanfare`. Each list is numbered from 0 in the order shown.

| Prefix | Names |
| --- | --- |
| `kind_` | `none popbumper passivebumper slingshot standuptarget droptarget toggletarget spinner rollover captiveball saucer scoop balllock kicker kickback magnet gate diverter uppost wall rubberpost mouth track insert flasher` |
| `ev_` | `none hit drop bankcomplete reset flip spin rollover captured released locked fired usedup relit grabbed passed switched raised lowered trackentered trackcompleted trackfailed flipperup flipperdown flipperfullyraised plungerpulled balllaunched nudge tiltwarning tilt balldrained ballsaved balladded ballcountchanged ballchangedlevel componentcreated componentremoved editrejected fsmsignal scriptsignal clockthreshold buildphaseended episodeending programloaded` |
| `set_` | `strength direction holdticks travelticks exitx exity capacity radius mode enabled position length curve bounce style widtha widthb moutha mouthb controlax controlay controlbx controlby colour lamp` |
| `cue_` | `none ping bell chime thunk clack pop sling spinner rollover drop resetbank launch drain ballsave extraball kick hole lock magnet gate beamin fadeout sweepup sweepdown fanfare jackpot queststart questfail warning tilt gameover programloaded plungerpull nudge` |
| `lamp_` | `off on flashing` |
| `colour_` | `yellow red green blue white` |
| `slot_` | `quest award` |
| `nudge_` | `left right up` |
| `reject_` | `none keepout overbudget toomanypieces overlap ratelimit unknowntarget badvalue limit notallowed` |
| `state_` | `free held ontrack` |
| `phase_` | `beamingin solid fadingout` |

Also `left` = 0 and `right` = 1, the flipper sides.

What the kinds, events and settings mean is in [arena.md](arena.md): [Pieces](arena.md#pieces) and [Rules](arena.md#rules).

## Maths

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

`sqrt`, `sin`, `cos` and `atan2` take fixed-point arguments, so an integer argument must be within -32768..32767. Results are close but not exact: `atan2(1, 1)` is 45.00021.

## Arguments and return values

Every call that changes the table returns:

- a positive number when it was accepted: the new piece id, FSM id or node index for the calls that make one, and 1 for the others;
- `-reason` when it was refused, where `reason` is a `reject_` constant: `if create(...) = -reject_overlap then`. A refused call did nothing.

A call may be used as a statement (`doscore(rule, award, 5)`) or in an expression (`bumper = create(...)`).

Arguments that are ids, groups, FSMs, nodes, signal numbers, counts, levels, sizes, amounts and constants must be whole numbers: a fraction is a run-time error. So is a number that is not one of the constants where a kind, event, setting, cue, lamp state, colour, slot, side or nudge direction is expected (`99 is not a ComponentKind`). Positions, rotations, setting values and seconds may have fractions. A wrong number of arguments is a compile error. `pressed` is true for any value that is not 0.

## The other seat's calls

A seat does not have the other seat's calls, and such a program never runs:

- used in an expression (`x = flip(left, 1)` in an Arena program), the call compiles and is a run-time error on the decision that reaches it (`BASIC indexed value must be a returned array`);
- used as a statement (`flip(left, 1)`), it is a compile error.

A misspelled call fails the same two ways.

## Failure

| Stage | When | Then |
| --- | --- | --- |
| `compile` | The source does not compile, is longer than 256 KiB, or needs more than 2 MiB | The program is not loaded, and whoever held the seat before keeps it. The message names the line (`line 3, column 14: ...`) |
| `run` | A run-time error: division by zero, an array index out of range, a bad argument, more printing than the limit | The program never runs again. There is no line number |
| `budget` | One decision used more than the instruction budget | The program never runs again |

What the program did before the error stays done. After an Arena program stops, the table stays as it is and its rules keep running. When a Flipper program stops, both flippers and the plunger are released.

You are told of every failure with a `program.failed` ([game-api.md](game-api.md#programfailed)), which carries the stage, the message and the last 16 lines the program printed.

## Limits

| Limit | Value |
| --- | --- |
| Instructions per decision, Arena | 200,000 |
| Instructions per decision, Flipper | 50,000 |
| Memory | 2 MiB |
| Source | 256 KiB |
| Printing per decision | 2,048 bytes and 256 print items (each value or string in a `PRINT`, and each line end, is one item) |
| Kept output | The last 16 lines |

A program that works on very long strings can reach a second, "work" limit before the instruction budget. It is reported as `budget` too.
