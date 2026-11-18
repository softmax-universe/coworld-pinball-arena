## How a ball must behave on track: mouths, the curve, the slope, ramps,
## rails and the small things that sit on track.
##
## No physics runs here. Each test puts the pieces on an empty table by hand
## and calls `stepTracks` once per tick. A free ball moves in a straight line
## between ticks, which stands in for the physics. Control points are table
## coordinates. Floats are used only to judge results.

import std/[math, unittest]
import pinball/sim/[types, catalogue, tracks]

const
  SlopeGravity = toFloat64(layout.SlopeGravity)   ## mm/s^2 along +y, as in the physics tests.
  BallId = 1'i32
  TrackId = 10'i32
  MouthAId = 11'i32
  MouthBId = 12'i32
  # The usual track of these tests runs level across the table, so the slope
  # does not act on it. Mouth A opens to the left and mouth B to the right.
  MouthAX = 150.0
  MouthBX = 400.0
  FlatY = 500.0

type
  Log = object
    ## Everything `stepTracks` reported over the ticks of one test.
    events: seq[Event]
    contacts: seq[Contact]

# --- Helpers -----------------------------------------------------------------

proc vec(x, y: float): FixedVec2 =
  fixedVec2(toFixed(x), toFixed(y))

proc point(vector: FixedVec2): tuple[x, y: float] =
  (toFloat64(vector.x), toFloat64(vector.y))

proc gap(a, b: FixedVec2): float =
  hypot(a.point.x - b.point.x, a.point.y - b.point.y)

proc speed(ball: Ball): float =
  hypot(ball.vel.point.x, ball.vel.point.y)

proc addPiece(game: var Table, id: int32, kind: ComponentKind, x, y, rotation: float,
              level = 1, phase = phaseSolid) =
  game.components.add Component(
    id: id, kind: kind, pos: vec(x, y), rotation: toFixed(rotation),
    sizePercent: 100, level: int32(level), settings: defaultSettings(kind), phase: phase)

proc addTrack(game: var Table, id, mouthA, mouthB: int32, level = 1,
              controlA = (x: 0.0, y: 0.0), controlB = (x: 0.0, y: 0.0),
              phase = phaseSolid) =
  game.addPiece(id, ckTrack, 0, 0, 0, level, phase)
  game.components[^1].settings[setMouthA] = toFixed(float(mouthA))
  game.components[^1].settings[setMouthB] = toFixed(float(mouthB))
  game.components[^1].settings[setControlAX] = toFixed(controlA.x)
  game.components[^1].settings[setControlAY] = toFixed(controlA.y)
  game.components[^1].settings[setControlBX] = toFixed(controlB.x)
  game.components[^1].settings[setControlBY] = toFixed(controlB.y)

proc flatTrack(levelB = 1): Table =
  ## The usual track. With `levelB` 2 it is a ramp that climbs from A to B.
  result.addPiece(MouthAId, ckMouth, MouthAX, FlatY, 180)
  result.addPiece(MouthBId, ckMouth, MouthBX, FlatY, 0, levelB)
  result.addTrack(TrackId, MouthAId, MouthBId, levelB)

proc uphillTrack(): Table =
  ## Mouth A is the lower end, near the player. Mouth B is 300 mm up the table.
  result.addPiece(MouthAId, ckMouth, 250, 650, 90)
  result.addPiece(MouthBId, ckMouth, 250, 350, 270)
  result.addTrack(TrackId, MouthAId, MouthBId)

proc addBall(game: var Table, x, y, velX, velY: float, level = 1) =
  game.balls.add Ball(id: BallId, pos: vec(x, y), vel: vec(velX, velY), level: int32(level))

proc rollIntoA(game: var Table, speed: float) =
  ## A ball just outside mouth A of the usual track, rolling straight in.
  game.addBall(MouthAX - 30, FlatY, speed, 0)

proc piece(game: Table, id: int32): Component =
  game.components[game.componentIndex(id)]

