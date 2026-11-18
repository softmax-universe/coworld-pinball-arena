## What each component kind does when a ball touches it (kick, drop, capture,
## count a spin, ...). Reactions change the component and raise the events of
## Appendix A. The collision shapes are in `shapes.nim`.
##
## Physics does not know the kinds. It bounces balls off the colliders and
## lists who touched what in `table.contacts`; `resolveContacts` reads that
## list. Holes, launchers, spinners and rollovers are sensors: the ball rolls
## over them and all that happens to it is decided here.
##
## Every value below is a starting point for playtest.

import types, catalogue, geometry, shapes

export shapes.rebuildColliders

const
  FirmHitSpeed = 100'fx
    ## mm/s into the surface. A slower touch is a ball leaning on the piece
    ## and reports nothing. Physics kicks from the same speed up.
  SaucerCaptureSpeed = 600'fx   ## mm/s. A faster ball skips over a saucer.

  SpinnerSpeedPerTurn = 200'fx  ## mm/s through the flag for each turn it makes.
  SpinnerTurnTicks = 6          ## Ticks between two reported turns.

  LockReleaseSpacingTicks = 8
    ## Ticks between two balls leaving a lock, so they do not come out inside
    ## each other.

  MagnetPullPerStrength = 4
    ## The pull at the core in mm/s^2 for each unit of `setStrength`. It
    ## falls evenly to nothing at the edge of the reach.
  MagnetGrabDistance = 8'fx     ## mm. A holding magnet grabs a ball this close ...
  MagnetGrabSpeed = 150'fx      ## ... that is slower than this, in mm/s.
  MagnetRepel = 1               ## Values of `setMode`. 0 attracts.
  MagnetHold = 2

  TouchEvents = {evHit, evDrop, evFlip, evSpin, evRollover, evCaptured, evLocked,
    evFired, evGrabbed, evPassed}
    ## The events that count in a piece's `hitCount`: a ball did something to it.

# --- Shared steps ------------------------------------------------------------

proc report(table: var Table, index: int, kind: EventKind, ballId = 0'i32,
    strength = 0'fx, value = 0'i32, inTick = true) =
  ## Raises an event of the piece. `inTick` is false for reactions to
  ## commands, edits and rule results, which rules see on the next tick.
  template component: untyped = table.components[index]
  let event = Event(kind: kind, componentId: component.id, group: component.group,
    level: component.level, ballId: ballId, strength: strength, value: value)
  if kind in TouchEvents:
    inc component.hitCount
  if inTick:
    table.emit event
  else:
    table.emitNext event

proc isTarget(component: Component, componentId, group: int32): bool =
  ## Commands name one piece by id or a whole group.
  component.id == componentId or (group != 0 and component.group == group)

proc capture(table: var Table, index, ballAt: int, kind: EventKind) =
  ## The piece takes the ball out of play and keeps it at its own place.
  template component: untyped = table.components[index]
  template ball: untyped = table.balls[ballAt]
  ball.state = ballHeld
  ball.holderId = component.id
  ball.pos = component.pos
  ball.vel = FixedVec2Zero
  component.heldBallIds.add ball.id
  table.report(index, kind, ball.id)

proc releaseOne(table: var Table, index: int, inTick: bool) =
  ## The piece lets go of the ball it has held longest. A magnet leaves the
  ## ball at rest. A hole shoots it out along `setDirection`, and a scoop
  ## with an exit does that from the exit.
  template component: untyped = table.components[index]
  let ballId = component.heldBallIds[0]
  component.heldBallIds.delete 0
  component.handledBallIds.add ballId
  template ball: untyped = table.balls[table.ballIndex(ballId)]
  ball.state = ballFree
  ball.holderId = 0
  if component.kind != ckMagnet:
    let exit = fixedVec2(component.settings[setExitX], component.settings[setExitY])
    ball.pos = if exit == FixedVec2Zero: component.pos else: exit
    ball.vel = heading(component.settings[setDirection]) * component.settings[setStrength]
  table.report(index, evReleased, ballId, inTick = inTick)

