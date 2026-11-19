## How the ball, the flippers, the plunger and the fixed table must behave.
##
## The tests never say where the flippers, the shooter lane or the drain are:
## they ask `layout`. The only place they assume is that the middle of the
## upper playfield (around x 200, y 400) has no fixed parts, so obstacles for
## a test can stand there. Floats are used here only to judge results.

import std/[math, unittest]
import pinball/sim/[simulation, physics, layout]

const
  SlopeGravity = toFloat64(layout.SlopeGravity)   ## Rolling acceleration in mm/s^2 along +y.
  WallX = 250.0           ## Test obstacles are upright walls at this x.

type
  Point = tuple[x, y: float]
  FlipperShape = object
    pivot, tip: Point
    radius: float

# --- Helpers -----------------------------------------------------------------

proc vec(x, y: float): FixedVec2 =
  fixedVec2(toFixed(x), toFixed(y))

proc point(vector: FixedVec2): Point =
  (toFloat64(vector.x), toFloat64(vector.y))

proc speed(ball: Ball): float =
  hypot(toFloat64(ball.vel.x), toFloat64(ball.vel.y))

proc span(a, b: Point): float =
  hypot(b.x - a.x, b.y - a.y)

proc addBall(game: var Table, x, y: float, velX = 0.0, velY = 0.0,
    id = 1'i32, level = 1'i32) =
  game.balls.add Ball(id: id, state: ballFree, level: level,
    pos: vec(x, y), vel: vec(velX, velY))

