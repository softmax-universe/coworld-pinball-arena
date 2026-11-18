## Track: two mouth pieces joined by a curve.
##
## A ball that rolls into the open end of a mouth is taken onto the track and
## then moves along the centre line of the curve only (one dimension). The
## slope of the table and the climb of a ramp slow it or speed it up. It
## leaves through the other mouth (track completed) or rolls back out of the
## mouth it came in by (track failed). Mouths on different levels make a ramp,
## and a ball on a raised track touches nothing on the playfield below.
##
## The path a ball follows is a line of points: the open end of mouth A, the
## curve from throat A to throat B, and the open end of mouth B. A ball's
## `trackDistance` is measured from throat A, so it is a little below zero
## while the ball is inside mouth A and a little above the length of the curve
## while it is inside mouth B.

import types, catalogue, geometry, layout

const
  ThroatDepth = 30'fx
    ## Millimetres from the open end of a mouth back to its throat, at 100% size.
  CurveSegments = 32
    ## The curve is sampled into this many straight pieces.
  FullGravity = 9800'fx
    ## mm/s^2 straight down. A ramp turns a share of it against the climb.
  LevelHeight = 25'fx
    ## Millimetres between one level and the next.
  RollingFriction = 40'fx
    ## mm/s^2, always against the motion.
  GateBounce = 0.5'fx
    ## The share of its speed a ball keeps when a gate on the track turns it back.
  ThingReach = 10'fx
    ## A rollover, spinner or gate this close to the path, in mm, is on the track.
  TickRate = int32(TicksPerSecond)

type
  TrackEnds = object
    ## The two mouths of a track, as indices into `table.components`.
    exists: bool      ## Both mouth pieces are on the table.
    isWorking: bool   ## The track and both mouths are solid.
    mouths: array[2, int]

  Crossing = object
    ## A thing on the track that the ball reaches during this tick.
    componentIndex: int
    at: Fixed         ## Its distance along the path.

proc trackEnds(table: Table, track: Component): TrackEnds =
  result.mouths = [table.componentIndex(toInt(track.settings[setMouthA])),
                   table.componentIndex(toInt(track.settings[setMouthB]))]
  result.exists = true
  result.isWorking = track.phase == phaseSolid
  for mouthIndex in result.mouths:
    if mouthIndex < 0 or table.components[mouthIndex].kind != ckMouth:
      return TrackEnds()
    if table.components[mouthIndex].phase != phaseSolid:
      result.isWorking = false

proc facing(piece: Component): FixedVec2 =
  direction(radians(piece.rotation))

proc throat(mouth: Component): FixedVec2 =
  mouth.pos - mouth.facing * scaled(ThroatDepth, mouth.sizePercent)

proc pathPoints(table: Table, track: Component, ends: TrackEnds): seq[FixedVec2] =
  ## Open end A, the sampled curve from throat A to throat B, open end B.
  let
    mouthA = table.components[ends.mouths[0]]
    mouthB = table.components[ends.mouths[1]]
    startPoint = mouthA.throat
    endPoint = mouthB.throat
  var
    controlA = fixedVec2(track.settings[setControlAX], track.settings[setControlAY])
    controlB = fixedVec2(track.settings[setControlBX], track.settings[setControlBY])
  if controlA == fixedVec2() and controlB == fixedVec2():
    # No control points were given: a straight line.
    controlA = startPoint + (endPoint - startPoint) / 3'i32
    controlB = endPoint - (endPoint - startPoint) / 3'i32
  result.add mouthA.pos
  for sample in 0 .. CurveSegments:
    let
      amount = fixed(int32(sample)) / int32(CurveSegments)
      first = lerp(startPoint, controlA, amount)
      second = lerp(controlA, controlB, amount)
      third = lerp(controlB, endPoint, amount)
    result.add lerp(lerp(first, second, amount), lerp(second, third, amount), amount)
  result.add mouthB.pos

proc pathLength(points: seq[FixedVec2]): Fixed =
  for index in 1 .. points.high:
    result += distance(points[index - 1], points[index])

