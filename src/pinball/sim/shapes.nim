## The collision shape of each component kind: the capsules that physics
## bounces the ball off, built from the place, rotation, size and settings of
## the piece. What happens on a touch is in `components.nim`.
##
## A long piece lies along its rotation. The footprint radius of each kind
## comes from the catalogue, and `sizePercent` scales every length here.
##
## Every value below is a starting point for playtest.

import types, catalogue, geometry

const
  # Millimetres at 100% size.
  PlateRadius = 3'fx        ## Half the thickness of a target, a slingshot edge, a diverter blade.
  WireRadius = 2'fx         ## Gate wires, spinner flags and rollover switches.
  RailRadius = 1.5'fx       ## The side rails of a captive-ball lane.
  MinHoleRadius = 2'fx

  DiverterSwing = 25'fx     ## Degrees the blade stands to either side of the rotation.
  WallDegreesPerSegment = 15  ## A curved wall gets one more straight piece per this much bend.

proc heading*(degrees: Fixed): FixedVec2 =
  ## The unit vector along an angle of the table.
  direction(radians(degrees))

proc circle(centre: FixedVec2, radius: Fixed, surface = surfaceMetal): Collider =
  Collider(a: centre, b: centre, radius: radius, surface: surface)

proc bar(centre, along: FixedVec2, halfLength, radius: Fixed, surface = surfaceMetal): Collider =
  Collider(a: centre - along * halfLength, b: centre + along * halfLength,
    radius: radius, surface: surface)

proc sensor(shape: Collider): Collider =
  result = shape
  result.isSensor = true

proc bumperShape(piece: Component, radius: Fixed): seq[Collider] =
  var ring = circle(piece.pos, radius, surfaceRubber)
  if piece.kind == ckPopBumper:
    ring.kickSpeed = piece.settings[setStrength]
  @[ring]

