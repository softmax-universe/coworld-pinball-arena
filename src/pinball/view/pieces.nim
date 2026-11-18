## What each kind of component looks like: a few simple shapes per kind, so
## that a player can tell the pieces apart at a glance.
##
## A piece is a list of parts. A part is one mesh with one material, plus a
## note of how it moves or glows while the game runs (a drop target sinks, a
## spinner flag turns, a lamp lights). The table view applies those each
## frame; nothing here looks at the state of the game beyond the shape of
## the piece.
##
## A piece is built about its own place: `x` runs along its rotation, `z`
## across it, `y` up, in millimetres. The sizes follow the collision shapes
## in `sim/shapes.nim`, so what the ball bounces off is what the player sees.
## A track is the exception: it runs between two other pieces, so it is built
## in table coordinates.

import
  std/math,
  vmath, chroma,
  ../sim/[types, catalogue, tracks],
  meshes

const
  LevelHeight* = 34'f32
    ## Millimetres between one level and the next as drawn. A little more
    ## than the simulation's 25 mm, so the levels read from above.
  WallHeight* = 24'f32
  PlateHeight = 24'f32
  DropTargetTravel = 23'f32
  UpPostHeight = 22'f32
  DiverterSwingDegrees* = 25'f32     ## Keep in step with `sim/shapes.nim`.
  ThroatDepth = 30'f32               ## Keep in step with `sim/tracks.nim`.
  TrackStep = 10'f32                 ## Millimetres between samples of a track curve.
  TrackPostSpacing = 12              ## Samples between two support posts.
  TrackHoopSpacing = 5               ## Samples between two hoops of a wire ramp.

  White = color(0.93, 0.92, 0.88, 1)
  Steel = color(0.70, 0.73, 0.82, 1)
  DarkMetal = color(0.20, 0.21, 0.28, 1)
  BlackRubber = color(0.06, 0.06, 0.08, 1)
  RedRubber = color(0.80, 0.10, 0.12, 1)
  Pit = color(0.015, 0.015, 0.04, 1)
  Orange = color(1.0, 0.48, 0.05, 1)
  Teal = color(0.10, 0.62, 0.66, 1)
  Purple = color(0.45, 0.25, 0.75, 1)
  ClearPlastic = color(0.35, 0.75, 1.0, 0.38)   ## Level 3 track.

  LampColours*: array[LampColour, Color] = [
    colourYellow: color(1.0, 0.80, 0.12, 1),
    colourRed: color(1.0, 0.16, 0.12, 1),
    colourGreen: color(0.18, 0.95, 0.32, 1),
    colourBlue: color(0.22, 0.48, 1.0, 1),
    colourWhite: color(0.95, 0.96, 1.0, 1)
  ]
  UnlitLampShare = 0.38'f32   ## How bright a lamp that is off still looks.

type
  Motion* = enum
    motionNone
    motionSink    ## Goes straight down by `travel` mm (drop target, up-post).
    motionTurn    ## Turns about `axis` through `pivot` (spinner flag, gate flap).
    motionSwing   ## Turns level about the place of the piece (diverter blade).

  Part* = object
    mesh*: ToonMesh
    material*: ToonMaterial
    glows*: bool          ## Lit by the lamp of the piece.
    glowColour*: Color
    castsShadow*: bool
    face*: int            ## Shown only while a toggle target shows this face. -1: always.
    motion*: Motion
    travel*: float32
    pivot*, axis*: Vec3

  PieceShape = object
    ## Collects the parts of one piece while it is being built.
    parts: seq[Part]

proc paint(colour: Color): ToonMaterial =
  ToonMaterial(color: colour)

