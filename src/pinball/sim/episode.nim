## The flow of one Episode: a build phase, then three balls, ending when the
## third ball drains or the clock runs out. Also ball save, extra balls,
## multiball, the end of a tilt, and the ball search for a stuck ball.

import types, layout, components

const
  # Starting values for playtest.
  LaunchBallSaveTicks = 8 * TicksPerSecond
    ## The ball save that starts by itself when a ball is launched.
  ClockMinuteTicks = 60 * TicksPerSecond
  QuietSpeed = 30'fx
    ## In mm/s. A free ball slower than this counts as not moving. A rolling
    ## ball passes this within a few ticks, even on the gentle slope.
  BallSearchTicks = 5 * TicksPerSecond
    ## A ball this long without moving makes the table fire its kickers and magnets.
  BallRescueTicks = 10 * TicksPerSecond
    ## A ball this long without moving is put back on the plunger.
  LaneBallSpacing = BallRadius * 2 + 1'fx
    ## In mm. Balls that wait in the shooter lane together sit this far apart.

# --- Serving -------------------------------------------------------------------

proc ballsInPlay(table: Table): int32 =
  ## Held balls and balls on a track count: they will come back.
  int32(table.balls.len)

proc emitBallCount(table: var Table) =
  table.emit Event(kind: evBallCountChanged, value: table.ballsInPlay)

proc waitsInShooterLane(ball: Ball): bool =
  ## True for a free ball on the plunger or in the queue of balls above it.
  let offset = ball.pos - shooterLaneStart()
  ball.state == ballFree and
    abs(offset.x) <= BallRadius and
    offset.y <= BallRadius and
    offset.y >= -LaneBallSpacing * MaxBallsInPlay

proc freeLaneSpot(table: Table): FixedVec2 =
  ## The plunger, or the first free place above it when balls already wait
  ## there. The waiting balls then roll down and are launched together.
  result = shooterLaneStart()
  var searching = true
  while searching:
    searching = false
    for ball in table.balls:
      if ball.state == ballFree and distance(ball.pos, result) < LaneBallSpacing:
        result.y -= LaneBallSpacing
        searching = true

proc serveBall(table: var Table) =
  let ball = Ball(id: table.nextBallId, state: ballFree, pos: table.freeLaneSpot(), level: 1)
  inc table.nextBallId
  table.balls.add ball
  table.emit Event(kind: evBallAdded, ballId: ball.id, level: ball.level)
  table.emitBallCount()

proc addBall*(table: var Table): bool =
  ## Serve one more ball to the shooter lane. False at the multiball limit.
  if table.ballsInPlay >= MaxBallsInPlay:
    return false
  table.serveBall()
  true

proc startBallSave*(table: var Table, ticks: int32) =
  ## A ball that drains within `ticks` from now is returned to the plunger.
  ## This is the save that a rule starts. It takes over from a running
  ## automatic save, so it is not cut short when that one returns its ball.
  table.ballSaveTicks = max(table.ballSaveTicks, ticks)
  if table.launchSave == launchSaveRunning:
    table.launchSave = launchSaveSpent

proc awardExtraBall*(table: var Table) =
  inc table.extraBalls

# --- The steps of a tick -------------------------------------------------------

proc endEpisode(table: var Table, reason: EndReason) =
  table.phase = episodeOver
  table.endReason = reason
  table.emit Event(kind: evEpisodeEnding)

proc recordBallLength(table: var Table) =
  table.ballTicks.add int32(table.tick - table.ballStartTick)

proc startBallNumber(table: var Table, number: int32) =
  table.ballNumber = number
  table.ballStartTick = table.tick
  table.launchSave = launchSaveReady
  table.serveBall()

proc endBuildPhase(table: var Table) =
  table.phase = episodePlay
  table.emit Event(kind: evBuildPhaseEnded)
  table.startBallNumber(1)

proc runClock(table: var Table) =
  if table.tick >= EpisodeClockTicks:
    table.recordBallLength()
    table.endEpisode(endClock)
  elif table.tick mod ClockMinuteTicks == 0:
    table.emit Event(kind: evClockThreshold, value: int32(table.tick div ClockMinuteTicks))

