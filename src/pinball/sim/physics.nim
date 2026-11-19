## Ball physics: gravity down the slope, collisions with capsules, the
## flippers, the plunger and nudges. Physics knows only `Collider`s. What a
## component does when it is hit is decided in `components.nim`, from the
## contacts that physics reports.
##
## The flippers and the plunger are moving colliders: a ball bounces off the
## surface as seen from that surface, so it takes on the speed of whatever
## hits it. Flip shots, the plunger launch, and the catches all come from
## that one rule. A flipper is driven like the real thing: a strong coil
## throws it up, a weaker hold keeps it there, a spring returns it, and it
## bounces a little off its top stop. A ball that arrives while the flipper
## recoils from the stop, or while it falls away after a release, meets a
## retreating surface and loses its speed: the live catch and the drop catch.
##
## `Ball.spin` is not modelled and stays 0.
##
## Every value below is a starting point for playtest.

import types, layout, geometry

const
  SubstepsPerSecond = TicksPerSecond * SubstepsPerTick

  MaxBallSpeed = 5000'fx        ## mm/s. Keeps the maths in range and walls solid.

  # How much of the speed into a surface comes back out.
  SurfaceBounce: array[Surface, Fixed] = [
    surfaceMetal: 0.42'fx, surfaceRubber: 0.62'fx, surfaceDead: 0.1'fx]
  FullBounceSpeed = 800'fx      ## mm/s normal to the surface.
  BounceFalloffSpeed = 2000'fx  ## Another 2 m/s above full bounce halves restitution.
  BallBounce = 0.9'fx           ## Steel ball against steel ball.
  RestingSpeed = 60'fx
    ## mm/s. A ball that meets a surface slower than this does not bounce, so
    ## it can come to rest and roll.
  SurfaceFriction = 0.05'fx
    ## The share of an impact that also slows the ball along the surface.
  KickMinSpeed = 100'fx
    ## mm/s. A `kickSpeed` collider only kicks a ball that hits it faster than
    ## this, so a ball leaning on a bumper is left alone.

  # Flipper drive, in degrees per second gained each tick.
  FlipperStrokeGain = 1200'fx   ## The power stroke: at full speed within two ticks.
  FlipperMaxSpeed = 1750'fx
    ## Degrees per second. The stroke tops out here, so the flipper starts at
    ## once without throwing the ball harder. Full stroke in about 4 ticks.
  FlipperHoldGain = 100'fx      ## The hold, after the flipper first reaches the top.
  FlipperReturnGain = 150'fx    ## The return spring.
  FlipperStopBounce = 0.15'fx   ## The share of its speed a flipper keeps off the top stop.
  FlipperStopMinSpeed = 60'fx   ## Degrees per second. Slower than this it just stops.

  PlungerPullTicks = 120        ## Ticks of holding for a full pull.
  PlungerMaxLaunchSpeed = 2300'fx  ## mm/s of the tip after a full pull.

  NudgeSpeed = 60'fx            ## mm/s given to every free ball.
  NudgeTiltTicks = 180          ## What one nudge adds to the tilt meter.
  TiltLimitTicks = 400          ## A nudge that takes the meter over this warns or tilts.

# --- Commands ----------------------------------------------------------------

proc setFlipper*(table: var Table, side: FlipperSide, pressed: bool) =
  ## Press or release a flipper button. A tilted table ignores presses.
  if pressed == table.flippers[side].pressed or (pressed and table.tilted):
    return
  table.flippers[side].pressed = pressed
  table.flippers[side].holding = false
  table.emitNext Event(kind: if pressed: evFlipperUp else: evFlipperDown,
    value: int32(ord(side)))

proc setPlunger*(table: var Table, pressed: bool) =
  ## Hold to pull the plunger back. Releasing fires it, and the pull length
  ## sets the launch strength.
  if pressed == table.plunger.pressed:
    return
  table.plunger.pressed = pressed
  if pressed:
    table.plunger.fireSpeed = 0'fx
    table.emitNext Event(kind: evPlungerPulled)
  else:
    table.plunger.fireSpeed = PlungerMaxLaunchSpeed * table.plunger.pull
    table.plunger.hasLaunched = false

proc nudge*(table: var Table, direction: NudgeDirection) =
  ## Shove every free ball slightly. Counts toward the tilt warnings.
  let shove = case direction
    of nudgeLeft: fixedVec2(-NudgeSpeed, 0'fx)
    of nudgeRight: fixedVec2(NudgeSpeed, 0'fx)
    of nudgeUp: fixedVec2(0'fx, -NudgeSpeed)
  for ball in table.balls.mitems:
    if ball.state == ballFree:
      ball.vel += shove
  table.emitNext Event(kind: evNudge, value: int32(ord(direction)))

  if table.tilted:
    return
  table.tiltMeterTicks += NudgeTiltTicks
  if table.tiltMeterTicks <= TiltLimitTicks:
    return
  if table.tiltWarnings < TiltWarningLimit:
    inc table.tiltWarnings
    table.emitNext Event(kind: evTiltWarning, value: table.tiltWarnings)
  else:
    table.tilted = true
    table.emitNext Event(kind: evTilt)
    for side in FlipperSide:
      table.setFlipper(side, false)

# --- Flippers and plunger ----------------------------------------------------

proc advanceFlipper(table: var Table, side: FlipperSide) =
  ## One substep of flipper movement.
  var flipper = table.flippers[side]
  let gain =
    if not flipper.pressed: -FlipperReturnGain
    elif flipper.holding: FlipperHoldGain
    else: FlipperStrokeGain
  flipper.angularVelocity = min(flipper.angularVelocity + gain / SubstepsPerTick,
    FlipperMaxSpeed)
  flipper.angle += flipper.angularVelocity / SubstepsPerSecond
  if flipper.angle >= FlipperStroke:
    flipper.angle = FlipperStroke
    if not flipper.holding:
      flipper.holding = true
      table.emit Event(kind: evFlipperFullyRaised, value: int32(ord(side)))
    flipper.angularVelocity =
      if flipper.angularVelocity > FlipperStopMinSpeed:
        -flipper.angularVelocity * FlipperStopBounce
      else:
        0'fx
  elif flipper.angle <= 0'fx:
    flipper.angle = 0'fx
    flipper.angularVelocity = max(flipper.angularVelocity, 0'fx)
  table.flippers[side] = flipper

proc flipperSurfaceVelocity(side: FlipperSide, flipper: Flipper, shape: Collider,
    ballPos: FixedVec2): FixedVec2 =
  ## How fast the part of the flipper nearest the ball is moving.
  let
    arm = closestPointOnSegment(ballPos, shape.a, shape.b) - flipperPivot(side)
    turnRate = radians(flipper.angularVelocity)
  # Rising turns the left flipper anticlockwise on screen and the right one clockwise.
  if side == flipperLeft: perpendicular(arm) * -turnRate
  else: perpendicular(arm) * turnRate

proc advancePlunger(table: var Table): FixedVec2 =
  ## One substep of plunger movement. Returns the velocity of its tip.
  if table.plunger.pressed:
    if table.plunger.pull < 1'fx:
      table.plunger.pull = min(1'fx,
        table.plunger.pull + 1'fx / int32(PlungerPullTicks * SubstepsPerTick))
      return fixedVec2(0'fx, PlungerTravel / int32(PlungerPullTicks) * TicksPerSecond)
  elif table.plunger.fireSpeed > 0'fx:
    table.plunger.pull -= table.plunger.fireSpeed / SubstepsPerSecond / PlungerTravel
    result = fixedVec2(0'fx, -table.plunger.fireSpeed)
    if table.plunger.pull <= 0'fx:
      table.plunger.pull = 0'fx
      table.plunger.fireSpeed = 0'fx

# --- Collisions --------------------------------------------------------------

proc report(contacts: var seq[Contact], firstOfTick: int, contact: Contact) =
  ## One contact per ball and component each tick: the hardest one.
  for index in firstOfTick ..< contacts.len:
    if contacts[index].ballId == contact.ballId and
        contacts[index].componentId == contact.componentId:
      if contact.strength > contacts[index].strength:
        contacts[index] = contact
      return
  contacts.add contact

proc touch(ball: var Ball, collider: Collider, surfaceVelocity: FixedVec2,
    contacts: var seq[Contact], firstOfTick: int, kicks = true): bool =
  ## Pushes the ball out of the collider and bounces it. `surfaceVelocity` is
  ## how fast the collider itself moves where the ball meets it. Returns true
  ## when the collider pushed the ball.
  let reach = collider.radius + BallRadius
  if ball.pos.x < min(collider.a.x, collider.b.x) - reach or
      ball.pos.x > max(collider.a.x, collider.b.x) + reach or
      ball.pos.y < min(collider.a.y, collider.b.y) - reach or
      ball.pos.y > max(collider.a.y, collider.b.y) + reach:
    return false
  let
    offset = ball.pos - closestPointOnSegment(ball.pos, collider.a, collider.b)
    gap = offset.length
  if gap >= reach:
    return false
  let
    normal = if gap > 0'fx: offset / gap else: fixedVec2(0'fx, -1'fx)
    relative = ball.vel - surfaceVelocity
    approach = -dot(relative, normal)
    passes = collider.passDirection != FixedVec2Zero and
      dot(ball.vel, collider.passDirection) > 0'fx
  if collider.componentId != 0:
    contacts.report(firstOfTick, Contact(ballId: ball.id,
      componentId: collider.componentId, strength: max(approach, 0'fx),
      normal: normal, passed: passes))
  if collider.isSensor or passes:
    return false

  ball.pos += normal * (reach - gap)
  if approach > 0'fx:
    var push = approach
    if approach > RestingSpeed:
      let excess = max(approach - FullBounceSpeed, 0'fx)
      push += approach * SurfaceBounce[collider.surface] / (1'fx + excess / BounceFalloffSpeed)
    if kicks and approach > KickMinSpeed:
      push += collider.kickSpeed
    let
      tangent = perpendicular(normal)
      grip = push * SurfaceFriction
      drag = clamp(dot(relative, tangent), -grip, grip)
    ball.vel += normal * push - tangent * drag
  true

proc collideBalls(first, second: var Ball) =
  ## Two balls of equal mass.
  let
    offset = second.pos - first.pos
    gap = offset.length
    reach = BallRadius * 2'i32
  if gap >= reach:
    return
  let
    normal = if gap > 0'fx: offset / gap else: fixedVec2(1'fx, 0'fx)
    overlap = reach - gap
    approach = dot(first.vel - second.vel, normal)
  first.pos -= normal * (overlap / 2'i32)
  second.pos += normal * (overlap / 2'i32)
  if approach > 0'fx:
    let exchange = normal * ((approach + approach * BallBounce) / 2'i32)
    first.vel -= exchange
    second.vel += exchange

proc keepInCabinet(ball: var Ball) =
  ## The raised levels have no walls of their own, and no wall is perfect.
  ## The cabinet still holds every ball: its sides take all the speed.
  let
    lowest = fixedVec2(BallRadius, BallRadius)
    highest = fixedVec2(fixed(PlayfieldWidth) - BallRadius, fixed(PlayfieldHeight) - BallRadius)
  if ball.pos.x < lowest.x or ball.pos.x > highest.x:
    ball.vel.x = 0'fx
  if ball.pos.y < lowest.y or ball.pos.y > highest.y:
    ball.vel.y = 0'fx
  ball.pos = clamp(ball.pos, lowest, highest)

proc limitSpeed(ball: var Ball) =
  let speed = ball.vel.length
  if speed > MaxBallSpeed:
    ball.vel = ball.vel * (MaxBallSpeed / speed)

# --- The step ----------------------------------------------------------------

proc stepPhysics*(table: var Table) =
  ## Advance the flippers, the plunger and every free ball by one tick.
  ## Balls collide with the fixed parts, the flippers, each other, and the
  ## colliders of solid components on their own level. Each touch of a
  ## component's collider is added to `table.contacts`.
  let
    firstContact = table.contacts.len
    fixedParts = fixedColliders()
  if table.tiltMeterTicks > 0:
    dec table.tiltMeterTicks

  for _ in 0 ..< SubstepsPerTick:
    var flipperShapes: array[FlipperSide, Collider]
    for side in FlipperSide:
      table.advanceFlipper(side)
      flipperShapes[side] = flipperCollider(side, table.flippers[side].angle)
    let
      plungerVelocity = table.advancePlunger()
      plungerShape = plungerCollider(table.plunger.pull)

    for index in 0 ..< table.balls.len:
      if table.balls[index].state != ballFree:
        continue
      var ball = table.balls[index]
      ball.vel.y += SlopeGravity / SubstepsPerSecond
      ball.pos += ball.vel / SubstepsPerSecond

      if ball.level == 1:
        for part in fixedParts:
          discard ball.touch(part, FixedVec2Zero, table.contacts, firstContact)
        for side in FlipperSide:
          let surfaceVelocity = flipperSurfaceVelocity(side, table.flippers[side],
            flipperShapes[side], ball.pos)
          discard ball.touch(flipperShapes[side], surfaceVelocity, table.contacts, firstContact)
        if ball.touch(plungerShape, plungerVelocity, table.contacts, firstContact) and
            table.plunger.fireSpeed > 0'fx and not table.plunger.hasLaunched:
          table.plunger.hasLaunched = true
          table.emit Event(kind: evBallLaunched, ballId: ball.id, level: ball.level,
            strength: table.plunger.fireSpeed)
      for component in table.components:
        if component.level == ball.level:
          for collider in component.colliders:
            # A tilted table is dead: bumpers and slingshots do not kick.
            discard ball.touch(collider, FixedVec2Zero, table.contacts, firstContact,
              kicks = not table.tilted)

      ball.keepInCabinet()
      ball.limitSpeed()
      table.balls[index] = ball

    for first in 0 ..< table.balls.len:
      for second in first + 1 ..< table.balls.len:
        if table.balls[first].state == ballFree and table.balls[second].state == ballFree and
            table.balls[first].level == table.balls[second].level:
          collideBalls(table.balls[first], table.balls[second])