proc metal(colour = Steel, shine = 0.6'f32): ToonMaterial =
  ToonMaterial(color: colour, chrome: shine)

proc chrome(): ToonMaterial =
  ToonMaterial(color: color(1, 1, 1, 1), chrome: 1)

proc flat(colour: Color): ToonMaterial =
  ## For marks on the playfield, which must not pick up shading.
  ToonMaterial(color: colour, unlit: true)

proc dimmed(colour: Color): Color =
  color(colour.r * UnlitLampShare, colour.g * UnlitLampShare, colour.b * UnlitLampShare, 1)

proc add(shape: var PieceShape, material: ToonMaterial, castsShadow = true): ToonMesh =
  ## A new empty part. Fill the mesh that comes back.
  result = ToonMesh()
  shape.parts.add Part(mesh: result, material: material, face: -1,
    castsShadow: castsShadow and material.color.a >= 1 and not material.unlit)

proc addLamp(shape: var PieceShape, colour: Color, castsShadow = false): ToonMesh =
  ## A new part that glows in `colour` when the lamp of the piece is lit.
  result = shape.add(paint(dimmed(colour)), castsShadow)
  shape.parts[^1].glows = true
  shape.parts[^1].glowColour = colour

proc last(shape: var PieceShape): var Part =
  shape.parts[^1]

proc lampColour*(piece: Component): Color =
  LampColours[LampColour(clamp(toInt(piece.settings[setColour]), 0, ord(high(LampColour))))]

proc ground(x, z: float32): Vec3 =
  vec3(x, 0, z)

# --- One proc per family of shapes -----------------------------------------------

proc buildBumper(shape: var PieceShape, piece: Component, radius: float32) =
  case piece.kind
  of ckPopBumper:
    let body = shape.add(paint(White))
    body.addCylinder(ground(0, 0), radius, 5)
    body.addCylinder(ground(0, 0), radius * 0.62, 26)
    shape.add(chrome()).addHoop(vec3(0, 9, 0), radius * 0.86, 2.2)
    let cap = shape.addLamp(piece.lampColour, castsShadow = true)
    cap.addCylinder(vec3(0, 26, 0), radius * 0.98, 4)
    cap.addDome(vec3(0, 30, 0), radius * 0.86, 9)
  of ckPassiveBumper:
    shape.add(paint(White)).addCylinder(ground(0, 0), radius * 0.5, 22)
    shape.add(paint(BlackRubber)).addHoop(vec3(0, 10, 0), radius * 0.8, radius * 0.2)
    shape.add(paint(Teal)).addCylinder(vec3(0, 22, 0), radius * 0.72, 3)
  else:  # Rubber post.
    shape.add(chrome()).addCylinder(ground(0, 0), radius * 0.45, 19)
    shape.add(paint(RedRubber)).addHoop(vec3(0, 9, 0), radius * 0.72, radius * 0.26)

proc buildSlingshot(shape: var PieceShape, radius, size: float32) =
  let
    corners = [vec2(-radius * 0.8, -radius * 0.2), vec2(radius * 0.8, -radius * 0.2),
               vec2(0, radius * 0.6)]
    posts = shape.add(chrome())
    band = shape.add(paint(RedRubber))
  for index, corner in corners:
    posts.addCylinder(ground(corner.x, corner.y), 3 * size, 20)
    band.addWall(corner, corners[(index + 1) mod 3], 2.4 * size, 7, 13)
  shape.add(paint(Orange)).addPrism(corners, 20, 22.5)

proc buildPlate(shape: var PieceShape, piece: Component, radius, size: float32) =
  ## Standup, drop and toggle targets: an upright plate across the rotation.
  let
    halfLength = radius
    halfThickness = 3 * size
    low = vec3(-halfLength, 0, -halfThickness)
    high = vec3(halfLength, PlateHeight, halfThickness)
  case piece.kind
  of ckStandupTarget:
    shape.add(metal()).addBox(vec3(-radius * 0.5, 0, -5 * size), vec3(radius * 0.5, 4, 5 * size))
    shape.addLamp(piece.lampColour, castsShadow = true).addBox(low, high)
  of ckDropTarget:
    # The slot stays where it is, so a dropped target leaves a dark gap.
    shape.add(flat(Pit)).addWall(vec2(-halfLength, 0), vec2(halfLength, 0),
      halfThickness + 2, 0.1, 0.3)
    shape.add(paint(White)).addBox(low, high)
    shape.last.motion = motionSink
    shape.last.travel = DropTargetTravel
    shape.add(paint(RedRubber)).addBox(vec3(low.x, PlateHeight, low.z),
      vec3(high.x, PlateHeight + 2, high.z))
    shape.last.motion = motionSink
    shape.last.travel = DropTargetTravel
  else:  # Toggle target: one plate per face, and a pivot post at each end.
    let posts = shape.add(chrome())
    posts.addCylinder(ground(-halfLength, 0), 3.2 * size, PlateHeight + 3)
    posts.addCylinder(ground(halfLength, 0), 3.2 * size, PlateHeight + 3)
    shape.addLamp(piece.lampColour, castsShadow = true).addBox(low, high)
    shape.last.face = 0
    shape.add(paint(Purple)).addBox(low, high)
    shape.last.face = 1

proc buildSpinner(shape: var PieceShape, radius: float32) =
  const AxleHeight = 20'f32
  let frame = shape.add(chrome())
  frame.addPost(ground(-radius - 2, 0), AxleHeight, 1.5)
  frame.addPost(ground(radius + 2, 0), AxleHeight, 1.5)
  frame.addTube([vec3(-radius - 2, AxleHeight, 0), vec3(radius + 2, AxleHeight, 0)], 1.2)
  shape.add(paint(Orange)).addBox(vec3(-radius + 2, -9, -1), vec3(radius - 2, 9, 1))
  shape.last.motion = motionTurn
  shape.last.pivot = vec3(0, AxleHeight, 0)
  shape.last.axis = vec3(1, 0, 0)

proc buildRollover(shape: var PieceShape, piece: Component, radius, size: float32) =
  if piece.settings[setStyle] == 1'fx:
    # Button style.
    shape.addLamp(piece.lampColour).addDisc(vec3(0, 0.3, 0), radius * 0.95)
    shape.add(paint(White)).addDome(vec3(0, 0.3, 0), radius * 0.45, 4)
  else:
    # Lane style: a wire in a slot.
    shape.addLamp(piece.lampColour).addWall(vec2(-radius, 0), vec2(radius, 0), 6 * size, 0.1, 0.3)
    shape.add(flat(Pit)).addWall(vec2(-radius, 0), vec2(radius, 0), 2.6 * size, 0.1, 0.5)
    shape.add(chrome()).addTube(
      [vec3(-radius, 0.5, 0), vec3(-radius * 0.6, 3.5, 0), vec3(radius * 0.6, 3.5, 0),
       vec3(radius, 0.5, 0)], 0.9)

proc buildCaptiveBall(shape: var PieceShape, piece: Component, radius, size: float32) =
  let
    half = toFloat32(scaled(piece.settings[setLength], piece.sizePercent)) / 2
    side = radius - 1.5 * size
    rails = shape.add(metal())
  rails.addWall(vec2(-half, side), vec2(half, side), 1.5 * size, 0, 13)
  rails.addWall(vec2(-half, -side), vec2(half, -side), 1.5 * size, 0, 13)
  shape.add(chrome()).addBall(vec3(-half, radius, 0), radius)
  shape.add(paint(RedRubber)).addBox(vec3(half - 2, 0, -radius), vec3(half + 2, 20, radius))

proc addRim(shape: var PieceShape, radius: float32, material: ToonMaterial) =
  ## The raised edge round a hole.
  shape.add(material).addLathe(ground(0, 0),
    [vec2(radius, 0), vec2(radius, 3), vec2(radius - 3, 3), vec2(radius - 4.5, 0.4)])

proc addArrow(shape: var PieceShape, degrees, length: float32, material: ToonMaterial,
              lamp = false, colour = White, at = vec2(0, 0)) =
  ## A flat arrowhead on the piece that points along `degrees` (of the piece).
  let
    along = vec2(cos(degToRad(degrees)), sin(degToRad(degrees)))
    across = vec2(-along.y, along.x)
    outline = [at + along * length, at - along * length * 0.6 + across * length * 0.75,
               at - along * length * 0.25, at - along * length * 0.6 - across * length * 0.75]
    mesh = if lamp: shape.addLamp(colour) else: shape.add(material, castsShadow = false)
  # The outline is a dart, which is not convex, so it is laid as two triangles.
  mesh.addFlatPolygon([outline[0], outline[1], outline[2]], 0.9)
  mesh.addFlatPolygon([outline[0], outline[2], outline[3]], 0.9)

proc buildHole(shape: var PieceShape, piece: Component, radius, size: float32) =
  ## Saucer, scoop, lock, kicker and kickback: things that lie in the table.
  let fireDegrees = toFloat32(piece.settings[setDirection] - piece.rotation)
  case piece.kind
  of ckSaucer:
    shape.add(flat(color(0.03, 0.04, 0.10, 1))).addDisc(vec3(0, 0.4, 0), radius - 3)
    shape.addRim(radius, chrome())
  of ckScoop:
    shape.add(flat(Pit)).addDisc(vec3(0, 0.4, 0), radius - 1)
    # A hood round the back, away from where the ball comes out.
    let hood = shape.add(metal(Purple, 0.35))
    var previous: Vec2
    for step in 0 .. 8:
      let
        angle = degToRad(fireDegrees + 180 + (step.float32 - 4) * 22.5)
        point = vec2(cos(angle), sin(angle)) * radius
      if step > 0:
        hood.addWall(previous, point, 2.5 * size, 0, 20)
      previous = point
  of ckBallLock:
    shape.add(flat(color(0.02, 0.08, 0.04, 1))).addDisc(vec3(0, 0.4, 0), radius - 3)
    shape.addRim(radius, metal(color(0.15, 0.75, 0.35, 1), 0.3))
    let cage = shape.add(chrome())
    for corner in 0 ..< 4:
      let angle = degToRad(45 + corner.float32 * 90)
      cage.addPost(ground(cos(angle) * radius, sin(angle) * radius), 18, 1.6)
  of ckKicker:
    shape.add(metal(DarkMetal, 0.3), castsShadow = false).addDisc(vec3(0, 0.4, 0), radius)
    shape.addRim(radius, chrome())
    shape.addArrow(fireDegrees, radius * 0.62, flat(Orange))
  else:  # Kickback: a square plate, and an arrow that is lit while it is armed.
    shape.add(metal(DarkMetal, 0.3), castsShadow = false).addBox(
      vec3(-radius, 0, -radius), vec3(radius, 0.5, radius))
    shape.addArrow(fireDegrees, radius * 0.7, flat(White), lamp = true,
      colour = LampColours[colourGreen])

proc buildMagnet(shape: var PieceShape, piece: Component, radius: float32) =
  let colour = case toInt(piece.settings[setMode])
    of 1: LampColours[colourBlue]     # Repels.
    of 2: LampColours[colourGreen]    # Holds.
    else: LampColours[colourRed]      # Attracts.
  shape.add(flat(color(0.10, 0.10, 0.14, 1))).addDisc(vec3(0, 0.3, 0), radius)
  shape.addLamp(colour).addDisc(vec3(0, 0.4, 0), radius * 0.82, radius * 0.60)
  shape.add(chrome(), castsShadow = false).addCylinder(ground(0, 0), radius * 0.36, 1.5)

proc buildGate(shape: var PieceShape, radius: float32) =
  ## A wire flap that hangs across the rotation from a bar between two posts.
  const BarHeight = 21'f32
  let frame = shape.add(chrome())
  frame.addPost(ground(0, -radius), BarHeight, 1.5)
  frame.addPost(ground(0, radius), BarHeight, 1.5)
  frame.addTube([vec3(0, BarHeight, -radius), vec3(0, BarHeight, radius)], 1.2)
  shape.add(metal(Steel, 0.4)).addBox(vec3(-0.8, 3, -radius + 2.5), vec3(0.8, BarHeight, radius - 2.5))
  shape.last.motion = motionTurn
  shape.last.pivot = vec3(0, BarHeight, 0)
  shape.last.axis = vec3(0, 0, 1)
  # The way the gate lets a ball through.
  shape.addArrow(0, radius * 0.4, flat(color(0.75, 0.80, 0.95, 1)), at = vec2(radius * 0.75, 0))

proc buildDiverter(shape: var PieceShape, radius, size: float32) =
  shape.add(chrome()).addCylinder(ground(0, 0), 4.5 * size, 21)
  shape.add(metal(color(0.25, 0.50, 0.95, 1), 0.3)).addWall(
    vec2(-radius + 3 * size, 0), vec2(radius - 3 * size, 0), 3 * size, 1.5, 17)
  shape.last.motion = motionSwing

proc buildUpPost(shape: var PieceShape, radius: float32) =
  shape.add(flat(Pit)).addDisc(vec3(0, 0.3, 0), radius + 1.5)
  shape.add(chrome()).addCylinder(ground(0, 0), radius, UpPostHeight)
  shape.last.motion = motionSink
  shape.last.travel = UpPostHeight - 1
  shape.add(paint(RedRubber)).addCylinder(vec3(0, UpPostHeight, 0), radius * 0.7, 1.5)
  shape.last.motion = motionSink
  shape.last.travel = UpPostHeight - 1

proc wallPath(piece: Component): seq[Vec2] =
  ## The centre line of a wall. The same construction as `sim/shapes.nim`.
  const DegreesPerSegment = 15
  let
    curve = toFloat32(piece.settings[setCurve])
    pieces = int(abs(curve)) div DegreesPerSegment + 1
    step = toFloat32(scaled(piece.settings[setLength], piece.sizePercent)) / pieces.float32
  result.add vec2(0, 0)
  for index in 0 ..< pieces:
    let turn = degToRad(curve * (2 * index + 1).float32 / (2 * pieces).float32 - curve / 2)
    result.add result[^1] + vec2(cos(turn), sin(turn)) * step
  let shift = result[^1] / 2
  for point in result.mitems:
    point -= shift

proc buildWall(shape: var PieceShape, piece: Component, radius: float32) =
  let path = wallPath(piece)
  case Surface(clamp(toInt(piece.settings[setBounce]), 0, ord(high(Surface))))
  of surfaceMetal:
    shape.add(metal()).addWallPath(path, radius, 0, WallHeight)
  of surfaceRubber:
    # A rubber band stretched between two posts.
    let posts = shape.add(chrome())
    posts.addCylinder(ground(path[0].x, path[0].y), radius * 0.8, WallHeight)
    posts.addCylinder(ground(path[^1].x, path[^1].y), radius * 0.8, WallHeight)
    shape.add(paint(RedRubber)).addWallPath(path, radius, 6, 15)
  of surfaceDead:
    shape.add(paint(color(0.16, 0.15, 0.20, 1))).addWallPath(path, radius, 0, WallHeight * 0.8)

proc addSupportPost(mesh: ToonMesh, top: Vec3) =
  ## A rod from the playfield up to a raised part.
  if top.y > 2:
    mesh.addTube([vec3(top.x, 0, top.z), top], 1.4, sides = 6)

proc buildRails(shape: var PieceShape, left, right: seq[Vec3], level: int32) =
  ## The two sides of a mouth or a track, in the material of their level:
  ## low steel guides on the playfield, chrome wire on level 2 and tinted
  ## clear plastic on level 3. `left` and `right` are the feet of the rails.
  if level <= 1:
    let rails = shape.add(metal())
    for side in [left, right]:
      for index in 1 .. side.high:
        rails.addWall(vec2(side[index - 1].x, side[index - 1].z),
          vec2(side[index].x, side[index].z), 2, 0, 13)
  elif level == 2:
    let wire = shape.add(chrome())
    for side in [left, right]:
      var upper: seq[Vec3]
      for point in side:
        upper.add point + vec3(0, 11, 0)
      wire.addTube(side, 2.0)
      wire.addTube(upper, 2.0)
    # Two more wires under the ball make the floor of the ramp.
    for share in [0.33'f32, 0.67]:
      var floorWire: seq[Vec3]
      for index in 0 .. left.high:
        floorWire.add mix(left[index], right[index], share) - vec3(0, 2, 0)
      wire.addTube(floorWire, 1.8)
  else:
    let plastic = shape.add(ToonMaterial(color: ClearPlastic))
    for index in 1 .. left.high:
      plastic.addQuad(left[index - 1], right[index - 1], right[index], left[index])
      for side in [left, right]:
        plastic.addQuad(side[index - 1], side[index], side[index] + vec3(0, 12, 0),
          side[index - 1] + vec3(0, 12, 0), facing = vec3(1, 0, 0))
    # A bright edge along the top of each side, so the clear ramp has an outline.
    let edge = shape.add(ToonMaterial(color: color(0.6, 0.9, 1.0, 1), unlit: true),
      castsShadow = false)
    for side in [left, right]:
      var upper: seq[Vec3]
      for point in side:
        upper.add point + vec3(0, 12, 0)
      edge.addTube(upper, 0.8, sides = 5)

proc buildMouth(shape: var PieceShape, piece: Component, size: float32) =
  ## A funnel: wide at the open end, which is at the place of the piece, and
  ## narrow at the throat behind it, where the track starts.
  let
    halfOpen = toFloat32(scaled(piece.settings[setWidthA], piece.sizePercent)) / 2
    halfThroat = toFloat32(scaled(piece.settings[setWidthB], piece.sizePercent)) / 2
    depth = ThroatDepth * size
    left = @[vec3(0, 0, -halfOpen), vec3(-depth, 0, -halfThroat)]
    right = @[vec3(0, 0, halfOpen), vec3(-depth, 0, halfThroat)]
  shape.buildRails(left, right, piece.level)
  if piece.level > 1:
    let posts = shape.add(chrome())
    for corner in [left[0], right[0]]:
      # The part is drawn at the height of its level, so the playfield is below it.
      posts.addTube([corner - vec3(0, LevelHeight * (piece.level - 1).float32, 0), corner], 1.4,
        sides = 6)

proc levelY*(level: int32): float32 =
  LevelHeight * (max(level, 1) - 1).float32

proc trackHeight*(levelA, levelB: int32, share: float32): float32 =
  ## The height of a track `share` of the way from mouth A to mouth B. The
  ## climb eases in and out, so a ramp meets both mouths level.
  let eased = share * share * (3 - 2 * share)
  mix(levelY(levelA), levelY(levelB), eased)

proc buildTrack(shape: var PieceShape, table: Table, track: Component) =
  let
    mouthA = table.componentIndex(toInt(track.settings[setMouthA]))
    mouthB = table.componentIndex(toInt(track.settings[setMouthB]))
    length = table.trackLength(track)
  if mouthA < 0 or mouthB < 0 or length <= 0'fx:
    return
  let
    levelA = table.components[mouthA].level
    levelB = table.components[mouthB].level
    widthA = toFloat32(scaled(table.components[mouthA].settings[setWidthB],
      table.components[mouthA].sizePercent))
    widthB = toFloat32(scaled(table.components[mouthB].settings[setWidthB],
      table.components[mouthB].sizePercent))
    samples = max(int(toFloat32(length) / TrackStep), 2)
  var centre: seq[Vec3]
  for sample in 0 .. samples:
    let
      share = sample.float32 / samples.float32
      point = table.trackPoint(track,
        multiplyDivide(length, fixed(int32(sample)), fixed(int32(samples))))
    centre.add vec3(toFloat32(point.x), trackHeight(levelA, levelB, share), toFloat32(point.y))
  var left, right: seq[Vec3]
  for sample, point in centre:
    var along = centre[min(sample + 1, samples)] - centre[max(sample - 1, 0)]
    along.y = 0
    along = if along.length < 1e-4: vec3(1, 0, 0) else: normalize(along)
    let
      across = vec3(-along.z, 0, along.x)
      halfWidth = mix(widthA, widthB, sample.float32 / samples.float32) / 2
    left.add point - across * halfWidth
    right.add point + across * halfWidth
  let level = max(levelA, levelB)
  shape.buildRails(left, right, level)
  if level > 1:
    let frame = shape.add(chrome())
    for sample in countup(TrackPostSpacing div 2, samples, TrackPostSpacing):
      frame.addSupportPost(left[sample])
      frame.addSupportPost(right[sample])
    if level == 2:
      # Hoops tie the wires of a wire ramp together.
      for sample in countup(1, samples - 1, TrackHoopSpacing):
        frame.addTube([left[sample] + vec3(0, 11, 0), left[sample],
          mix(left[sample], right[sample], 0.5) - vec3(0, 3, 0), right[sample],
          right[sample] + vec3(0, 11, 0)], 1.1, sides = 6)

proc buildLamp(shape: var PieceShape, piece: Component, radius: float32) =
  if piece.kind == ckInsert:
    shape.add(flat(color(0.02, 0.02, 0.05, 1))).addDisc(vec3(0, 0.2, 0), radius + 1.3, radius)
    shape.addLamp(piece.lampColour).addDisc(vec3(0, 0.3, 0), radius)
  else:  # Flasher.
    shape.add(chrome(), castsShadow = false).addCylinder(ground(0, 0), radius + 1.5, 2)
    shape.addLamp(piece.lampColour, castsShadow = true).addDome(vec3(0, 2, 0), radius, 9)

proc buildParts*(table: Table, piece: Component): seq[Part] =
  ## The parts of one piece, for its place, size and settings as they are now.
  let
    size = piece.sizePercent.float32 / 100
    radius = toFloat32(scaled(KindInfos[piece.kind].radius, piece.sizePercent))
  var shape: PieceShape
  case piece.kind
  of ckPopBumper, ckPassiveBumper, ckRubberPost: shape.buildBumper(piece, radius)
  of ckSlingshot: shape.buildSlingshot(radius, size)
  of ckStandupTarget, ckDropTarget, ckToggleTarget: shape.buildPlate(piece, radius, size)
  of ckSpinner: shape.buildSpinner(radius)
  of ckRollover: shape.buildRollover(piece, radius, size)
  of ckCaptiveBall: shape.buildCaptiveBall(piece, radius, size)
  of ckSaucer, ckScoop, ckBallLock, ckKicker, ckKickback: shape.buildHole(piece, radius, size)
  of ckMagnet: shape.buildMagnet(piece, radius)
  of ckGate: shape.buildGate(radius)
  of ckDiverter: shape.buildDiverter(radius, size)
  of ckUpPost: shape.buildUpPost(radius)
  of ckWall: shape.buildWall(piece, radius)
  of ckMouth: shape.buildMouth(piece, size)
  of ckTrack: shape.buildTrack(table, piece)
  of ckInsert, ckFlasher: shape.buildLamp(piece, radius)
  of ckNone: discard
  shape.parts