proc runBallSave(table: var Table) =
  ## The automatic save starts at the first launch of a ball number only. If
  ## every launch started one, a ball that kept draining at once would come
  ## back for ever.
  for event in table.events:
    if event.kind == evBallLaunched and table.launchSave == launchSaveReady:
      table.launchSave = launchSaveRunning
      table.ballSaveTicks = max(table.ballSaveTicks, LaunchBallSaveTicks)
  if table.ballSaveTicks > 0:
    dec table.ballSaveTicks

proc endBall(table: var Table) =
  ## The last ball in play is lost: the tilt ends, and the next ball is
  ## served or the Episode ends.
  table.tilted = false
  table.tiltWarnings = 0
  table.tiltMeterTicks = 0
  table.recordBallLength()
  if table.extraBalls > 0:
    dec table.extraBalls
    table.startBallNumber(table.ballNumber)
  elif table.ballNumber < BallsPerEpisode:
    table.startBallNumber(table.ballNumber + 1)
  else:
    table.endEpisode(endLastBallDrained)

proc handleDrains(table: var Table) =
  var index = 0
  while index < table.balls.len:
    let ball = table.balls[index]
    if ball.state != ballFree or not isDrained(ball.pos):
      inc index
      continue
    table.balls.delete index
    table.emit Event(kind: evBallDrained, ballId: ball.id)
    table.emitBallCount()
    if table.ballSaveTicks > 0:
      table.emit Event(kind: evBallSaved, ballId: ball.id)
      table.serveBall()
      if table.launchSave == launchSaveRunning:
        table.launchSave = launchSaveSpent
        table.ballSaveTicks = 0
    elif table.ballsInPlay == 0:
      table.endBall()

proc searchForStuckBalls(table: var Table) =
  ## A ball at rest on a held flipper is a cradle, not a stuck ball. The
  ## table cannot tell which ball is cradled, so no free ball counts as stuck
  ## while a flipper is held up. A ball can also come to rest on a level
  ## stretch of track, where nothing but the rescue will move it again.
  let flipperHeld = table.flippers[flipperLeft].pressed or table.flippers[flipperRight].pressed
  var searchNow = false
  for index in 0 ..< table.balls.len:
    let ball = table.balls[index]
    let slow = abs(ball.vel.x) < QuietSpeed and abs(ball.vel.y) < QuietSpeed
    let quiet =
      case ball.state
      of ballFree: slow and not flipperHeld and not ball.waitsInShooterLane
      of ballOnTrack: slow
      of ballHeld: false
    if not quiet:
      table.balls[index].quietTicks = 0
      continue
    inc table.balls[index].quietTicks
    if ball.quietTicks + 1 == BallSearchTicks:
      searchNow = true
    elif ball.quietTicks + 1 >= BallRescueTicks:
      let spot = table.freeLaneSpot()
      table.balls[index] = Ball(id: ball.id, state: ballFree, pos: spot, level: 1)
      if ball.level != 1:
        table.emit Event(kind: evBallChangedLevel, ballId: ball.id, level: 1, value: 1)
  if searchNow:
    table.ballSearch()

proc expireFloatingMessages(table: var Table) =
  var index = 0
  while index < table.floatingMessages.len:
    dec table.floatingMessages[index].ticksLeft
    if table.floatingMessages[index].ticksLeft <= 0:
      table.floatingMessages.delete index
    else:
      inc index

proc advanceEpisode*(table: var Table) =
  ## One tick of Episode bookkeeping: end the build phase and serve the first
  ## ball, handle drained balls, serve the next ball, run the clock, search
  ## for stuck balls, and end the Episode.
  if table.phase == episodeOver:
    return
  table.expireFloatingMessages()
  if table.phase == episodeBuild:
    if table.tick >= uint32(table.settings.buildPhaseTicks):
      table.endBuildPhase()
    return
  table.runClock()
  if table.phase == episodeOver:
    return
  table.runBallSave()
  table.handleDrains()
  if table.phase == episodePlay:
    table.searchForStuckBalls()