proc releaseAll(table: var Table, index: int) =
  ## Lets go of every held ball, on command. Only a lock holds more than
  ## one: the first leaves now and `advanceComponents` sends the others after it.
  template component: untyped = table.components[index]
  if component.heldBallIds.len == 0:
    return
  table.releaseOne(index, inTick = false)
  if component.heldBallIds.len > 0:
    component.timerTicks = LockReleaseSpacingTicks

proc forgetBallsThatLeft(table: var Table) =
  ## See `Component.handledBallIds`. A magnet has no collider, so it forgets
  ## by distance in `applyForces` instead.
  for component in table.components.mitems:
    if component.kind == ckMagnet or component.handledBallIds.len == 0:
      continue
    var stillTouching: seq[int32]
    for contact in table.contacts:
      if contact.componentId == component.id and contact.ballId in component.handledBallIds:
        stillTouching.add contact.ballId
    component.handledBallIds = stillTouching

# --- Targets -----------------------------------------------------------------

proc bankIsDown(table: Table, group: int32): bool =
  for component in table.components:
    if component.kind == ckDropTarget and component.group == group and not component.isDown:
      return false
  true

proc dropTarget(table: var Table, index: int, contact: Contact) =
  template target: untyped = table.components[index]
  target.isDown = true
  rebuildColliders(target)
  table.report(index, evDrop, contact.ballId, contact.strength)
  if target.group != 0 and table.bankIsDown(target.group):
    table.report(index, evBankComplete, contact.ballId)

proc flipTarget(table: var Table, index: int, contact: Contact) =
  template target: untyped = table.components[index]
  target.face = 1 - target.face
  table.report(index, evFlip, contact.ballId, contact.strength, value = target.face)

proc startSpinner(table: var Table, index, ballAt: int) =
  ## The faster the ball goes through the flag, the more turns it makes.
  ## `turnSpinner` reports them one by one.
  template spinner: untyped = table.components[index]
  let
    ball = table.balls[ballAt]
    through = perpendicular(heading(spinner.rotation))
  spinner.spinsLeft += toInt(abs(dot(ball.vel, through)) / SpinnerSpeedPerTurn)
  spinner.spinBallId = ball.id
  spinner.handledBallIds.add ball.id

proc turnSpinner(table: var Table, index: int) =
  template spinner: untyped = table.components[index]
  if spinner.spinsLeft == 0:
    return
  if spinner.timerTicks > 0:
    dec spinner.timerTicks
    return
  dec spinner.spinsLeft
  spinner.timerTicks = SpinnerTurnTicks
  table.report(index, evSpin, spinner.spinBallId)

proc rollOver(table: var Table, index, ballAt: int) =
  table.components[index].handledBallIds.add table.balls[ballAt].id
  table.report(index, evRollover, table.balls[ballAt].id)

# --- Holes and launchers -----------------------------------------------------

proc catchInSaucer(table: var Table, index, ballAt: int) =
  template saucer: untyped = table.components[index]
  if saucer.heldBallIds.len == 0 and table.balls[ballAt].vel.length < SaucerCaptureSpeed:
    saucer.timerTicks = toInt(saucer.settings[setHoldTicks])
    table.capture(index, ballAt, evCaptured)

proc swallowInScoop(table: var Table, index, ballAt: int) =
  ## One ball at a time: a second ball rolls over a scoop whose subway is busy.
  template scoop: untyped = table.components[index]
  if scoop.heldBallIds.len == 0:
    scoop.timerTicks = toInt(scoop.settings[setTravelTicks])
    table.capture(index, ballAt, evCaptured)

proc lockBall(table: var Table, index, ballAt: int) =
  ## A lock that is full, or busy sending its balls out, lets the ball roll over.
  template lock: untyped = table.components[index]
  if lock.timerTicks == 0 and lock.heldBallIds.len < toInt(lock.settings[setCapacity]):
    table.capture(index, ballAt, evLocked)

proc countDownHold(table: var Table, index: int) =
  ## A saucer or scoop ejects its ball when the hold or travel time is over.
  template hole: untyped = table.components[index]
  if hole.heldBallIds.len == 0:
    return
  if hole.timerTicks > 0:
    dec hole.timerTicks
  if hole.timerTicks == 0:
    table.releaseOne(index, inTick = true)