proc addObstacle(game: var Table, id: int32, collider: Collider, level = 1'i32) =
  ## A solid component that is nothing but the given collision shape.
  var shape = collider
  shape.componentId = id
  game.components.add Component(id: id, kind: ckWall, level: level,
    sizePercent: 100, phase: phaseSolid, colliders: @[shape])

proc uprightWall(surface = surfaceMetal): Collider =
  ## A thin wall across the path of a ball that travels along x at y 400.
  Collider(a: vec(WallX, 300), b: vec(WallX, 500), radius: 2'fx, surface: surface)

proc run(game: var Table, ticks: int, contacts: var seq[Contact]) =
  ## Steps physics and gathers the contacts, as the driver clears them each tick.
  for _ in 0 ..< ticks:
    game.contacts.setLen 0
    game.stepPhysics()
    contacts.add game.contacts

proc run(game: var Table, ticks: int) =
  var ignored: seq[Contact]
  game.run(ticks, ignored)

proc eventCount(game: Table, kind: EventKind, value = -1): int =
  ## Events so far. Nothing clears them here, because the tests call
  ## `stepPhysics` and not `step`. Events from commands wait in `pendingEvents`.
  for event in game.events & game.pendingEvents:
    if event.kind == kind and (value < 0 or event.value == value):
      inc result

proc flipperShape(side: FlipperSide, angle: Fixed): FlipperShape =
  ## The flipper capsule with its ends told apart: the pivot is the end that
  ## stays in place through the stroke.
  let
    rest = flipperCollider(side, 0'fx)
    raised = flipperCollider(side, FlipperStroke)
    shape = flipperCollider(side, angle)
    pivotIsA = span(point(rest.a), point(raised.a)) <= span(point(rest.b), point(raised.b))
  result.radius = toFloat64(shape.radius)
  result.pivot = point(if pivotIsA: shape.a else: shape.b)
  result.tip = point(if pivotIsA: shape.b else: shape.a)

proc upwardNormal(shape: FlipperShape): Point =
  ## The unit vector square to the flipper that points up the table.
  let length = span(shape.pivot, shape.tip)
  if length == 0:
    return (0.0, -1.0)
  result = ((shape.tip.y - shape.pivot.y) / length, -(shape.tip.x - shape.pivot.x) / length)
  if result.y > 0:
    result = (-result.x, -result.y)

proc pointAbove(shape: FlipperShape, along, gap: float): Point =
  ## The centre of a ball that is `gap` mm clear of the top face of the
  ## flipper, at the fraction `along` of the way from the pivot to the tip.
  let
    normal = upwardNormal(shape)
    reach = shape.radius + toFloat64(BallRadius) + gap
  (shape.pivot.x + (shape.tip.x - shape.pivot.x) * along + normal.x * reach,
   shape.pivot.y + (shape.tip.y - shape.pivot.y) * along + normal.y * reach)

proc gapToFlipper(ball: Ball, shape: FlipperShape): float =
  ## The clear distance between the ball and the flipper. 0 means touching.
  let
    centre = point(ball.pos)
    lengthX = shape.tip.x - shape.pivot.x
    lengthY = shape.tip.y - shape.pivot.y
    lengthSquared = lengthX * lengthX + lengthY * lengthY
  var along = 0.0
  if lengthSquared > 0:
    along = clamp(((centre.x - shape.pivot.x) * lengthX +
      (centre.y - shape.pivot.y) * lengthY) / lengthSquared, 0.0, 1.0)
  let nearest: Point = (shape.pivot.x + lengthX * along, shape.pivot.y + lengthY * along)
  span(centre, nearest) - shape.radius - toFloat64(BallRadius)

proc isRaised(game: Table, side: FlipperSide): bool =
  toFloat64(game.flippers[side].angle) >= toFloat64(FlipperStroke) - 0.5

proc raiseAndHold(game: var Table, side: FlipperSide) =
  game.setFlipper(side, true)
  for _ in 0 ..< 60:
    if game.isRaised(side):
      break
    game.stepPhysics()

proc circleAt(position: Point, radius = 5.0): Collider =
  Collider(a: vec(position.x, position.y), b: vec(position.x, position.y),
    radius: toFixed(radius))

proc reboundFrom(collider: Collider, approachSpeed: float, tilted = false): float =
  ## Sends a ball square into an upright wall and returns how fast it comes
  ## back. Negative means it is still travelling into the wall.
  var game = initTable()
  game.tilted = tilted
  game.addObstacle(7, collider)
  game.addBall(150, 400, velX = approachSpeed)
  game.run(20)
  -toFloat64(game.balls[0].vel.x)

# --- The fixed table ---------------------------------------------------------

suite "layout":
  test "the flippers face each other and swing up the table":
    let
      left = flipperShape(flipperLeft, 0'fx)
      right = flipperShape(flipperRight, 0'fx)
    check left.pivot.x < left.tip.x
    check left.tip.x < right.tip.x
    check right.tip.x < right.pivot.x
    for side in FlipperSide:
      let
        rest = flipperShape(side, 0'fx)
        raised = flipperShape(side, FlipperStroke)
      check span(rest.pivot, rest.tip) > 40.0
      check raised.tip.y < rest.tip.y - 20

  test "keep-out covers the flippers, the drain mouth, the shooter lane and beyond the walls":
    for side in FlipperSide:
      for angle in [0'fx, FlipperStroke]:
        let shape = flipperShape(side, angle)
        check inKeepOut(circleAt(((shape.pivot.x + shape.tip.x) / 2,
          (shape.pivot.y + shape.tip.y) / 2)))
    let
      leftTip = flipperShape(flipperLeft, 0'fx).tip
      rightTip = flipperShape(flipperRight, 0'fx).tip
    check inKeepOut(circleAt(((leftTip.x + rightTip.x) / 2,
      (leftTip.y + rightTip.y) / 2 + 30)))
    check inKeepOut(circleAt(point(shooterLaneStart())))
    check inKeepOut(circleAt((-20.0, 400.0)))
    check inKeepOut(circleAt((float(PlayfieldWidth) + 20, 400.0)))
    check inKeepOut(circleAt((200.0, -20.0)))
    check inKeepOut(circleAt((200.0, float(PlayfieldHeight) + 20)))
    for open in [(200.0, 400.0), (150.0, 300.0), (300.0, 450.0)]:
      check not inKeepOut(circleAt(open))

  test "a ball stays inside the walls and drains when the flippers are idle":
    const starts = [
      (200.0, 400.0, 0.0, 0.0),
      (120.0, 300.0, -3000.0, 0.0),
      (300.0, 450.0, 3000.0, -500.0),
      (200.0, 300.0, 0.0, -3000.0),
      (260.0, 500.0, 1500.0, 2500.0),
      (150.0, 350.0, -2000.0, -2000.0)
    ]
    for start in starts:
      var game = initTable()
      game.addBall(start[0], start[1], start[2], start[3])
      var
        drained = false
        escaped = false
      for _ in 0 ..< 60 * TicksPerSecond:
        game.stepPhysics()
        let position = point(game.balls[0].pos)
        if isDrained(game.balls[0].pos):
          drained = true
          break
        if position.x < 0 or position.x > float(PlayfieldWidth) or
            position.y < 0 or position.y > float(PlayfieldHeight):
          escaped = true
          break
      checkpoint "ball started at " & $start
      check not escaped
      check drained

# --- The ball ----------------------------------------------------------------

suite "ball":
  test "a free ball speeds up down the slope":
    var game = initTable()
    game.addBall(200, 300)
    game.run(TicksPerSecond div 2)
    let ball = game.balls[0]
    check toFloat64(ball.vel.y) > 0.6 * SlopeGravity * 0.5
    check toFloat64(ball.vel.y) < 1.15 * SlopeGravity * 0.5
    check abs(toFloat64(ball.vel.x)) < 5.0
    check toFloat64(ball.pos.y) > 360.0

  test "rubber is lively, a dead surface kills the bounce, metal is in between":
    let
      rubber = reboundFrom(uprightWall(surfaceRubber), 800)
      metal = reboundFrom(uprightWall(surfaceMetal), 800)
      dead = reboundFrom(uprightWall(surfaceDead), 800)
    check rubber > 0.55 * 800
    check rubber <= 800.0
    check dead >= -1.0
    check dead < 0.25 * 800
    check metal > dead
    check metal < rubber

  test "rubber gives back a smaller share of a hard shot":
    let wall = uprightWall(surfaceRubber)
    let slowShare = reboundFrom(wall, 800) / 800
    let fastShare = reboundFrom(wall, 2400) / 2400
    check fastShare > 0
    check fastShare < 0.7 * slowShare

  test "a fast ball does not pass through a thin wall":
    var game = initTable()
    game.addObstacle(7, uprightWall())
    game.addBall(150, 400, velX = 4000)
    var
      contacts: seq[Contact]
      passedThrough = false
    for _ in 0 ..< 10:
      game.run(1, contacts)
      if toFloat64(game.balls[0].pos.x) >= WallX:
        passedThrough = true
    check not passedThrough
    check toFloat64(game.balls[0].vel.x) < 0.0
    check contacts.len > 0

  test "a hit reports who was hit, how hard and from which side":
    var game = initTable()
    game.addObstacle(7, uprightWall())
    game.addBall(150, 400, velX = 800)
    var contacts: seq[Contact]
    game.run(20, contacts)
    check contacts.len > 0
    if contacts.len > 0:
      let first = contacts[0]
      check first.ballId == 1
      check first.componentId == 7
      check toFloat64(first.strength) > 0.85 * 800
      check toFloat64(first.strength) < 1.15 * 800
      check toFloat64(first.normal.x) < -0.9

  test "a sensor reports the ball and lets it through":
    var game = initTable()
    var sensor = uprightWall()
    sensor.isSensor = true
    game.addObstacle(7, sensor)
    game.addBall(150, 400, velX = 800)
    var contacts: seq[Contact]
    game.run(25, contacts)
    check contacts.len > 0
    if contacts.len > 0:
      check contacts[0].componentId == 7
    check toFloat64(game.balls[0].pos.x) > WallX + 30
    check abs(toFloat64(game.balls[0].vel.x) - 800) < 40.0

  test "a kicking collider sends the ball away faster than it came":
    var kicker = uprightWall(surfaceRubber)
    kicker.kickSpeed = 900'fx
    check reboundFrom(kicker, 800) > 1.2 * 800

  test "a tilted table is dead: a kicking collider only bounces":
    var kicker = uprightWall(surfaceRubber)
    kicker.kickSpeed = 900'fx
    check reboundFrom(kicker, 800, tilted = true) < 800

  test "a one-way collider lets the ball through one way only":
    var gate = uprightWall()
    gate.passDirection = vec(1, 0)

    var passing = initTable()
    passing.addObstacle(7, gate)
    passing.addBall(150, 400, velX = 800)
    passing.run(25)
    check toFloat64(passing.balls[0].pos.x) > WallX + 30
    check toFloat64(passing.balls[0].vel.x) > 0.5 * 800

    var blocked = initTable()
    blocked.addObstacle(7, gate)
    blocked.addBall(350, 400, velX = -800)
    var wentThrough = false
    for _ in 0 ..< 25:
      blocked.run(1)
      if toFloat64(blocked.balls[0].pos.x) <= WallX:
        wentThrough = true
    check not wentThrough
    check toFloat64(blocked.balls[0].vel.x) > 0.0

  test "a ball touches only components and balls on its own level":
    var raised = initTable()
    raised.addObstacle(7, uprightWall(), level = 1)
    raised.addBall(150, 400, velX = 800, level = 2)
    var contacts: seq[Contact]
    raised.run(25, contacts)
    check toFloat64(raised.balls[0].pos.x) > WallX + 30
    check contacts.len == 0

    var apart = initTable()
    apart.addBall(150, 400, velX = 600, id = 1, level = 1)
    apart.addBall(250, 400, id = 2, level = 2)
    apart.run(30)
    check toFloat64(apart.balls[0].vel.x) > 0.9 * 600
    check abs(toFloat64(apart.balls[1].vel.x)) < 5.0

  test "two balls on the same level bounce off each other":
    var game = initTable()
    game.addBall(150, 400, velX = 600, id = 1)
    game.addBall(250, 400, id = 2)
    game.run(30)
    let
      striker = game.balls[0]
      struck = game.balls[1]
    check toFloat64(struck.vel.x) > 200.0
    check toFloat64(striker.vel.x) < 400.0
    check span(point(striker.pos), point(struck.pos)) >= 2 * toFloat64(BallRadius) - 1

# --- Plunger -----------------------------------------------------------------

proc pullAndRelease(game: var Table, pull: float): float =
  ## Holds the plunger until it is pulled back this far (1 is all the way),
  ## lets go, and returns the fastest the ball then travels up the table.
  game.addBall(point(shooterLaneStart()).x, point(shooterLaneStart()).y)
  game.run(60)
  game.setPlunger(true)
  for _ in 0 ..< 5 * TicksPerSecond:
    if toFloat64(game.plunger.pull) >= pull:
      break
    game.stepPhysics()
  game.setPlunger(false)
  for _ in 0 ..< TicksPerSecond:
    game.stepPhysics()
    result = max(result, -toFloat64(game.balls[0].vel.y))

suite "plunger":
  test "a served ball rests on the plunger":
    var game = initTable()
    let start = point(shooterLaneStart())
    check start.x > float(PlayfieldWidth) / 2
    game.addBall(start.x, start.y)
    game.run(2 * TicksPerSecond)
    check span(point(game.balls[0].pos), start) < 5.0
    check game.balls[0].speed < 30.0

  test "a longer pull launches the ball faster":
    var
      shortGame = initTable()
      longGame = initTable()
    let
      shortLaunch = shortGame.pullAndRelease(0.3)
      longLaunch = longGame.pullAndRelease(1.0)
    check shortLaunch > 100.0
    check longLaunch > 1.3 * shortLaunch

  test "a full pull sends the ball out of the shooter lane, with its events":
    var game = initTable()
    discard game.pullAndRelease(1.0)
    check toFloat64(game.plunger.pull) < 0.5
    check game.eventCount(evPlungerPulled) == 1
    check game.eventCount(evBallLaunched) == 1
    let laneX = point(shooterLaneStart()).x
    var reachedPlayfield = false
    for _ in 0 ..< 8 * TicksPerSecond:
      game.stepPhysics()
      if toFloat64(game.balls[0].pos.x) < laneX - 80:
        reachedPlayfield = true
        break
    check reachedPlayfield

# --- Flippers ----------------------------------------------------------------

type CatchAttempt = enum
  attemptHold       ## The flipper is up and stays up.
  attemptLiveCatch  ## The flipper starts down and is pressed on `actionTick`.
  attemptDropCatch  ## The flipper is up and is released on `actionTick`.

const NoImpact = -1

proc speedAfterDrop(attempt: CatchAttempt, actionTick: int): tuple[impactTick: int, speed: float] =
  ## Fires a ball square at the top face of the raised left flipper and
  ## returns the tick of the first impact and the speed of the ball three
  ## ticks later. The impact is the first tick on which the velocity changes
  ## by much more than gravity can explain.
  var game = initTable()
  if attempt != attemptLiveCatch:
    game.raiseAndHold(flipperLeft)
  let
    raised = flipperShape(flipperLeft, FlipperStroke)
    normal = upwardNormal(raised)
    start = pointAbove(raised, along = 0.7, gap = 70)
  game.addBall(start.x, start.y, -normal.x * 700, -normal.y * 700)
  result.impactTick = NoImpact
  for tick in 0 ..< 60:
    if tick == actionTick and attempt != attemptHold:
      game.setFlipper(flipperLeft, attempt == attemptLiveCatch)
    let before = point(game.balls[0].vel)
    game.stepPhysics()
    if result.impactTick == NoImpact and span(before, point(game.balls[0].vel)) > 60:
      result.impactTick = tick
    if result.impactTick != NoImpact and tick == result.impactTick + 3:
      result.speed = game.balls[0].speed
      return
  result.impactTick = NoImpact

proc bestCatch(attempt: CatchAttempt, lastActionTick: int): float =
  ## The slowest ball that any timing of the press or release leaves behind.
  result = Inf
  for actionTick in 0 .. lastActionTick:
    let outcome = speedAfterDrop(attempt, actionTick)
    if outcome.impactTick != NoImpact:
      result = min(result, outcome.speed)

suite "flippers":
  test "a press completes the stroke fast, holds, and a release drops it":
    for side in FlipperSide:
      let other = if side == flipperLeft: flipperRight else: flipperLeft
      var game = initTable()
      game.setFlipper(side, true)
      # The flipper recoils a few degrees off its top stop before it settles,
      # so the event marks the end of the stroke, not the angle at a tick end.
      var ticksToRaise = 0
      while game.eventCount(evFlipperFullyRaised, ord(side)) == 0 and ticksToRaise < 60:
        game.stepPhysics()
        inc ticksToRaise
      # 7 ticks is 58 ms.
      check ticksToRaise in 1 .. 7
      check game.eventCount(evFlipperUp, ord(side)) == 1
      check game.eventCount(evFlipperFullyRaised, ord(side)) == 1
      check game.eventCount(evFlipperUp, ord(other)) == 0

      game.run(30)
      check game.isRaised(side)
      check toFloat64(game.flippers[side].angle) <= toFloat64(FlipperStroke) + 0.5
      check toFloat64(game.flippers[other].angle) == 0.0
      check game.eventCount(evFlipperDown, ord(side)) == 0

      game.setFlipper(side, false)
      game.run(60)
      check abs(toFloat64(game.flippers[side].angle)) < 0.5
      check game.eventCount(evFlipperDown, ord(side)) == 1

  test "a tilted table ignores flipper presses":
    var game = initTable()
    game.tilted = true
    game.setFlipper(flipperLeft, true)
    game.run(20)
    check toFloat64(game.flippers[flipperLeft].angle) == 0.0
    check game.eventCount(evFlipperUp) == 0
    # Without this the stubs would pass: the same press works when not tilted.
    game.tilted = false
    game.setFlipper(flipperLeft, false)
    game.setFlipper(flipperLeft, true)
    game.run(20)
    check game.isRaised(flipperLeft)

  test "cradle: a ball dropped gently on a held flipper rests there":
    for side in FlipperSide:
      var game = initTable()
      game.raiseAndHold(side)
      let
        raised = flipperShape(side, FlipperStroke)
        start = pointAbove(raised, along = 0.5, gap = 20)
      game.addBall(start.x, start.y)
      game.run(6 * TicksPerSecond)
      let settled = point(game.balls[0].pos)
      var
        leftTheFlipper = false
        fastest = 0.0
      for _ in 0 ..< 2 * TicksPerSecond:
        game.stepPhysics()
        let shape = flipperShape(side, game.flippers[side].angle)
        if gapToFlipper(game.balls[0], shape) > 3:
          leftTheFlipper = true
        fastest = max(fastest, game.balls[0].speed)
      checkpoint "flipper " & $side
      check game.isRaised(side)
      check not leftTheFlipper
      check fastest < 80.0
      check span(point(game.balls[0].pos), settled) < 10.0
      check not isDrained(game.balls[0].pos)

  test "flip: a ball on a lowered flipper is shot up the table":
    for side in FlipperSide:
      var game = initTable()
      let start = pointAbove(flipperShape(side, 0'fx), along = 0.65, gap = 1)
      game.addBall(start.x, start.y)
      game.run(2)
      game.setFlipper(side, true)
      var
        fastestUp = 0.0
        highest = start.y
      for _ in 0 ..< TicksPerSecond div 2:
        game.stepPhysics()
        fastestUp = max(fastestUp, -toFloat64(game.balls[0].vel.y))
        highest = min(highest, toFloat64(game.balls[0].pos.y))
      checkpoint "flipper " & $side
      check fastestUp > 1000.0
      check highest < start.y - 150

  test "live catch and drop catch: the right timing takes the speed out of the ball":
    let held = speedAfterDrop(attemptHold, 0)
    check held.impactTick != NoImpact
    # A held flipper returns the ball: without a real bounce there is nothing to catch.
    check held.speed > 150.0
    if held.impactTick != NoImpact:
      check bestCatch(attemptLiveCatch, held.impactTick) < 0.5 * held.speed
      check bestCatch(attemptDropCatch, held.impactTick + 1) < 0.5 * held.speed

# --- Nudge and tilt ----------------------------------------------------------

suite "nudge":
  test "a nudge shoves a free ball slightly its way":
    var still = initTable()
    still.addBall(200, 400)
    still.run(6)
    let unmoved = point(still.balls[0].pos)
    for direction in NudgeDirection:
      var game = initTable()
      game.addBall(200, 400)
      game.nudge(direction)
      game.run(6)
      let
        position = point(game.balls[0].pos)
        shove = case direction
          of nudgeLeft: unmoved.x - position.x
          of nudgeRight: position.x - unmoved.x
          of nudgeUp: unmoved.y - position.y
      checkpoint $direction
      check shove > 0.2
      check shove < 30.0
      check game.eventCount(evNudge) == 1

  test "rapid nudges give two warnings and then tilt":
    var game = initTable()
    var
      nudges = 0
      tiltedEarly = false
    while not game.tilted and nudges < 30:
      game.nudge(if nudges mod 2 == 0: nudgeLeft else: nudgeRight)
      inc nudges
      game.run(3)
      if game.tilted and game.eventCount(evTiltWarning) < TiltWarningLimit:
        tiltedEarly = true
    check game.tilted
    check not tiltedEarly
    check nudges >= TiltWarningLimit + 1
    check game.tiltWarnings == TiltWarningLimit
    check game.eventCount(evTiltWarning) == TiltWarningLimit
    check game.eventCount(evTilt) == 1

  test "nudges a few seconds apart never warn":
    var game = initTable()
    for _ in 0 ..< 6:
      game.nudge(nudgeUp)
      game.run(3 * TicksPerSecond)
    check game.eventCount(evNudge) == 6
    check game.tiltWarnings == 0
    check game.eventCount(evTiltWarning) == 0
    check not game.tilted

# --- Determinism -------------------------------------------------------------

proc playScript(withInputs: bool): seq[uint64] =
  ## Launches a ball and plays it with a fixed list of presses and nudges.
  ## Returns the state hash once a second.
  var game = initTable()
  let start = point(shooterLaneStart())
  game.addBall(start.x, start.y)
  for tick in 0 ..< 10 * TicksPerSecond:
    if withInputs:
      case tick
      of 10: game.setPlunger(true)
      of 250: game.setPlunger(false)
      of 400, 700, 1000: game.setFlipper(flipperLeft, true)
      of 430, 760, 1100: game.setFlipper(flipperLeft, false)
      of 420, 690, 900: game.setFlipper(flipperRight, true)
      of 450, 720, 1050: game.setFlipper(flipperRight, false)
      of 500: game.nudge(nudgeLeft)
      of 800: game.nudge(nudgeUp)
      else: discard
    game.contacts.setLen 0
    game.stepPhysics()
    if tick mod TicksPerSecond == TicksPerSecond - 1:
      result.add game.stateHash()

suite "determinism":
  test "the same inputs on the same ticks give the same state hashes":
    check playScript(withInputs = true) == playScript(withInputs = true)
    # The hash has to see what the inputs did, or equal hashes prove nothing.
    check playScript(withInputs = true) != playScript(withInputs = false)