proc tick(game: var Table, log: var Log) =
  for ball in game.balls.mitems:
    if ball.state == ballFree:
      ball.pos = ball.pos + ball.vel / int32(TicksPerSecond)
  game.events.setLen(0)
  game.contacts.setLen(0)
  game.stepTracks()
  log.events.add game.events
  log.contacts.add game.contacts

proc has(log: Log, kind: EventKind, componentId = -1, value = -1): bool =
  for event in log.events:
    if event.kind == kind and
        (componentId < 0 or event.componentId == componentId) and
        (value < 0 or event.value == value):
      return true
  false

proc touched(log: Log, componentId: int32): bool =
  for contact in log.contacts:
    if contact.componentId == componentId and contact.ballId == BallId:
      return true
  false

proc rollUntil(game: var Table, log: var Log, kind: EventKind, maxTicks: int,
               componentId = -1): bool =
  ## Runs until an event of this kind has been raised. False if it never is.
  for _ in 0 ..< maxTicks:
    if log.has(kind, componentId):
      return true
    game.tick(log)
  log.has(kind, componentId)

proc rollToTrackEnd(game: var Table, log: var Log, maxTicks = 1200) =
  ## Runs until the ball has completed or failed a track.
  for _ in 0 ..< maxTicks:
    if log.has(evTrackCompleted) or log.has(evTrackFailed):
      return
    game.tick(log)

proc entersTrack(game: var Table): bool =
  var log: Log
  game.rollUntil(log, evTrackEntered, 40)

proc exitSpeed(game: var Table): float =
  ## The speed at which the ball leaves by the far mouth, or 0 if it does not.
  var log: Log
  game.rollToTrackEnd(log)
  if log.has(evTrackCompleted): game.balls[0].speed else: 0.0

# --- Tests -------------------------------------------------------------------