proc continueRelease(table: var Table, index: int) =
  ## A lock that was told to release sends out its other balls one by one.
  template lock: untyped = table.components[index]
  if lock.timerTicks == 0:
    return
  dec lock.timerTicks
  if lock.timerTicks == 0 and lock.heldBallIds.len > 0:
    table.releaseOne(index, inTick = true)
    if lock.heldBallIds.len > 0:
      lock.timerTicks = LockReleaseSpacingTicks

proc isArmed(launcher: Component): bool =
  launcher.kind == ckKicker or launcher.settings[setEnabled] == 1'fx

proc fire(table: var Table, index, ballAt: int, inTick: bool) =
  ## A kicker or a lit kickback shoots the ball away. Firing uses a kickback up.
  template launcher: untyped = table.components[index]
  template ball: untyped = table.balls[ballAt]
  if not launcher.isArmed or table.tilted:   # A tilted table is dead.
    return
  ball.vel = heading(launcher.settings[setDirection]) * launcher.settings[setStrength]
  launcher.handledBallIds.add ball.id
  table.report(index, evFired, ball.id, inTick = inTick)
  if launcher.kind == ckKickback:
    launcher.settings[setEnabled] = 0'fx
    table.report(index, evUsedUp, ball.id, inTick = inTick)

proc fireAtRestingBalls(table: var Table, index: int) =
  ## For the ball search. A ball that lies still on a launcher makes no
  ## contact that would fire it, so the balls are found by where they are.
  let launcher = table.components[index]
  if launcher.phase != phaseSolid:
    return
  let reach = scaled(KindInfos[launcher.kind].radius, launcher.sizePercent)
  for ballAt in 0 ..< table.balls.len:
    let ball = table.balls[ballAt]
    if ball.state == ballFree and ball.level == launcher.level and
        distance(ball.pos, launcher.pos) < reach:
      table.fire(index, ballAt, inTick = false)

# --- Magnets -----------------------------------------------------------------

proc pullBall(table: var Table, index, ballAt: int) =
  ## One tick of a magnet's force on one ball. A ball the magnet has let go
  ## of is left alone until it is out of reach, so it can roll away.
  template magnet: untyped = table.components[index]
  let ball = table.balls[ballAt]
  if ball.state != ballFree or ball.level != magnet.level:
    return
  let
    reach = magnet.settings[setRadius]
    offset = magnet.pos - ball.pos
    gap = offset.length
    letGoAt = magnet.handledBallIds.find(ball.id)
  if gap >= reach:
    if letGoAt >= 0:
      magnet.handledBallIds.delete letGoAt
    return
  if letGoAt >= 0:
    return

  let mode = toInt(magnet.settings[setMode])
  if mode == MagnetHold and magnet.heldBallIds.len == 0 and
      gap < MagnetGrabDistance and ball.vel.length < MagnetGrabSpeed:
    table.capture(index, ballAt, evGrabbed)
    return
  let
    pull = magnet.settings[setStrength] * int32(MagnetPullPerStrength) * ((reach - gap) / reach)
    toward = normalize(offset) * (pull / TicksPerSecond)
  if mode == MagnetRepel:
    table.balls[ballAt].vel -= toward
  else:
    table.balls[ballAt].vel += toward

proc applyForces*(table: var Table) =
  ## Magnets pull, push or hold the free balls in their reach.
  for index in 0 ..< table.components.len:
    template magnet: untyped = table.components[index]
    if magnet.kind == ckMagnet and magnet.phase == phaseSolid and
        magnet.settings[setEnabled] == 1'fx:
      for ballAt in 0 ..< table.balls.len:
        table.pullBall(index, ballAt)

# --- The tick ----------------------------------------------------------------

