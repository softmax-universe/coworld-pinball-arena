## How one Episode must run: the build phase, three balls, ball save, extra
## balls, multiball, the clock, the search for a stuck ball, and the end.
##
## The tests call `advanceEpisode` directly and play the part of the driver:
## they clear the events of the last tick and count the ticks. Physics does
## not run here, so a ball only moves when a test moves it. Times that are a
## matter of tuning are tested with loose bounds.

import std/unittest
import pinball/sim/[simulation, episode, layout]

const
  Second = TicksPerSecond
  BuildTicks = 20
  LongestBallSave = 15 * Second
    ## The ball save that follows a launch must be over by now.
  LongestBallSearch = 30 * Second
    ## A stuck ball must be back at the plunger by now.
  OpenPlayfield = fixedVec2(260'fx, 400'fx)
    ## A place in the upper playfield, far from the drain and the plunger.

# --- Helpers -----------------------------------------------------------------

proc advance(game: var Table, ticks = 1, incoming: seq[Event] = @[]): seq[Event] {.discardable.} =
  ## Run `ticks` ticks of Episode bookkeeping and return every event of those
  ## ticks. `incoming` stands for the events that physics raised earlier in
  ## the first tick.
  for index in 0 ..< ticks:
    game.events = if index == 0: incoming else: @[]
    game.advanceEpisode()
    result.add game.events
    inc game.tick

proc count(events: seq[Event], kind: EventKind): int =
  for event in events:
    if event.kind == kind:
      inc result

proc find(events: seq[Event], kind: EventKind): Event =
  ## The first event of this kind, or an `evNone` event.
  for event in events:
    if event.kind == kind:
      return event

proc startedGame(): Table =
  ## A table just after the build phase: ball 1 waits on the plunger.
  result = initTable(TableSettings(buildPhaseTicks: BuildTicks))
  result.advance(BuildTicks + 1)
  doAssert result.phase == episodePlay, "the build phase did not end"
  doAssert result.balls.len == 1, "the first ball was not served"

proc atPlunger(ball: Ball): bool =
  ball.state == ballFree and distance(ball.pos, shooterLaneStart()) <= 1'fx

proc launch(game: var Table): seq[Event] {.discardable.} =
  ## Physics reports a launch. The ball itself stays where it is.
  game.advance(1, @[Event(kind: evBallLaunched, ballId: game.balls[0].id)])

proc launchAndOutlastSave(game: var Table) =
  game.launch()
  game.advance(LongestBallSave)
  doAssert game.ballSaveTicks == 0, "the ball save after a launch lasts too long"

