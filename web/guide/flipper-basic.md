# Pinball Arena: the Flipper BASIC guide

The **Flipper player** plays the pinball: two flippers, the plunger and nudges. In the browser
that is usually a person. A BASIC program can hold the seat too, and so can direct control
through the game API. This guide is for whoever plays the seat that way.

## The aim

Score as many points as you can in one Episode.

- An Episode is a build phase (10 seconds at most, in which the Arena program lays the
  table), then **three balls**, then it is over. It also ends when the clock reaches
  **8 minutes** of play. The clock starts when the first ball is served.
- **The table decides what scores.** The game itself awards nothing. Every point comes from
  the rules of the Arena program, and a table with no rules gives a score of 0. The bundled
  house table is described in section 10 of the Arena guide.
- **A Flipper program cannot read the rules.** It sees the pieces and their lamps, and not
  the state machines behind them or the text in the two message boxes. A lit or flashing
  lamp (`pieces(i).lamp`) is the table's way of pointing at a goal. You can read more than
  your program can: the `state` request of the game API also gives the two messages and
  the current node of every FSM.
- The table can change during play: the Arena program may add, move and remove pieces.
  A new or moved piece is a hologram for half a second (`pieces(i).phase` is
  `phase_beamingin`) and touches nothing until it is solid.

## How a program runs

The program runs from its first line to its last **60 times a second** (every 2 ticks; a
tick is 1/120 s), from the start of the build phase. Variables and arrays keep their values
between runs, and a variable that was never assigned is 0. One run may use 50,000
instructions.

The language is Bassy BASIC. Section 3 of the Arena guide lists how it differs from QBasic,
and all of it holds for this seat. Section 8 of the Arena guide lists the view and the
constants, and section 7 the maths calls. A Flipper program has none of the Arena calls
(`create`, `fsm`, ...), and an Arena program has none of the three calls below.

A run-time error or a run over the instruction budget stops the program for good, and the
flippers and the plunger are released. Because the program runs again 60 times a second, a
loop that waits for something never ends: test the condition once per run with `IF`.

## What you can do

| Call | Effect |
| --- | --- |
| `flip(side, pressed)` | Press (1) or release (0) a flipper. `side` is `left` or `right` |
| `plunger(pressed)` | Pull the plunger (1) or let it go (0) |
| `nudge(direction)` | Shove the table: `nudge_left`, `nudge_right` or `nudge_up` |

Each returns 1, or `-reject_notallowed` once the Episode is over. A press stays until you
release it, so call `flip` only when the state should change.

## What you can see

Before each run the host fills the view: `tick`, `phase`, `ballnumber`, `score`,
`clockseconds`, `leftangle` and `rightangle`, `leftpressed` and `rightpressed`,
`plungerpull`, `tiltwarnings`, `tilted`, the `balls` records (position, speed, level, state)
and the `pieces` records (every piece on the table with its kind, place, rotation, size,
level, group, phase, lamp, and whether a drop target is down). Section 8 of the Arena guide
lists every field. The Arena names `budgetleft`, `fsmcount`, `rejectcount` and `lastreject`
are not there for this seat.

Positions are millimetres: `x` 0..520 to the right, `y` 0..1080 toward the player, so the
flippers are at large `y` and a ball moving up the table has a negative `vy`. Speeds are
mm/s.

## The mechanics that matter to this seat

**The ball.** 27 mm across. Gravity pulls it down the table at 1,250 mm/s². Its speed is
capped at 5,000 mm/s. A ball is lost when its centre passes `y` = 1045.

**Flippers.** Pivots at (157, 950) and (323, 950), 70 mm long. At rest a flipper lies 30
degrees below level, with its tip at (218, 985) or (262, 985); the gap between the tips is
33 mm, wider than the ball. A full stroke is 50 degrees (`leftangle` 0..50) and takes a few
ticks. Where on the blade the ball is when you flip changes where the shot goes. A held
flipper can cradle a ball. A rail on each side (the lane guide) feeds a ball onto its
flipper; outside the rail is the outlane, which leads to the drain.