proc resolveContacts*(table: var Table) =
  ## Turn this tick's `table.contacts` into component reactions and events.
  table.forgetBallsThatLeft()
  for contact in table.contacts:
    let
      index = table.componentIndex(contact.componentId)
      ballAt = table.ballIndex(contact.ballId)
      isFirm = contact.strength > FirmHitSpeed
    if table.balls[ballAt].state != ballFree or
        contact.ballId in table.components[index].handledBallIds:
      continue
    case table.components[index].kind
    of ckPopBumper, ckPassiveBumper, ckSlingshot, ckStandupTarget, ckRubberPost, ckCaptiveBall:
      if isFirm:
        table.report(index, evHit, contact.ballId, contact.strength)
    of ckDropTarget:
      if isFirm:
        table.dropTarget(index, contact)
    of ckToggleTarget:
      if isFirm:
        table.flipTarget(index, contact)
    of ckSpinner:
      table.startSpinner(index, ballAt)
    of ckRollover:
      table.rollOver(index, ballAt)
    of ckSaucer:
      table.catchInSaucer(index, ballAt)
    of ckScoop:
      table.swallowInScoop(index, ballAt)
    of ckBallLock:
      table.lockBall(index, ballAt)
    of ckKicker, ckKickback:
      table.fire(index, ballAt, inTick = true)
    of ckGate:
      if contact.passed:
        table.components[index].handledBallIds.add contact.ballId
        table.report(index, evPassed, contact.ballId)
    else:
      discard

proc advanceComponents*(table: var Table) =
  ## Count down hold and travel timers, eject balls whose time is up, and
  ## report pending spinner turns.
  for index in 0 ..< table.components.len:
    case table.components[index].kind
    of ckSaucer, ckScoop: table.countDownHold(index)
    of ckBallLock: table.continueRelease(index)
    of ckSpinner: table.turnSpinner(index)
    else: discard

# --- Commands, edits and rule results ----------------------------------------

proc settingChanged*(table: var Table, componentIndex: int, setting: Setting, oldValue: Fixed) =
  ## Called by the editing module after it changed one setting of a piece.
  ## Rebuilds the collision shape if the piece is solid and raises the event
  ## that belongs to the change: an up-post raised or lowered, a diverter
  ## switched, a kickback relit, a magnet letting go of its ball.
  template component: untyped = table.components[componentIndex]
  rebuildColliders(component)
  let value = component.settings[setting]
  if value == oldValue:
    return
  case component.kind
  of ckUpPost:
    if setting == setEnabled:
      table.report(componentIndex, (if value == 1'fx: evRaised else: evLowered), inTick = false)
  of ckDiverter:
    if setting == setPosition:
      table.report(componentIndex, evSwitched, inTick = false)
  of ckKickback:
    if setting == setEnabled and value == 1'fx:
      table.report(componentIndex, evRelit, inTick = false)
  of ckMagnet:
    # Switched off or on, or to another mode: it starts afresh, holding nothing.
    if setting in {setEnabled, setMode}:
      table.releaseAll(componentIndex)
      component.handledBallIds.setLen 0
  else:
    discard

proc releaseBalls*(table: var Table, componentId, group: int32) =
  ## Let go of every ball held by the component, or by each piece of the group.
  for index in 0 ..< table.components.len:
    if table.components[index].isTarget(componentId, group):
      table.releaseAll(index)

proc resetTargets*(table: var Table, componentId, group: int32) =
  ## Raise drop targets again and relight kickbacks.
  for index in 0 ..< table.components.len:
    template component: untyped = table.components[index]
    if not component.isTarget(componentId, group):
      continue
    if component.kind == ckDropTarget and component.isDown:
      component.isDown = false
      rebuildColliders(component)
      table.report(index, evReset, inTick = false)
    elif component.kind == ckKickback and component.settings[setEnabled] != 1'fx:
      component.settings[setEnabled] = 1'fx
      table.report(index, evRelit, inTick = false)

proc ballSearch*(table: var Table) =
  ## Free a stuck ball: fire every kicker and lit kickback at the balls that
  ## rest on them, and make every saucer, scoop, lock and holding magnet let
  ## go of its balls.
  for index in 0 ..< table.components.len:
    if table.components[index].kind in {ckKicker, ckKickback}:
      table.fireAtRestingBalls(index)
    else:
      table.releaseAll(index)