suite "tracks":
  test "a ball rolling into a mouth rides the track and leaves by the other mouth":
    var
      game = flatTrack()
      log: Log
    game.rollIntoA(800)

    check game.rollUntil(log, evTrackEntered, 20)
    check log.has(evTrackEntered, TrackId, MouthAId)
    check game.balls[0].state == ballOnTrack
    check game.balls[0].holderId == TrackId
    check game.balls[0].trackEntryMouthId == MouthAId
    check game.balls[0].trackSpeed > 0'fx

    var
      ticksOnTrack = 0
      stayedOnCurve = true
      lastDistance = game.balls[0].trackDistance
    for _ in 0 ..< 240:
      game.tick(log)
      let ball = game.balls[0]
      if ball.state != ballOnTrack:
        break
      inc ticksOnTrack
      if gap(ball.pos, trackPoint(game, game.piece(TrackId), ball.trackDistance)) > 1.0 or
          ball.trackDistance <= lastDistance:
        stayedOnCurve = false
      lastDistance = ball.trackDistance
    check ticksOnTrack >= 10
    check stayedOnCurve

    let ball = game.balls[0]
    check log.has(evTrackCompleted, TrackId)
    check not log.has(evTrackFailed)
    check ball.state == ballFree
    check gap(ball.pos, game.piece(MouthBId).pos) < 5.0
    check ball.vel.point.x > 0.0
    check abs(ball.vel.point.y) < 0.05 * ball.speed
    check ball.speed > 0.5 * 800
    check ball.speed < 1.01 * 800

  test "a ball can enter by mouth B and leave by mouth A":
    var
      game = flatTrack()
      log: Log
    game.addBall(MouthBX + 30, FlatY, -800, 0)

    check game.rollUntil(log, evTrackEntered, 20)
    check log.has(evTrackEntered, TrackId, MouthBId)
    check game.balls[0].trackEntryMouthId == MouthBId
    check game.balls[0].trackSpeed < 0'fx

    game.rollToTrackEnd(log)
    check log.has(evTrackCompleted, TrackId)
    check game.balls[0].state == ballFree
    check gap(game.balls[0].pos, game.piece(MouthAId).pos) < 5.0
    check game.balls[0].vel.point.x < 0.0

  test "only a ball moving into a mouth on its own level is captured":
    var rollingIn = flatTrack()
    rollingIn.addBall(MouthBX + 30, FlatY, -600, 0)
    check rollingIn.entersTrack()

    var crossing = flatTrack()
    crossing.addBall(MouthBX, FlatY - 60, 0, 600)
    check not crossing.entersTrack()
    check crossing.balls[0].state == ballFree

    var movingOut = flatTrack()
    movingOut.addBall(MouthBX, FlatY, 600, 0)
    check not movingOut.entersTrack()

    var onAnotherLevel = flatTrack()
    onAnotherLevel.addBall(MouthBX + 30, FlatY, -600, 0, level = 2)
    check not onAnotherLevel.entersTrack()

  test "a track captures nothing until all three of its pieces are solid":
    var noMouthB: Table
    noMouthB.addPiece(MouthAId, ckMouth, MouthAX, FlatY, 180)
    noMouthB.addTrack(TrackId, MouthAId, MouthBId)
    noMouthB.rollIntoA(600)
    check not noMouthB.entersTrack()
    check noMouthB.balls[0].state == ballFree

    var mouthBeamingIn: Table
    mouthBeamingIn.addPiece(MouthAId, ckMouth, MouthAX, FlatY, 180)
    mouthBeamingIn.addPiece(MouthBId, ckMouth, MouthBX, FlatY, 0, phase = phaseBeamingIn)
    mouthBeamingIn.addTrack(TrackId, MouthAId, MouthBId)
    mouthBeamingIn.rollIntoA(600)
    check not mouthBeamingIn.entersTrack()

    var trackBeamingIn: Table
    trackBeamingIn.addPiece(MouthAId, ckMouth, MouthAX, FlatY, 180)
    trackBeamingIn.addPiece(MouthBId, ckMouth, MouthBX, FlatY, 0)
    trackBeamingIn.addTrack(TrackId, MouthAId, MouthBId, phase = phaseBeamingIn)
    trackBeamingIn.rollIntoA(600)
    check not trackBeamingIn.entersTrack()

    # The same track works once the last piece is solid.
    trackBeamingIn.components[^1].phase = phaseSolid
    trackBeamingIn.balls.setLen(0)
    trackBeamingIn.rollIntoA(600)
    check trackBeamingIn.entersTrack()

  test "the curve runs from throat to throat and bends toward its control points":
    let straight = flatTrack()
    let
      straightPiece = straight.piece(TrackId)
      straightLength = trackLength(straight, straightPiece)
      throatA = trackPoint(straight, straightPiece, 0'fx)
      throatB = trackPoint(straight, straightPiece, straightLength)
    # Each throat lies a short way behind the open end of its mouth.
    check abs(throatA.point.y - FlatY) < 1.0
    check throatA.point.x > MouthAX - 1.0
    check throatA.point.x < MouthAX + 80.0
    check abs(throatB.point.y - FlatY) < 1.0
    check throatB.point.x < MouthBX + 1.0
    check throatB.point.x > MouthBX - 80.0
    check abs(toFloat64(straightLength) - gap(throatA, throatB)) < 1.0

    # Both control points lie 150 mm toward the player, so the middle of the
    # curve is at (275, 612.5), far from the straight line at y 500.
    var curved: Table
    curved.addPiece(MouthAId, ckMouth, MouthAX, FlatY, 180)
    curved.addPiece(MouthBId, ckMouth, MouthBX, FlatY, 0)
    curved.addTrack(TrackId, MouthAId, MouthBId,
                    controlA = (x: 180.0, y: 650.0), controlB = (x: 370.0, y: 650.0))
    let
      curvedPiece = curved.piece(TrackId)
      curvedLength = trackLength(curved, curvedPiece)
      middle = vec(275, 612.5)
    check gap(trackPoint(curved, curvedPiece, 0'fx), throatA) < 1.0
    check gap(trackPoint(curved, curvedPiece, curvedLength), throatB) < 1.0
    check toFloat64(curvedLength) > toFloat64(straightLength) + 20.0
    check gap(trackPoint(curved, curvedPiece, curvedLength / 2'i32), middle) < 8.0

    var
      log: Log
      nearestToMiddle = 1000.0
    curved.rollIntoA(1000)
    for _ in 0 ..< 600:
      curved.tick(log)
      if curved.balls[0].state == ballOnTrack:
        nearestToMiddle = min(nearestToMiddle, gap(curved.balls[0].pos, middle))
    check nearestToMiddle < 15.0
    check log.has(evTrackCompleted, TrackId)

  test "a slow ball on a track that runs up the table rolls back out":
    var
      game = uphillTrack()
      log: Log
    game.addBall(250, 680, 0, -100)
    check game.rollUntil(log, evTrackEntered, 20)
    game.rollToTrackEnd(log)
    check log.has(evTrackFailed, TrackId)
    check not log.has(evTrackCompleted)
    check game.balls[0].state == ballFree
    check game.balls[0].vel.point.y > 0.0
    check gap(game.balls[0].pos, game.piece(MouthAId).pos) < 5.0

  test "a fast ball climbs a track that runs up the table and loses speed":
    var game = uphillTrack()
    game.addBall(250, 680, 0, -3000)
    let leavingSpeed = game.exitSpeed()
    check leavingSpeed > 0.0
    check leavingSpeed < 3000.0
    check game.balls[0].vel.point.y < 0.0
    # It cannot lose less than the slope takes over the climb between throats.
    let piece = game.piece(TrackId)
    let climb = trackPoint(game, piece, 0'fx).point.y -
      trackPoint(game, piece, trackLength(game, piece)).point.y
    check leavingSpeed * leavingSpeed < 3000.0 * 3000.0 - SlopeGravity * climb

  test "a ball leaves a track that runs down the table faster than it entered":
    var game: Table
    game.addPiece(MouthAId, ckMouth, 250, 350, 270)
    game.addPiece(MouthBId, ckMouth, 250, 650, 90)
    game.addTrack(TrackId, MouthAId, MouthBId)
    game.addBall(250, 320, 0, 300)
    check game.exitSpeed() > 300.0
    check game.balls[0].vel.point.y > 0.0

  test "a ramp takes more speed to climb than the same track laid flat":
    var flat = flatTrack()
    flat.rollIntoA(300)
    check flat.exitSpeed() > 0.0

    var
      slowOnRamp = flatTrack(levelB = 2)
      slowLog: Log
    slowOnRamp.rollIntoA(300)
    slowOnRamp.rollToTrackEnd(slowLog)
    check slowLog.has(evTrackFailed, TrackId)
    check not slowLog.has(evTrackCompleted)
    check slowOnRamp.balls[0].level == 1

    var fastOnFlat = flatTrack()
    fastOnFlat.rollIntoA(2500)
    var fastOnRamp = flatTrack(levelB = 2)
    fastOnRamp.rollIntoA(2500)
    let rampExitSpeed = fastOnRamp.exitSpeed()
    check rampExitSpeed > 0.0
    check rampExitSpeed < fastOnFlat.exitSpeed()

  test "a ball on a ramp is on the upper level and lands on level 1 when it leaves":
    var
      game = flatTrack(levelB = 2)
      log: Log
    game.rollIntoA(2500)
    check game.rollUntil(log, evTrackEntered, 20)
    check game.balls[0].level == 2
    check log.has(evBallChangedLevel, value = 2)
    check not log.has(evBallChangedLevel, value = 1)

    var alwaysRaised = true
    for _ in 0 ..< 600:
      game.tick(log)
      if game.balls[0].state != ballOnTrack:
        break
      if game.balls[0].level != 2:
        alwaysRaised = false
    check alwaysRaised
    check log.has(evTrackCompleted, TrackId)
    check game.balls[0].state == ballFree
    check game.balls[0].level == 1
    check log.has(evBallChangedLevel, value = 1)
    check gap(game.balls[0].pos, game.piece(MouthBId).pos) < 5.0

  test "a ball gains speed rolling down a ramp":
    var game = flatTrack(levelB = 2)
    game.addBall(MouthBX + 30, FlatY, -300, 0, level = 2)
    check game.exitSpeed() > 300.0
    check game.balls[0].level == 1

  test "a ball leaving a ramp into the mouth of a rail continues on the rail":
    const
      RailId = 30'i32
      RailEntryId = 31'i32
      RailExitId = 32'i32
    var
      game: Table
      log: Log
    # The ramp climbs from x 80 to x 250. The rail starts where the ramp ends
    # and runs on level 2 to x 420.
    game.addPiece(MouthAId, ckMouth, 80, FlatY, 180)
    game.addPiece(MouthBId, ckMouth, 250, FlatY, 0, level = 2)
    game.addTrack(TrackId, MouthAId, MouthBId, level = 2)
    game.addPiece(RailEntryId, ckMouth, 250, FlatY, 180, level = 2)
    game.addPiece(RailExitId, ckMouth, 420, FlatY, 0, level = 2)
    game.addTrack(RailId, RailEntryId, RailExitId, level = 2)
    game.addBall(50, FlatY, 2500, 0)

    check game.rollUntil(log, evTrackEntered, 20)
    var stayedRaised = true
    for _ in 0 ..< 600:
      if game.balls[0].holderId == RailId and game.balls[0].state == ballOnTrack:
        break
      game.tick(log)
      if game.balls[0].level != 2:
        stayedRaised = false
    check game.balls[0].state == ballOnTrack
    check game.balls[0].holderId == RailId
    check stayedRaised
    check log.has(evTrackCompleted, TrackId)
    check log.has(evTrackEntered, RailId, RailEntryId)
    check not log.has(evBallChangedLevel, value = 1)

    check game.rollUntil(log, evTrackCompleted, 600, RailId)
    check game.balls[0].state == ballFree
    check game.balls[0].level == 1
    check gap(game.balls[0].pos, game.piece(RailExitId).pos) < 5.0

  test "a rollover on the track reports the ball that passes over it":
    const
      OnTrackId = 20'i32
      AboveTrackId = 21'i32
    var
      game = flatTrack()
      log: Log
    game.addPiece(OnTrackId, ckRollover, 275, FlatY, 0)
    game.addPiece(AboveTrackId, ckRollover, 300, FlatY, 0, level = 2)
    game.rollIntoA(800)
    game.rollToTrackEnd(log)
    check log.has(evTrackCompleted, TrackId)
    check log.touched(OnTrackId)
    check not log.touched(AboveTrackId)

  test "a gate on the track passes a ball one way and turns it back the other way":
    const GateId = 22'i32

    var
      withGate = flatTrack()
      passLog: Log
    withGate.addPiece(GateId, ckGate, 275, FlatY, 0)
    withGate.rollIntoA(800)
    withGate.rollToTrackEnd(passLog)
    check passLog.has(evTrackCompleted, TrackId)
    var passed = false
    for contact in passLog.contacts:
      if contact.componentId == GateId and contact.ballId == BallId and contact.passed:
        passed = true
    check passed

    var
      againstGate = flatTrack()
      blockLog: Log
    againstGate.addPiece(GateId, ckGate, 275, FlatY, 180)
    againstGate.rollIntoA(800)
    againstGate.rollToTrackEnd(blockLog)
    check blockLog.has(evTrackFailed, TrackId)
    check not blockLog.has(evTrackCompleted)
    check againstGate.balls[0].vel.point.x < 0.0
    check gap(againstGate.balls[0].pos, againstGate.piece(MouthAId).pos) < 5.0