proc pathPoint(points: seq[FixedVec2], along: Fixed): tuple[pos, tangent: FixedVec2] =
  ## The point `along` millimetres from the start of the path, and the
  ## direction of the path there (a unit vector that points toward mouth B).
  var left = max(along, 0'fx)
  result.pos = points[^1]
  for index in 1 .. points.high:
    let
      span = points[index] - points[index - 1]
      length = span.length
    if length == 0'fx:
      continue
    result.tangent = span / length
    if left <= length:
      result.pos = points[index - 1] + result.tangent * left
      return
    left -= length

proc findOnPath(points: seq[FixedVec2], pos: FixedVec2, along: var Fixed): bool =
  ## Whether `pos` lies on the path, and how far along it.
  var
    nearest = ThingReach
    walked = 0'fx
  for index in 1 .. points.high:
    let
      closest = closestPointOnSegment(pos, points[index - 1], points[index])
      gap = distance(pos, closest)
    if gap <= nearest:
      nearest = gap
      along = walked + distance(points[index - 1], closest)
      result = true
    walked += distance(points[index - 1], points[index])

proc trackLength*(table: Table, track: Component): Fixed =
  ## The length of the curve between the two mouths, in millimetres.
  let ends = table.trackEnds(track)
  if not ends.exists:
    return 0'fx
  let points = table.pathPoints(track, ends)
  points.pathLength - distance(points[0], points[1]) - distance(points[^2], points[^1])

proc trackPoint*(table: Table, track: Component, distance: Fixed): FixedVec2 =
  ## The point on the curve `distance` millimetres from mouth A.
  let ends = table.trackEnds(track)
  if not ends.exists:
    return fixedVec2()
  let points = table.pathPoints(track, ends)
  points.pathPoint(distance + distance(points[0], points[1])).pos

proc setLevel(table: var Table, ball: var Ball, level: int32) =
  if ball.level != level:
    ball.level = level
    table.emit Event(kind: evBallChangedLevel, ballId: ball.id, level: level, value: level)

proc emitTrackEvent(table: var Table, kind: EventKind, track: Component, ball: Ball,
                    mouthId: int32) =
  table.emit Event(kind: kind, componentId: track.id, group: track.group,
                   level: ball.level, ballId: ball.id, value: mouthId)

proc findMouth(table: Table, ball: Ball, lowestLevel, highestLevel: int32):
    tuple[trackIndex, mouthIndex: int] =
  ## The mouth of a working track that the ball is rolling into, if any.
  ## `trackIndex` is -1 when there is none.
  for trackIndex, track in table.components:
    if track.kind != ckTrack:
      continue
    let ends = table.trackEnds(track)
    if not ends.isWorking:
      continue
    for mouthIndex in ends.mouths:
      let
        mouth = table.components[mouthIndex]
        halfWidth = scaled(mouth.settings[setWidthA], mouth.sizePercent) / 2'i32
      if mouth.level in lowestLevel .. highestLevel and
          distance(ball.pos, mouth.pos) <= halfWidth and
          dot(ball.vel, mouth.facing) < 0'fx:
        return (trackIndex, mouthIndex)
  (-1, -1)

proc enterTrack(table: var Table, ball: var Ball, trackIndex, mouthIndex: int) =
  let
    track = table.components[trackIndex]
    mouth = table.components[mouthIndex]
    ends = table.trackEnds(track)
    points = table.pathPoints(track, ends)
    entersByB = mouthIndex == ends.mouths[1]
    speed = ball.vel.length
  ball.state = ballOnTrack
  ball.holderId = track.id
  ball.trackEntryMouthId = mouth.id
  ball.trackDistance = -distance(points[0], points[1])
  ball.trackSpeed = speed
  if entersByB:
    ball.trackDistance += points.pathLength
    ball.trackSpeed = -speed
  ball.pos = mouth.pos
  ball.vel = -mouth.facing * speed
  table.setLevel(ball, max(table.components[ends.mouths[0]].level,
                           table.components[ends.mouths[1]].level))
  table.emitTrackEvent(evTrackEntered, track, ball, mouth.id)

proc leaveTrack(table: var Table, ball: var Ball, track: Component, mouthIndex: int,
                speed: Fixed) =
  ## Put the ball back on the table at the open end of this mouth.
  let mouth = table.components[mouthIndex]
  ball.state = ballFree
  ball.holderId = 0
  ball.trackSpeed = 0'fx
  ball.pos = mouth.pos
  ball.vel = mouth.facing * abs(speed)
  let kind = if mouth.id == ball.trackEntryMouthId: evTrackFailed else: evTrackCompleted
  table.emitTrackEvent(kind, track, ball, mouth.id)
  # A raised mouth may feed straight into the mouth of another track on its
  # own level or the one below. Otherwise the ball lands on the playfield.
  let next = table.findMouth(ball, mouth.level - 1, mouth.level)
  if next.trackIndex >= 0:
    table.enterTrack(ball, next.trackIndex, next.mouthIndex)
  else:
    table.setLevel(ball, 1)

proc blocks(thing: Component, travel: FixedVec2): bool =
  ## A closed gate stops a ball that moves against the way the gate points.
  thing.kind == ckGate and thing.settings[setEnabled] == 0'fx and
    dot(travel, thing.facing) < 0'fx

proc moveOnTrack(table: var Table, ball: var Ball) =
  let trackIndex = table.componentIndex(ball.holderId)
  var ends: TrackEnds
  if trackIndex >= 0:
    ends = table.trackEnds(table.components[trackIndex])
  if not ends.isWorking:
    # The track was taken away from under the ball: it drops where it is.
    ball.state = ballFree
    ball.holderId = 0
    ball.trackSpeed = 0'fx
    table.setLevel(ball, 1)
    return

  let
    track = table.components[trackIndex]
    points = table.pathPoints(track, ends)
    total = points.pathLength
    lead = distance(points[0], points[1])
    before = ball.trackDistance + lead
    climb = table.components[ends.mouths[1]].level - table.components[ends.mouths[0]].level

  # Speed: the slope of the table, the climb of a ramp, then friction.
  var acceleration = SlopeGravity * points.pathPoint(before).tangent.y
  if climb != 0:
    let grade = min(LevelHeight * abs(climb) / total, 1'fx)
    acceleration -= FullGravity * grade * sign(fixed(climb))
  var speed = ball.trackSpeed + acceleration / TickRate
  let friction = RollingFriction / TickRate
  speed = if abs(speed) <= friction: 0'fx else: speed - friction * sign(speed)
  var after = before + speed / TickRate

  # Things on the track that the ball reaches in this tick.
  var crossings: seq[Crossing]
  for componentIndex, thing in table.components:
    var at: Fixed
    if thing.kind in {ckRollover, ckSpinner, ckGate} and thing.phase == phaseSolid and
        thing.level == ball.level and points.findOnPath(thing.pos, at) and
        ((before < at and at <= after) or (before > at and at >= after)):
      crossings.add Crossing(componentIndex: componentIndex, at: at)

  # The nearest gate that blocks the ball stops it there and turns it back.
  let travelSign = sign(speed)
  var blockedBy = -1
  for crossing in crossings:
    let travel = points.pathPoint(crossing.at).tangent * travelSign
    if table.components[crossing.componentIndex].blocks(travel) and
        abs(crossing.at - before) <= abs(after - before):
      blockedBy = crossing.componentIndex
      after = crossing.at

  for crossing in crossings:
    if abs(crossing.at - before) <= abs(after - before):
      let thing = table.components[crossing.componentIndex]
      table.contacts.add Contact(
        ballId: ball.id, componentId: thing.id, strength: abs(speed),
        normal: -(points.pathPoint(crossing.at).tangent * travelSign),
        passed: thing.kind == ckGate and crossing.componentIndex != blockedBy)
  if blockedBy >= 0:
    speed = -speed * GateBounce

  if after < 0'fx:
    table.leaveTrack(ball, track, ends.mouths[0], speed)
  elif after > total:
    table.leaveTrack(ball, track, ends.mouths[1], speed)
  else:
    let here = points.pathPoint(after)
    ball.trackDistance = after - lead
    ball.trackSpeed = speed
    ball.pos = here.pos
    ball.vel = here.tangent * speed

proc stepTracks*(table: var Table) =
  ## Take free balls that enter a mouth onto its track, move the balls that
  ## are on tracks by one tick, and put the ones that reach an end back on
  ## the table.
  for ballIndex in 0 ..< table.balls.len:
    var ball = table.balls[ballIndex]
    case ball.state
    of ballOnTrack:
      table.moveOnTrack(ball)
    of ballFree:
      let found = table.findMouth(ball, ball.level, ball.level)
      if found.trackIndex >= 0:
        table.enterTrack(ball, found.trackIndex, found.mouthIndex)
    of ballHeld:
      discard
    table.balls[ballIndex] = ball