**Plunger.** A served ball rests on the plunger at (498, 972), in the lane at the right
edge. Holding the plunger pulls it back: `plungerpull` goes from 0 to 1 in one second.
Releasing fires it at 3,000 mm/s times the pull. The ball goes up the lane and
anticlockwise along the top arch. Nothing launches a ball for you: a program that never
plunges scores 0 and its Episode lasts the full 8 minutes.

**Ball save.** The first launch of each ball number starts an 8 second save: a ball that
drains in that time comes back to the plunger, once. A rule of the table can start a
longer one.

**Nudge and tilt.** A nudge adds 60 mm/s to every free ball: to the left, to the right or
up the table. Each nudge also adds 180 ticks to a tilt meter that runs down by one per
tick. A nudge that takes the meter over 400 gives a warning (so three nudges within about a
second do, and one nudge every 1.5 seconds never does). After two warnings on a ball, the
next such nudge tilts: until the ball ends the flippers are dead, bumpers, slingshots,
kickers and kickbacks do not kick, and no ball save applies. The warnings and the tilt
clear when the ball ends.

**More than one ball.** Up to 6 balls can be in play. `balls(i).state` is `state_free`,
`state_held` (in a saucer, scoop, lock or magnet) or `state_ontrack` (on a ramp or other
track, where it touches nothing). The ball number ends when the last ball that is not in a
lock drains.

**A stuck ball.** A free ball that lies still for 5 seconds makes the table fire its
kickers and release held balls, and after 10 seconds the ball is put back on the plunger. A
ball on a held flipper does not count as stuck, and neither does a ball waiting on the
plunger.

**Extra balls and the pieces.** What each kind of piece does to the ball is in section 5 of
the Arena guide. Whether hitting it is worth anything is up to the table's rules.

**The game is exactly repeatable.** There is no randomness outside the programs, and
`rnd` gives a program the same numbers in every Episode. The same Flipper program on the
same table plays the same Episode every time, so a second run tells you nothing new.

## An example

This program was run in the game. On the house table it scores about 290,000.

```basic
' @seat flipper
' Plunges every ball, and raises a flipper while a ball comes down onto it.

' A ball that lies still at the bottom of the shooter lane is on the plunger.
' Pull until the plunger is 80 percent back, then let go.
onplunger = 0
for i = 0 to ballcount - 1
  if balls(i).x > 480 and balls(i).y > 950 and abs(balls(i).vy) < 20 then onplunger = 1
next
if onplunger = 1 and pulling = 0 then
  pulling = 1
  plunger(1)
end if
if pulling = 1 and plungerpull >= 0.8 then
  plunger(0)
  pulling = 0
end if

' A flipper is wanted while a free ball is falling just above it.
wantleft = 0
wantright = 0
for i = 0 to ballcount - 1
  if balls(i).state = state_free and balls(i).vy > 0 and balls(i).y > 900 and balls(i).y < 990 then
    if balls(i).x > 150 and balls(i).x <= 240 then wantleft = 1
    if balls(i).x > 240 and balls(i).x < 330 then wantright = 1
  end if
next
' Call flip only when the button must change.
if wantleft <> leftpressed then flip(left, wantleft)
if wantright <> rightpressed then flip(right, wantright)
```

## Deploying it

Deploy the program with `policy.create`, as the game API guide says. Its first lines must be
comments and one of them must be `' @seat flipper`, or it is taken for a table program. It
plays at once, and the person's keys do nothing while it does. The request
`{"method": "programs.activate", "params": {"seat": "flipper", "name": null}}` gives the
flippers back to the person, and the built-in program `demo` can be activated the same way.

A program that does not compile, or that fails while running, raises a `program.failed`
with `"seat": "flipper"`. For single moves, the request `run` with `"seat": "flipper"` runs
lines such as `flip(left, 1)` at once.

**The summary** of an Episode (section 1 of the Arena guide) is how you judge a Flipper
program: `score`, `endReason` (`lastBallDrained` or `clock`), `balls` (how many seconds each
ball lasted), `components` (how often each piece was hit) and `flipper.scriptError`. What a
Flipper program prints comes back only with an error, in its `output`.