proc drainFreeBalls(game: var Table): seq[Event] {.discardable.} =
  ## Drop every free ball far below the table, then give the table up to
  ## three seconds to serve the next ball, if one is due.
  for ball in game.balls.mitems:
    if ball.state == ballFree:
      ball.pos = fixedVec2(260'fx, fixed(int32(PlayfieldHeight + 200)))
  result = game.advance()
  var waited = 0
  while game.phase == episodePlay and game.balls.len == 0 and waited < 3 * Second:
    result.add game.advance()
    inc waited

proc stuckBallGame(): Table =
  ## Ball 1 lies still in the open playfield.
  result = startedGame()
  result.balls[0].pos = OpenPlayfield
  result.balls[0].vel = fixedVec2(0'fx, 0'fx)

# --- Tests -------------------------------------------------------------------

suite "episode":

  test "the build phase ends on time and the first ball is served to the plunger":
    var game = initTable(TableSettings(buildPhaseTicks: BuildTicks))
    let buildEvents = game.advance(BuildTicks)
    check game.phase == episodeBuild
    check game.balls.len == 0
    check buildEvents.len == 0

    let events = game.advance()
    check game.phase == episodePlay
    check game.ballNumber == 1
    check events.count(evBuildPhaseEnded) == 1
    check events.count(evBallAdded) == 1
    check events.find(evBallCountChanged).value == 1
    doAssert game.balls.len == 1
    check game.balls[0].atPlunger
    check game.balls[0].level == 1
    check game.balls[0].id > 0
    check events.find(evBallAdded).ballId == game.balls[0].id

  test "the Episode ends when the third ball drains":
    var game = startedGame()
    var ballNumbers: seq[int32]
    var ballIds: seq[int32]
    var events: seq[Event]
    for ball in 1 .. BallsPerEpisode:
      doAssert game.balls.len == 1
      check game.balls[0].atPlunger
      ballNumbers.add game.ballNumber
      ballIds.add game.balls[0].id
      game.launchAndOutlastSave()
      check game.phase == episodePlay
      events = game.drainFreeBalls()
      check events.find(evBallDrained).ballId == ballIds[^1]

    check ballNumbers == @[1'i32, 2, 3]
    check ballIds[0] != ballIds[1]
    check ballIds[1] != ballIds[2]
    check game.phase == episodeOver
    check game.endReason == endLastBallDrained
    check game.balls.len == 0
    check events.count(evEpisodeEnding) == 1
    doAssert game.ballTicks.len == 3
    for length in game.ballTicks:
      # Each ball was launched one tick after it was served and drained
      # `LongestBallSave` ticks later.
      check abs(length - LongestBallSave) <= Second

  test "a ball that drains just after launch is saved":
    var game = startedGame()
    game.launch()
    check game.ballSaveTicks > 0
    game.advance(Second)
    let events = game.drainFreeBalls()
    check events.count(evBallSaved) == 1
    check game.phase == episodePlay
    check game.ballNumber == 1
    check game.ballTicks.len == 0
    doAssert game.balls.len == 1
    check game.balls[0].atPlunger

  test "the automatic save returns one ball for each ball number, however often it is launched":
    var game = startedGame()
    game.launch()
    game.advance(Second)
    check game.drainFreeBalls().count(evBallSaved) == 1

    # The saved ball is launched again and drains at once: it is lost.
    game.launch()
    check game.ballSaveTicks == 0
    game.advance(Second)
    check game.drainFreeBalls().count(evBallSaved) == 0
    check game.ballNumber == 2

    # Ball 2 has a save of its own.
    game.launch()
    game.advance(Second)
    check game.drainFreeBalls().count(evBallSaved) == 1
    check game.ballNumber == 2

    # A save that a rule starts returns every ball that drains in its time.
    game.startBallSave(10 * Second)
    for _ in 1 .. 2:
      game.launch()
      game.advance(Second)
      check game.drainFreeBalls().count(evBallSaved) == 1
    check game.ballNumber == 2

  test "a ball that drains after the save has run out is lost":
    var game = startedGame()
    game.launchAndOutlastSave()
    let events = game.drainFreeBalls()
    check events.count(evBallSaved) == 0
    check events.count(evBallDrained) == 1
    check game.ballNumber == 2
    check game.ballTicks.len == 1

  test "a ball save started by a rule saves a ball until it runs out":
    var game = startedGame()
    game.startBallSave(Second)
    game.advance(Second div 2)
    let savedEvents = game.drainFreeBalls()
    check savedEvents.count(evBallSaved) == 1
    check game.ballNumber == 1
    doAssert game.balls.len == 1
    check game.balls[0].atPlunger

    var lateGame = startedGame()
    lateGame.startBallSave(Second)
    lateGame.advance(2 * Second)
    check lateGame.ballSaveTicks == 0
    let lostEvents = lateGame.drainFreeBalls()
    check lostEvents.count(evBallSaved) == 0
    check lateGame.ballNumber == 2

  test "an extra ball replays the same ball number":
    var game = startedGame()
    game.awardExtraBall()
    check game.extraBalls == 1

    game.drainFreeBalls()
    check game.phase == episodePlay
    check game.ballNumber == 1
    check game.extraBalls == 0
    check game.ballTicks.len == 1
    doAssert game.balls.len == 1
    check game.balls[0].atPlunger

    game.drainFreeBalls()
    check game.ballNumber == 2

  test "multiball: balls are added up to the limit and the ball ends with the last one":
    var game = startedGame()
    for ball in 2 .. MaxBallsInPlay:
      check game.addBall()
    doAssert game.balls.len == MaxBallsInPlay
    for first in 0 ..< game.balls.len:
      for second in first + 1 ..< game.balls.len:
        check game.balls[first].id != game.balls[second].id
    check not game.addBall()
    check game.balls.len == MaxBallsInPlay

    # One of the balls is caught by a saucer and one drains.
    let heldId = game.balls[0].id
    let lostId = game.balls[1].id
    game.balls[0].state = ballHeld
    game.balls[1].pos = fixedVec2(260'fx, fixed(int32(PlayfieldHeight + 200)))
    let events = game.advance()
    check events.find(evBallDrained).ballId == lostId
    check events.find(evBallCountChanged).value == MaxBallsInPlay - 1
    check game.balls.len == MaxBallsInPlay - 1
    check game.ballNumber == 1
    check game.ballTicks.len == 0

    # Every free ball drains. The held ball keeps ball 1 alive.
    game.drainFreeBalls()
    game.advance(Second)
    doAssert game.balls.len == 1
    check game.balls[0].id == heldId
    check game.phase == episodePlay
    check game.ballNumber == 1
    check game.ballTicks.len == 0

    # The saucer lets go and the last ball drains.
    game.balls[0].state = ballFree
    game.drainFreeBalls()
    check game.ballNumber == 2
    check game.ballTicks.len == 1
    check game.balls.len == 1

  test "a locked ball is replaced at the plunger, and the ball ends when the other one drains":
    var game = startedGame()
    game.launchAndOutlastSave()
    game.components.add Component(id: 1, kind: ckBallLock, phase: phaseSolid)
    let lockedId = game.balls[0].id
    game.balls[0].state = ballHeld
    game.balls[0].holderId = 1

    let events = game.advance()
    check events.count(evBallAdded) == 1
    doAssert game.balls.len == 2
    check game.balls[1].atPlunger
    check game.ballNumber == 1
    check game.ballTicks.len == 0
    game.advance(Second)
    check game.balls.len == 2

    # The served ball drains: ball 1 is over, and the locked ball stays locked.
    game.drainFreeBalls()
    check game.phase == episodePlay
    check game.ballNumber == 2
    check game.ballTicks.len == 1
    doAssert game.balls.len == 2
    check game.balls[0].id == lockedId
    check game.balls[0].state == ballHeld
    check game.balls[1].atPlunger

  test "a tilt is cleared when the ball ends":
    var game = startedGame()
    game.tilted = true
    game.tiltWarnings = TiltWarningLimit
    game.advance(Second)
    check game.tilted
    game.drainFreeBalls()
    check game.ballNumber == 2
    check not game.tilted
    check game.tiltWarnings == 0

  test "the clock raises an event each minute and ends the Episode at 8 minutes":
    var game = stuckBallGame()
    game.balls[0].vel = fixedVec2(0'fx, 300'fx)   # In play and moving.

    game.tick = uint32(3 * 60 * Second - 5)
    let minuteEvents = game.advance(10)
    check minuteEvents.count(evClockThreshold) == 1
    check minuteEvents.find(evClockThreshold).value == 3
    check game.phase == episodePlay

    game.tick = uint32(EpisodeClockTicks - 5)
    let beforeEnd = game.advance(5)
    check game.phase == episodePlay
    check beforeEnd.count(evEpisodeEnding) == 0
    let endEvents = game.advance(2)
    check game.phase == episodeOver
    check game.endReason == endClock
    check endEvents.count(evEpisodeEnding) == 1

  test "a stuck ball in the playfield is returned to the plunger":
    var game = stuckBallGame()
    game.advance(2 * Second)
    check game.balls[0].pos == OpenPlayfield   # Not stuck for long enough yet.

    var waited = 0
    while not game.balls[0].atPlunger and waited < LongestBallSearch:
      game.advance()
      inc waited
    check game.balls.len == 1
    check game.balls[0].atPlunger
    check game.ballNumber == 1
    check game.ballTicks.len == 0

  test "a ball that has stopped on a track is returned to the plunger":
    var game = stuckBallGame()
    game.balls[0].state = ballOnTrack
    game.balls[0].level = 2
    game.advance(LongestBallSearch)
    check game.balls[0].atPlunger
    check game.balls[0].level == 1
    check game.ballNumber == 1

  test "balls that are not stuck are never searched for":
    # Waiting on the plunger.
    var waiting = startedGame()
    let waitingBall = waiting.balls[0]
    waiting.advance(LongestBallSearch)
    check waiting.balls == @[waitingBall]

    # Held in a component.
    var held = stuckBallGame()
    held.balls[0].state = ballHeld
    held.advance(LongestBallSearch)
    check held.balls[0].pos == OpenPlayfield

    # Cradled: at rest while a flipper is held up.
    var cradled = stuckBallGame()
    cradled.flippers[flipperLeft].pressed = true
    cradled.flippers[flipperLeft].angle = FlipperStroke
    cradled.advance(LongestBallSearch)
    check cradled.balls[0].pos == OpenPlayfield

    # Rolling: physics would be moving this ball.
    var rolling = stuckBallGame()
    rolling.balls[0].vel = fixedVec2(0'fx, 300'fx)
    rolling.advance(LongestBallSearch)
    check rolling.balls[0].pos == OpenPlayfield

  test "floating messages expire":
    var game = startedGame()
    game.floatingMessages.add FloatingMessage(componentId: 1, text: "SHORT", ticksLeft: 3)
    game.floatingMessages.add FloatingMessage(componentId: 2, text: "LONG", ticksLeft: 10)
    game.advance(3)
    doAssert game.floatingMessages.len == 1
    check game.floatingMessages[0].text == "LONG"
    check game.floatingMessages[0].ticksLeft == 7
    game.advance(7)
    check game.floatingMessages.len == 0

  test "an ended Episode stays ended":
    var game = startedGame()
    for ball in 1 .. BallsPerEpisode:
      game.drainFreeBalls()
    doAssert game.phase == episodeOver

    game.tick = uint32(EpisodeClockTicks - 5)
    let events = game.advance(10)
    check events.len == 0
    check game.phase == episodeOver
    check game.endReason == endLastBallDrained
    check game.balls.len == 0
    check game.ballTicks.len == BallsPerEpisode
