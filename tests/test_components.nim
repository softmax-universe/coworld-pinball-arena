## How each kind of component must behave: the shape it gives to physics and
## what it does and reports when a ball touches it.
##
## Most tests need no physics. They put a contact into `game.contacts` by
## hand, as physics would, and run the component part of a tick. The last
## suite runs real physics. Pieces stand around x 200, y 400, where the table
## has no fixed parts. Floats are used here only to judge results.
##
## Events are looked for in `events` and in `pendingEvents`, so the tests do
## not care whether a reaction to an edit is reported this tick or the next.

import std/[math, unittest]
import pinball/sim/[types, catalogue, components, physics]

const
  HomeX = 200.0
  HomeY = 400.0
  FirmHit = 600.0     ## mm/s. Clearly a hit.
  FeebleTouch = 5.0   ## mm/s. A ball resting against a piece.
  HitKinds = [ckPopBumper, ckPassiveBumper, ckSlingshot, ckStandupTarget,
    ckRubberPost, ckCaptiveBall]

# --- Helpers -----------------------------------------------------------------

proc vec(x, y: float): FixedVec2 =
  fixedVec2(toFixed(x), toFixed(y))

proc num(value: Fixed): float =
  toFloat64(value)

proc gap(a, b: FixedVec2): float =
  hypot(num(a.x) - num(b.x), num(a.y) - num(b.y))

proc addPiece(game: var Table, id: int32, kind: ComponentKind,
    x = HomeX, y = HomeY, rotation = 0.0, sizePercent = 100'i32,
    level = 1'i32, group = 0'i32, phase = phaseSolid,
    settings: seq[(Setting, float)] = @[]) =
  var component = Component(id: id, kind: kind, pos: vec(x, y),
    rotation: toFixed(rotation), sizePercent: sizePercent, level: level,
    group: group, settings: defaultSettings(kind), phase: phase)
  for (setting, value) in settings:
    component.settings[setting] = toFixed(value)
  component.rebuildColliders()
  game.components.add component