proc slingshotShape(piece: Component, radius: Fixed): seq[Collider] =
  ## A triangle. Its long face lies along the rotation and kicks; at rotation
  ## 0 the face looks up the table. The two short sides only bounce.
  let
    along = heading(piece.rotation) * (radius * 0.8'fx)
    behind = perpendicular(heading(piece.rotation))
    faceMiddle = piece.pos - behind * (radius * 0.2'fx)
    apex = piece.pos + behind * (radius * 0.6'fx)
    edge = scaled(PlateRadius, piece.sizePercent)
  var face = Collider(a: faceMiddle - along, b: faceMiddle + along, radius: edge,
    surface: surfaceRubber)
  face.kickSpeed = piece.settings[setStrength]
  @[face,
    Collider(a: face.a, b: apex, radius: edge, surface: surfaceRubber),
    Collider(a: face.b, b: apex, radius: edge, surface: surfaceRubber)]

proc plateShape(piece: Component, radius: Fixed): seq[Collider] =
  ## A flat target, as wide as its footprint.
  let thickness = scaled(PlateRadius, piece.sizePercent)
  @[bar(piece.pos, heading(piece.rotation), radius - thickness, thickness)]

proc captiveBallShape(piece: Component, radius: Fixed): seq[Collider] =
  ## The trapped ball sits at the near end of its lane (the end the rotation
  ## points away from) and stands in for the whole mechanism: the game ball
  ## bounces off it as off a rubber post. Two rails close the lane behind it.
  let
    along = heading(piece.rotation)
    half = along * (scaled(piece.settings[setLength], piece.sizePercent) / 2'i32)
    rail = scaled(RailRadius, piece.sizePercent)
    side = perpendicular(along) * (radius - rail)
    near = piece.pos - half
    far = piece.pos + half
  @[circle(near, radius, surfaceRubber),
    Collider(a: near + side, b: far + side, radius: rail),
    Collider(a: near - side, b: far - side, radius: rail)]

proc holeShape(piece: Component, radius: Fixed): seq[Collider] =
  ## Saucers, scoops, locks and launchers lie flat in the table. The sensor
  ## reports a ball once its centre is over the hole.
  @[sensor(circle(piece.pos, max(radius - BallRadius, MinHoleRadius)))]

proc gateShape(piece: Component, radius: Fixed): seq[Collider] =
  ## A wire across the rotation. A ball moving along the rotation goes through.
  let along = heading(piece.rotation)
  var wire = bar(piece.pos, perpendicular(along), radius, scaled(WireRadius, piece.sizePercent))
  wire.passDirection = along
  @[wire]

proc diverterShape(piece: Component, radius: Fixed): seq[Collider] =
  let
    swing = if piece.settings[setPosition] == 1'fx: DiverterSwing else: -DiverterSwing
    thickness = scaled(PlateRadius, piece.sizePercent)
  @[bar(piece.pos, heading(piece.rotation + swing), radius - thickness, thickness)]

proc wallShape(piece: Component, radius: Fixed): seq[Collider] =
  ## `setLength` of wall that turns by `setCurve` degrees from end to end,
  ## as a chain of straight pieces. The middle of the chain runs along the
  ## rotation, and the two ends lie evenly about the place of the wall.
  let
    curve = piece.settings[setCurve]
    pieces = toInt(abs(curve)) div WallDegreesPerSegment + 1
    step = scaled(piece.settings[setLength], piece.sizePercent) / int32(pieces)
    surface = Surface(toInt(piece.settings[setBounce]))
  var point = FixedVec2Zero
  for index in 0 ..< pieces:
    let
      turn = curve * int32(2 * index + 1) / int32(2 * pieces) - curve / 2'i32
      next = point + heading(piece.rotation + turn) * step
    result.add Collider(a: point, b: next, radius: radius, surface: surface)
    point = next
  let shift = piece.pos - point / 2'i32
  for collider in result.mitems:
    collider.a += shift
    collider.b += shift

proc shapeOf(piece: Component): seq[Collider] =
  let
    radius = scaled(KindInfos[piece.kind].radius, piece.sizePercent)
    along = heading(piece.rotation)
    wire = scaled(WireRadius, piece.sizePercent)
    isOn = piece.settings[setEnabled] == 1'fx
  case piece.kind
  of ckPopBumper, ckPassiveBumper, ckRubberPost:
    bumperShape(piece, radius)
  of ckSlingshot:
    slingshotShape(piece, radius)
  of ckStandupTarget, ckToggleTarget:
    plateShape(piece, radius)
  of ckDropTarget:
    if piece.isDown: @[] else: plateShape(piece, radius)
  of ckSpinner:
    @[sensor(bar(piece.pos, along, radius, wire))]
  of ckRollover:
    # Button style is a spot, lane style a wire along the lane.
    let halfLength = if piece.settings[setStyle] == 1'fx: 0'fx else: radius
    @[sensor(bar(piece.pos, along, halfLength, wire))]
  of ckCaptiveBall:
    captiveBallShape(piece, radius)
  of ckSaucer, ckScoop, ckBallLock, ckKicker, ckKickback:
    holeShape(piece, radius)
  of ckGate:
    if isOn: @[] else: gateShape(piece, radius)   # Enabled means open both ways.
  of ckDiverter:
    diverterShape(piece, radius)
  of ckUpPost:
    if isOn: @[circle(piece.pos, radius, surfaceRubber)] else: @[]
  of ckWall:
    wallShape(piece, radius)
  of ckNone, ckMagnet, ckMouth, ckTrack, ckInsert, ckFlasher:
    @[]

proc rebuildColliders*(component: var Component) =
  ## Derive `component.colliders` from its kind, place, size and settings.
  ## A piece that is not solid, or a drop target that is down, has none.
  component.colliders = if component.phase == phaseSolid: shapeOf(component) else: @[]
  for collider in component.colliders.mitems:
    collider.componentId = component.id
