## The flow of one Episode: a build phase, then three balls, ending when the
## third ball drains or the clock runs out. Also ball save, extra balls,
## multiball, the end of a tilt, and the ball search for a stuck ball.
##
## Locked balls. A ball in a ball lock stays there until a rule releases it,
## so it cannot keep a ball number alive: only the other balls are "live".
## As on a real machine, the person always has a ball to play:
##
## - When a ball is locked and no live ball is left, a new ball is served to
##   the plunger. The ball number stays.
## - When the last live ball drains, the ball ends as usual (the next ball
##   number is served, or the Episode ends) and the locked balls stay locked.

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

proc isLocked(table: Table, ball: Ball): bool =
  if ball.state != ballHeld:
    return false
  let index = table.componentIndex(ball.holderId)
  index >= 0 and table.components[index].kind == ckBallLock

proc liveBalls(table: Table): int32 =
  ## See "Locked balls" at the top.
  for ball in table.balls:
    if not table.isLocked(ball):
      inc result

proc raiseEvent(table: var Table, event: Event, inTick: bool) =
  if inTick:
    table.emit event
  else:
    table.emitNext event

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

proc serveBall(table: var Table, inTick = true) =
  let ball = Ball(id: table.nextBallId, state: ballFree, pos: table.freeLaneSpot(), level: 1)
  inc table.nextBallId
  table.balls.add ball
  table.raiseEvent(Event(kind: evBallAdded, ballId: ball.id, level: ball.level), inTick)
  table.raiseEvent(Event(kind: evBallCountChanged, value: table.ballsInPlay), inTick)

proc addBall*(table: var Table): bool =
  ## Serve one more ball to the shooter lane. False at the multiball limit.
  ## This is the ball a rule adds, so rules see its events on the next tick.
  if table.ballsInPlay >= MaxBallsInPlay:
    return false
  table.serveBall(inTick = false)
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

proc buildIsDone(table: Table): bool =
  ## The build phase lasts until the Arena player says it is ready and every
  ## piece is solid, and `buildPhaseTicks` at the longest.
  if table.tick >= uint32(table.settings.buildPhaseTicks):
    return true
  if not table.buildReady:
    return false
  for component in table.components:
    if component.phase != phaseSolid:
      return false
  true

proc endBuildPhase(table: var Table) =
  table.phase = episodePlay
  table.playStartTick = table.tick
  table.emit Event(kind: evBuildPhaseEnded)
  table.startBallNumber(1)

proc runClock(table: var Table) =
  let clock = table.clockTicks
  if clock >= EpisodeClockTicks:
    table.recordBallLength()
    table.endEpisode(endClock)
  elif clock > 0 and clock mod ClockMinuteTicks == 0:
    table.emit Event(kind: evClockThreshold, value: clock div ClockMinuteTicks)

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
  ## The last live ball is lost: the tilt ends, and the next ball is
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
    table.emit Event(kind: evBallCountChanged, value: table.ballsInPlay)
    # A tilt costs the ball: no save brings a tilted ball back.
    if table.ballSaveTicks > 0 and not table.tilted:
      table.emit Event(kind: evBallSaved, ballId: ball.id)
      table.serveBall()
      if table.launchSave == launchSaveRunning:
        table.launchSave = launchSaveSpent
        table.ballSaveTicks = 0
    elif table.liveBalls == 0:
      table.endBall()

proc replaceLockedBall(table: var Table) =
  ## The last live ball has just been locked: see "Locked balls" at the top.
  if table.balls.len > 0 and table.liveBalls == 0:
    table.serveBall()

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

proc advanceEpisode*(table: var Table) =
  ## One tick of Episode bookkeeping: end the build phase and serve the first
  ## ball, handle drained balls, serve the next ball, run the clock, search
  ## for stuck balls, and end the Episode.
  if table.phase == episodeOver:
    return
  if table.phase == episodeBuild:
    if table.buildIsDone:
      table.endBuildPhase()
    return
  table.runClock()
  if table.phase == episodeOver:
    return
  table.runBallSave()
  table.handleDrains()
  if table.phase == episodePlay:
    table.replaceLockedBall()
    table.searchForStuckBalls()