proc addBall(game: var Table, id: int32, x = HomeX, y = HomeY,
    velX = 0.0, velY = 0.0, level = 1'i32) =
  game.balls.add Ball(id: id, state: ballFree, level: level,
    pos: vec(x, y), vel: vec(velX, velY))

template piece(game: untyped, pieceId: int32): untyped =
  game.components[game.componentIndex(pieceId)]

template ball(game: untyped, ballId: int32): untyped =
  game.balls[game.ballIndex(ballId)]

proc touch(game: var Table, ballId, pieceId: int32, strength: float, passed = false) =
  ## The contact that physics reports when the ball touches the piece.
  let offset = game.ball(ballId).pos - game.piece(pieceId).pos
  game.contacts.add Contact(ballId: ballId, componentId: pieceId,
    strength: toFixed(strength), passed: passed,
    normal: (if length(offset) > 1'fx: normalize(offset) else: vec(0, -1)))

proc tick(game: var Table, ticks = 1) =
  ## The component part of a tick, in the order of `simulation.step`, with
  ## no physics in between.
  for _ in 0 ..< ticks:
    game.applyForces()
    game.resolveContacts()
    game.advanceComponents()
    game.contacts.setLen 0
    inc game.tick

proc play(game: var Table, ticks = 1) =
  ## Whole ticks, with physics.
  for _ in 0 ..< ticks:
    game.contacts.setLen 0
    game.applyForces()
    game.stepPhysics()
    game.resolveContacts()
    game.advanceComponents()
    inc game.tick

proc changeSetting(game: var Table, pieceId: int32, setting: Setting, value: float) =
  ## Changes a setting the way the editing module does.
  let
    index = game.componentIndex(pieceId)
    oldValue = game.components[index].settings[setting]
  game.components[index].settings[setting] = toFixed(value)
  game.settingChanged(index, setting, oldValue)

proc eventsOf(game: Table, kind: EventKind, componentId = 0'i32): seq[Event] =
  for event in game.events & game.pendingEvents:
    if event.kind == kind and (componentId == 0 or event.componentId == componentId):
      result.add event

proc eventCount(game: Table, kind: EventKind, componentId = 0'i32): int =
  game.eventsOf(kind, componentId).len

proc firstIndex(game: Table, kind: EventKind): int =
  result = -1
  for index, event in game.events & game.pendingEvents:
    if event.kind == kind:
      return index

proc speed(moving: Ball): float =
  hypot(num(moving.vel.x), num(moving.vel.y))

proc movesAt(moving: Ball, degrees, wantedSpeed: float): bool =
  ## True when the ball moves along `degrees` (0 is +x, 90 is +y, toward the
  ## player) at the wanted speed, within 5%.
  let
    wantedX = cos(degToRad(degrees)) * wantedSpeed
    wantedY = sin(degToRad(degrees)) * wantedSpeed
  hypot(num(moving.vel.x) - wantedX, num(moving.vel.y) - wantedY) < 0.05 * wantedSpeed

proc shapeOf(kind: ComponentKind, rotation = 0.0, sizePercent = 100'i32,
    phase = phaseSolid, settings: seq[(Setting, float)] = @[]): seq[Collider] =
  var game = Table()
  game.addPiece(7, kind, rotation = rotation, sizePercent = sizePercent,
    phase = phase, settings = settings)
  game.piece(7).colliders

proc largestRadius(shape: seq[Collider]): float =
  for collider in shape:
    result = max(result, num(collider.radius))

proc strongestKick(shape: seq[Collider]): float =
  for collider in shape:
    result = max(result, num(collider.kickSpeed))

proc extent(shape: seq[Collider]): tuple[x, y: float] =
  ## The width and height of the box around the segments of the shape.
  if shape.len == 0:
    return
  var
    lowX, highX = num(shape[0].a.x)
    lowY, highY = num(shape[0].a.y)
  for collider in shape:
    for point in [collider.a, collider.b]:
      lowX = min(lowX, num(point.x))
      highX = max(highX, num(point.x))
      lowY = min(lowY, num(point.y))
      highY = max(highY, num(point.y))
  (highX - lowX, highY - lowY)

proc turnBetween(first, last: Collider): float =
  ## The angle between two segments in degrees, 0 .. 90.
  proc heading(collider: Collider): float =
    radToDeg(arctan2(num(collider.b.y) - num(collider.a.y),
      num(collider.b.x) - num(collider.a.x)))
  let difference = abs(heading(first) - heading(last)) mod 180.0
  min(difference, 180.0 - difference)

# --- Shapes ------------------------------------------------------------------

suite "shapes":
  test "a solid piece has a shape; holograms, lamps, mouths and track have none":
    for kind in [ckPopBumper, ckPassiveBumper, ckSlingshot, ckStandupTarget,
        ckDropTarget, ckToggleTarget, ckSpinner, ckRollover, ckCaptiveBall,
        ckSaucer, ckScoop, ckBallLock, ckKicker, ckKickback, ckGate, ckDiverter,
        ckUpPost, ckWall, ckRubberPost]:
      checkpoint $kind
      let shape = shapeOf(kind)
      check shape.len > 0
      for collider in shape:
        check collider.componentId == 7

    for kind in [ckMouth, ckTrack, ckInsert, ckFlasher, ckFloatingText]:
      checkpoint $kind
      check shapeOf(kind).len == 0
    check shapeOf(ckPopBumper, phase = phaseBeamingIn).len == 0

    var game = Table()
    game.addPiece(7, ckPopBumper)
    game.piece(7).phase = phaseFadingOut
    game.piece(7).rebuildColliders()
    check game.piece(7).colliders.len == 0

  test "spinners and rollovers let the ball through, posts and targets stand in its way":
    for kind in [ckSpinner, ckRollover]:
      checkpoint $kind
      let shape = shapeOf(kind)
      check shape.len > 0
      for collider in shape:
        check collider.isSensor
    for kind in [ckPopBumper, ckRubberPost, ckStandupTarget, ckDropTarget, ckWall]:
      checkpoint $kind
      var blocks = false
      for collider in shapeOf(kind):
        if not collider.isSensor:
          blocks = true
      check blocks

  test "a pop bumper and a slingshot kick with their strength, the other hit pieces do not":
    for kind in [ckPopBumper, ckSlingshot]:
      checkpoint $kind
      var game = Table()
      game.addPiece(7, kind)
      check abs(strongestKick(game.piece(7).colliders) -
        num(defaultSettings(kind)[setStrength])) < 1.0
      game.changeSetting(7, setStrength, 650)
      check abs(strongestKick(game.piece(7).colliders) - 650.0) < 1.0
    for kind in [ckPassiveBumper, ckStandupTarget, ckRubberPost, ckCaptiveBall]:
      checkpoint $kind
      let shape = shapeOf(kind)
      check shape.len > 0
      check strongestKick(shape) == 0.0

  test "size scales the shape":
    let
      small = largestRadius(shapeOf(ckPopBumper, sizePercent = 50))
      normal = largestRadius(shapeOf(ckPopBumper, sizePercent = 100))
      big = largestRadius(shapeOf(ckPopBumper, sizePercent = 200))
    check normal > 0.0
    check abs(big - 2.0 * normal) < 0.02 * normal
    check abs(small - 0.5 * normal) < 0.02 * normal

  test "a wall lies along its rotation, as long as its length, bent by its curve":
    let
      across = shapeOf(ckWall)
      upright = shapeOf(ckWall, rotation = 90)
      longer = shapeOf(ckWall, settings = @[(setLength, 160.0)])
      bent = shapeOf(ckWall, settings = @[(setCurve, 90.0)])
    check across.len == 1
    check extent(across).x > 60.0
    check extent(across).x < 90.0
    check extent(across).y < 1.0
    check extent(upright).y > 60.0
    check extent(upright).x < 1.0
    check extent(longer).x > 130.0
    check bent.len > 1
    if bent.len > 1:
      check turnBetween(bent[0], bent[^1]) > 30.0

  test "the bounce setting of a wall picks its surface":
    for (bounce, surface) in [(0.0, surfaceMetal), (1.0, surfaceRubber), (2.0, surfaceDead)]:
      let shape = shapeOf(ckWall, settings = @[(setBounce, bounce)])
      check shape.len > 0
      for collider in shape:
        check collider.surface == surface

  test "a one-way gate lets the ball through along its rotation":
    for rotation in [0.0, 90.0]:
      var along = 0.0
      for collider in shapeOf(ckGate, rotation = rotation):
        let size = hypot(num(collider.passDirection.x), num(collider.passDirection.y))
        if size > 0.0:
          along = (num(collider.passDirection.x) * cos(degToRad(rotation)) +
            num(collider.passDirection.y) * sin(degToRad(rotation))) / size
      check along > 0.95

# --- Hits --------------------------------------------------------------------

suite "hits":
  test "bumpers, standup targets, posts and captive balls report firm hits only":
    for kind in HitKinds:
      checkpoint $kind
      var game = Table()
      game.addPiece(7, kind, group = 3)
      game.addBall(4, y = HomeY - 45)

      for _ in 0 ..< 20:
        game.touch(4, 7, FeebleTouch)
        game.tick()
      check game.eventCount(evHit) == 0
      check game.piece(7).hitCount == 0

      game.touch(4, 7, FirmHit)
      game.tick()
      let hits = game.eventsOf(evHit)
      check hits.len == 1
      if hits.len == 1:
        check hits[0].componentId == 7
        check hits[0].group == 3
        check hits[0].level == 1
        check hits[0].ballId == 4
        check abs(num(hits[0].strength) - FirmHit) < 1.0
      check game.piece(7).hitCount == 1

  test "a wall reports nothing":
    var game = Table()
    game.addPiece(7, ckWall)
    game.addBall(4, y = HomeY - 20)
    check game.piece(7).colliders.len > 0
    game.touch(4, 7, FirmHit)
    game.tick()
    check game.events.len == 0
    check game.pendingEvents.len == 0

# --- Targets -----------------------------------------------------------------

proc knockDown(game: var Table, ballId, targetId: int32) =
  game.touch(ballId, targetId, FirmHit)
  game.tick()

suite "targets":
  test "a drop target drops on a firm hit and stays down until it is reset":
    var game = Table()
    game.addPiece(7, ckDropTarget)
    game.addBall(4, y = HomeY - 30)

    game.touch(4, 7, FeebleTouch)
    game.tick()
    check not game.piece(7).isDown
    check game.piece(7).colliders.len > 0

    game.knockDown(4, 7)
    check game.piece(7).isDown
    check game.piece(7).colliders.len == 0
    let drops = game.eventsOf(evDrop, 7)
    check drops.len == 1
    if drops.len == 1:
      check drops[0].ballId == 4

    game.tick(300)
    check game.piece(7).isDown

    game.resetTargets(7, 0)
    check not game.piece(7).isDown
    check game.piece(7).colliders.len > 0
    check game.eventCount(evReset, 7) == 1

  test "a bank is complete once, when the last drop target of its group is down":
    var game = Table()
    for id in [1'i32, 2, 3]:
      game.addPiece(id, ckDropTarget, x = 100.0 + 50.0 * float(id), group = 4)
    game.addPiece(5, ckDropTarget, x = 350, group = 9)
    game.addPiece(6, ckDropTarget, x = 400)
    game.addBall(9, y = HomeY - 30)

    game.knockDown(9, 6)
    check game.piece(6).isDown
    game.knockDown(9, 1)
    game.knockDown(9, 2)
    check game.eventCount(evBankComplete) == 0

    game.knockDown(9, 3)
    game.tick(30)
    let complete = game.eventsOf(evBankComplete)
    check complete.len == 1
    if complete.len == 1:
      check complete[0].group == 4

    game.resetTargets(0, 4)
    for id in [1'i32, 2, 3]:
      check not game.piece(id).isDown
      check game.piece(id).colliders.len > 0
    check game.piece(6).isDown
    let resets = game.eventsOf(evReset)
    check resets.len >= 1
    for reset in resets:
      check reset.group == 4

    for id in [1'i32, 2, 3]:
      game.knockDown(9, id)
    check game.eventCount(evBankComplete) == 2

  test "a toggle target flips its face on each firm hit":
    var game = Table()
    game.addPiece(7, ckToggleTarget)
    game.addBall(4, y = HomeY - 30)

    game.touch(4, 7, FirmHit)
    game.tick()
    check game.piece(7).face == 1
    game.tick(120)
    game.touch(4, 7, FirmHit)
    game.tick()
    check game.piece(7).face == 0
    game.tick(120)
    game.touch(4, 7, FeebleTouch)
    game.tick()
    check game.piece(7).face == 0

    let flips = game.eventsOf(evFlip, 7)
    check flips.len == 2
    if flips.len == 2:
      check flips[0].value == 1
      check flips[1].value == 0

  test "a spinner turns more for a faster ball, one event per turn, spread over time":
    proc spins(ballSpeed: float): tuple[atOnce, total: int] =
      var game = Table()
      game.addPiece(7, ckSpinner)
      game.addBall(4, velY = ballSpeed)
      game.touch(4, 7, ballSpeed)
      game.tick()
      result.atOnce = game.eventCount(evSpin, 7)
      game.tick(600)
      result.total = game.eventCount(evSpin, 7)

    let
      slow = spins(400)
      fast = spins(1500)
    check slow.total >= 1
    check fast.total > slow.total
    check fast.atOnce < fast.total

  test "a rollover reports once per pass, with its group, its level and the ball":
    var game = Table()
    game.addPiece(7, ckRollover, level = 2, group = 5)
    game.addBall(4, velY = 300, level = 2)

    for _ in 0 ..< 6:
      game.touch(4, 7, 300)
      game.tick()
    let passes = game.eventsOf(evRollover)
    check passes.len == 1
    if passes.len == 1:
      check passes[0].componentId == 7
      check passes[0].group == 5
      check passes[0].level == 2
      check passes[0].ballId == 4

    game.ball(4).pos = vec(HomeX, HomeY + 100)
    game.tick(10)
    game.ball(4).pos = vec(HomeX, HomeY)
    for _ in 0 ..< 6:
      game.touch(4, 7, 300)
      game.tick()
    check game.eventCount(evRollover) == 2

# --- Holes and launchers -----------------------------------------------------

suite "holes and launchers":
  test "a saucer holds a slow ball for its hold time, then ejects it":
    var game = Table()
    game.addPiece(7, ckSaucer,
      settings = @[(setHoldTicks, 60.0), (setDirection, 0.0), (setStrength, 500.0)])
    game.addBall(4, x = HomeX + 5, velY = 100)

    game.touch(4, 7, 100)
    game.tick()
    check game.ball(4).state == ballHeld
    check game.ball(4).holderId == 7
    check gap(game.ball(4).pos, game.piece(7).pos) < 1.0
    let captures = game.eventsOf(evCaptured, 7)
    check captures.len == 1
    if captures.len == 1:
      check captures[0].ballId == 4

    game.tick(40)
    check game.ball(4).state == ballHeld
    check game.eventCount(evReleased) == 0

    game.tick(40)
    check game.ball(4).state == ballFree
    check game.ball(4).movesAt(0, 500)
    let releases = game.eventsOf(evReleased, 7)
    check releases.len == 1
    if releases.len == 1:
      check releases[0].ballId == 4

  test "a fast ball skips over a saucer":
    var game = Table()
    game.addPiece(7, ckSaucer)
    game.addBall(4, velY = 2500)
    check game.piece(7).colliders.len > 0
    game.touch(4, 7, 2500)
    game.tick()
    check game.ball(4).state == ballFree
    check game.ball(4).movesAt(90, 2500)
    check game.eventCount(evCaptured) == 0

  test "a scoop swallows a ball at any speed and returns it at its exit":
    var game = Table()
    game.addPiece(7, ckScoop, settings = @[(setTravelTicks, 40.0), (setExitX, 300.0),
      (setExitY, 600.0), (setDirection, 180.0), (setStrength, 400.0)])
    game.addBall(4, velY = 2500)

    game.touch(4, 7, 2500)
    game.tick()
    check game.ball(4).state == ballHeld
    check game.ball(4).holderId == 7
    check game.eventCount(evCaptured, 7) == 1

    game.tick(25)
    check game.ball(4).state == ballHeld

    game.tick(30)
    check game.ball(4).state == ballFree
    check gap(game.ball(4).pos, vec(300, 600)) < 1.0
    check game.ball(4).movesAt(180, 400)
    check game.eventCount(evReleased, 7) == 1

  test "a scoop with no exit returns the ball where it went in":
    var game = Table()
    game.addPiece(7, ckScoop, settings = @[(setTravelTicks, 40.0)])
    game.addBall(4, velY = 300)
    game.touch(4, 7, 300)
    game.tick()
    game.ball(4).pos = vec(50, 50)   # Wherever the held ball is kept meanwhile.
    game.tick(60)
    check game.ball(4).state == ballFree
    check gap(game.ball(4).pos, game.piece(7).pos) < 40.0
    check game.ball(4).movesAt(90, 700)

  test "a ball lock fills to its capacity and holds until it is told to release":
    var game = Table()
    game.addPiece(7, ckBallLock, group = 6)
    for id in [1'i32, 2, 3]:
      game.addBall(id, velY = 300)

    game.touch(1, 7, 300)
    game.tick()
    check game.ball(1).state == ballHeld
    check game.ball(1).holderId == 7
    check game.eventCount(evLocked, 7) == 1

    game.touch(2, 7, 300)
    game.tick()
    game.touch(3, 7, 300)
    game.tick()
    check game.ball(2).state == ballHeld
    check game.ball(3).state == ballFree
    let locks = game.eventsOf(evLocked, 7)
    check locks.len == 2
    if locks.len == 2:
      check locks[1].ballId == 2
      check locks[1].group == 6

    game.tick(600)
    check game.ball(1).state == ballHeld
    check game.ball(2).state == ballHeld
    check game.eventCount(evReleased) == 0

    game.releaseBalls(0, 6)
    game.tick(120)
    for id in [1'i32, 2]:
      check game.ball(id).state == ballFree
      check game.ball(id).movesAt(90, 700)
    check game.eventCount(evReleased, 7) == 2

  test "a kicker fires a ball that touches it":
    var game = Table()
    game.addPiece(7, ckKicker, settings = @[(setDirection, 0.0), (setStrength, 1000.0)])
    game.addBall(4, velY = 200)
    game.touch(4, 7, 200)
    game.tick()
    check game.ball(4).movesAt(0, 1000)
    let fired = game.eventsOf(evFired, 7)
    check fired.len == 1
    if fired.len == 1:
      check fired[0].ballId == 4

  test "a kickback fires only while lit, is used up by firing, and can be relit":
    var game = Table()
    game.addPiece(7, ckKickback)
    game.addBall(4, velY = 200)

    game.touch(4, 7, 200)
    game.tick()
    check game.ball(4).movesAt(270, 1500)
    check game.piece(7).settings[setEnabled] == 0'fx
    check game.eventCount(evFired, 7) == 1
    check game.eventCount(evUsedUp, 7) == 1
    check game.firstIndex(evFired) >= 0
    check game.firstIndex(evFired) < game.firstIndex(evUsedUp)

    # Unlit: the ball rolls on.
    game.tick(120)
    game.ball(4).vel = vec(0, 200)
    game.touch(4, 7, 200)
    game.tick()
    check game.ball(4).movesAt(90, 200)
    check game.eventCount(evFired, 7) == 1

    game.resetTargets(7, 0)
    check game.piece(7).settings[setEnabled] == 1'fx
    check game.eventCount(evRelit, 7) == 1

    game.tick(120)
    game.touch(4, 7, 200)
    game.tick()
    check game.ball(4).movesAt(270, 1500)
    check game.eventCount(evUsedUp, 7) == 2

    game.changeSetting(7, setEnabled, 1)
    check game.eventCount(evRelit, 7) == 2

# --- Magnets -----------------------------------------------------------------

proc pushOnBall(mode: float, distance: float, ballLevel = 1'i32, enabled = 1.0): Ball =
  ## A ball at rest `distance` to the right of a magnet, after a few ticks of
  ## the magnet's force.
  var game = Table()
  game.addPiece(7, ckMagnet, settings = @[(setMode, mode), (setEnabled, enabled)])
  game.addBall(4, x = HomeX + distance, level = ballLevel)
  for _ in 0 ..< 10:
    game.applyForces()
  game.ball(4)

proc grabbedBall(): Table =
  ## A holding magnet with a ball that came to rest on it.
  result.addPiece(7, ckMagnet, settings = @[(setMode, 2.0)])
  result.addBall(4, x = HomeX + 2, velX = 10)
  for _ in 0 ..< 5:
    result.applyForces()

suite "magnets":
  test "a magnet pulls or pushes the free balls in its reach on its level":
    let
      attracted = pushOnBall(mode = 0, distance = 50)
      repelled = pushOnBall(mode = 1, distance = 50)
      holding = pushOnBall(mode = 2, distance = 50)
    check num(attracted.vel.x) < -1.0
    check abs(num(attracted.vel.y)) < 0.1 * abs(num(attracted.vel.x))
    check num(repelled.vel.x) > 1.0
    check num(holding.vel.x) < -1.0
    check holding.state == ballFree

    check pushOnBall(mode = 0, distance = 150).speed == 0.0
    check pushOnBall(mode = 0, distance = 50, ballLevel = 2).speed == 0.0
    check pushOnBall(mode = 0, distance = 50, enabled = 0).speed == 0.0

  test "a holding magnet grabs a ball that is close and slow, not one that flies past":
    var game = grabbedBall()
    check game.ball(4).state == ballHeld
    check game.ball(4).holderId == 7
    let grabs = game.eventsOf(evGrabbed, 7)
    check grabs.len == 1
    if grabs.len == 1:
      check grabs[0].ballId == 4

    var passing = Table()
    passing.addPiece(7, ckMagnet, settings = @[(setMode, 2.0)])
    passing.addBall(4, x = HomeX + 2, velX = 2000)
    passing.applyForces()
    check passing.ball(4).state == ballFree
    check passing.eventCount(evGrabbed) == 0

  test "a holding magnet lets go when it is switched off or told to release":
    var switched = grabbedBall()
    check switched.ball(4).state == ballHeld
    switched.changeSetting(7, setEnabled, 0)
    check switched.ball(4).state == ballFree
    check switched.eventCount(evReleased, 7) == 1

    var released = grabbedBall()
    check released.ball(4).state == ballHeld
    released.releaseBalls(7, 0)
    check released.ball(4).state == ballFree
    check released.eventCount(evReleased, 7) == 1

# --- Flow control ------------------------------------------------------------

suite "flow control":
  test "a gate reports a ball that went through, not one it turned back":
    var game = Table()
    game.addPiece(7, ckGate)
    game.addBall(4, x = HomeX - 10, velX = 300)
    game.touch(4, 7, 300, passed = false)
    game.tick()
    check game.eventCount(evPassed) == 0
    game.tick(60)
    game.touch(4, 7, 300, passed = true)
    game.tick()
    let passes = game.eventsOf(evPassed, 7)
    check passes.len == 1
    if passes.len == 1:
      check passes[0].ballId == 4

  test "a diverter moves its wall when it is switched":
    var game = Table()
    game.addPiece(7, ckDiverter)
    let first = game.piece(7).colliders
    check first.len > 0

    game.changeSetting(7, setPosition, 1)
    check game.piece(7).colliders.len > 0
    check game.piece(7).colliders != first
    check game.eventCount(evSwitched, 7) == 1

    game.changeSetting(7, setPosition, 0)
    check game.piece(7).colliders == first
    check game.eventCount(evSwitched, 7) == 2

  test "an up-post is a post while raised and nothing while lowered":
    var game = Table()
    game.addPiece(7, ckUpPost)
    check game.piece(7).colliders.len > 0

    game.changeSetting(7, setEnabled, 0)
    check game.piece(7).colliders.len == 0
    check game.eventCount(evLowered, 7) == 1
    check game.eventCount(evRaised, 7) == 0

    game.changeSetting(7, setEnabled, 1)
    check game.piece(7).colliders.len > 0
    check game.eventCount(evRaised, 7) == 1

    check shapeOf(ckUpPost, settings = @[(setEnabled, 0.0)]).len == 0

# --- Ball search -------------------------------------------------------------

suite "ball search":
  test "it fires kickers and lit kickbacks and frees every held ball":
    var game = Table()
    game.addPiece(1, ckKicker, y = 200)
    game.addPiece(2, ckKickback, y = 300)
    game.addPiece(3, ckKickback, y = 400, settings = @[(setEnabled, 0.0)])
    game.addPiece(4, ckSaucer, y = 500, settings = @[(setHoldTicks, 10000.0)])
    game.addPiece(5, ckScoop, y = 600, settings = @[(setTravelTicks, 10000.0)])
    game.addPiece(6, ckBallLock, y = 700)
    game.addPiece(7, ckMagnet, x = 420, y = 300, settings = @[(setMode, 2.0)])
    # Balls 11 to 13 lie still on the launchers. No contact is reported for them.
    game.addBall(11, y = 200)
    game.addBall(12, y = 300)
    game.addBall(13, y = 400)
    game.addBall(14, y = 500, velY = 100)
    game.addBall(15, y = 600, velY = 100)
    game.addBall(16, y = 700, velY = 100)
    game.addBall(17, x = 422, y = 300, velX = 10)
    for id in [14'i32, 15, 16]:
      game.touch(id, id - 10, 100)
    game.tick(5)
    for id in [14'i32, 15, 16, 17]:
      check game.ball(id).state == ballHeld

    game.ballSearch()
    game.advanceComponents()
    check game.ball(11).movesAt(270, 1200)
    check game.ball(12).movesAt(270, 1500)
    check game.ball(13).speed == 0.0
    for id in [14'i32, 15, 16, 17]:
      check game.ball(id).state == ballFree

# --- With physics ------------------------------------------------------------

suite "with physics":
  test "a ball rolled at a pop bumper is kicked away and the hit is reported":
    var game = Table()
    game.addPiece(7, ckPopBumper)
    game.addBall(4, y = HomeY - 100, velY = 600)
    for _ in 0 ..< 60:
      game.play()
      if game.eventCount(evHit, 7) > 0:
        break
    let hits = game.eventsOf(evHit, 7)
    check hits.len == 1
    if hits.len == 1:
      check hits[0].ballId == 4
      check num(hits[0].strength) > 500.0
    check num(game.ball(4).vel.y) < 0.0
    check game.ball(4).speed > 850.0
    check game.piece(7).hitCount == 1

  test "a ball bounces off a drop target and drops it; the next ball rolls through":
    var game = Table()
    game.addPiece(7, ckDropTarget)
    game.addBall(4, y = HomeY - 80, velY = 500)
    for _ in 0 ..< 60:
      game.play()
      if game.piece(7).isDown:
        break
    check game.piece(7).isDown
    check game.eventCount(evDrop, 7) == 1
    check num(game.ball(4).vel.y) < 0.0
    check num(game.ball(4).pos.y) < HomeY

    game.balls.setLen 0
    game.addBall(5, y = HomeY - 80, velY = 500)
    game.play(40)
    check num(game.ball(5).pos.y) > HomeY + 50
    check abs(num(game.ball(5).pos.x) - HomeX) < 2.0
    check game.eventCount(evDrop, 7) == 1

  test "a ball rolled slowly into a saucer is held, then ejected and rolls away":
    var game = Table()
    game.addPiece(7, ckSaucer, settings = @[(setHoldTicks, 30.0)])
    game.addBall(4, y = HomeY - 40, velY = 50)
    for _ in 0 ..< 120:
      game.play()
      if game.ball(4).state == ballHeld:
        break
    check game.ball(4).state == ballHeld
    check game.ball(4).holderId == 7
    check game.eventCount(evCaptured, 7) == 1

    for _ in 0 ..< 60:
      game.play()
      if game.ball(4).state == ballFree:
        break
    check game.ball(4).state == ballFree
    check game.eventCount(evReleased, 7) == 1

    game.play(20)
    check game.ball(4).state == ballFree
    check gap(game.ball(4).pos, game.piece(7).pos) > 40.0
