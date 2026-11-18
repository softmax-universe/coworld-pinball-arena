## Drawing the table: one fixed camera at the player's end, the fixed parts
## of the table, the flippers, the balls and every component.
##
## The view only reads the `Table`. It keeps a little state of its own for
## things that are shown but are not part of the game: the meshes of each
## piece, how far a drop target has sunk on screen, the glow left over from a
## hit, the effects for the rules' flasher and burst cues.
##
## Table coordinates become world coordinates as (x, height, y) in
## millimetres: `x` to the right, the world `y` up, and the world `z` toward
## the player.

import
  std/[hashes, math],
  opengl, vmath, chroma,
  ../../polyworld/[toon, shadows, shapes],
  ../sim/[types, layout, catalogue, tracks],
  meshes, pieces, playfieldart

const
  # Camera. The table is framed for a canvas of `DesignAspect` (width over
  # height). A narrower canvas widens the view so the sides still fit.
  CameraTarget = vec3(261, 0, 548)
  CameraPitchDegrees = 63'f32      ## Above level. 90 would look straight down.
  CameraDistance = 3150'f32
  CameraFovDegrees = 20'f32
  DesignAspect = 0.58'f32

  # Light. It comes from the far left, so shadows fall toward the player's right.
  LightAzimuthDegrees = 222'f32
  LightElevationDegrees = 58'f32
  ShadowTint = color(0.36, 0.33, 0.52, 1)
  RimTint = color(0.55, 0.65, 1.0, 0.22)
  Backdrop = color(0.012, 0.010, 0.030, 1)

  # Fixed parts.
  CabinetHeight = WallHeight + 5
  CabinetMargin = 30'f32           ## Width of the cabinet frame round the playfield.
  ApronHeight = 34'f32
  ApronTopZ = 1040'f32             ## The far edge of the apron. Just above the drain line.
  LaneDividerX = 478'f32           ## Keep in step with `sim/layout.nim`.
  CabinetColour = color(0.11, 0.08, 0.22, 1)
  ApronColour = color(0.30, 0.16, 0.48, 1)
  RailColour = color(0.74, 0.77, 0.86, 1)
  FlipperColour = color(0.95, 0.94, 0.90, 1)
  FlipperBandColour = color(0.85, 0.10, 0.14, 1)

  # Holograms and fades.
  HologramColour = color(0.25, 0.95, 1.0, 0.60)
  HologramRing = rgbx(70, 240, 255, 200)

  # Lamps and effects.
  FlashesPerSecond = 4'f32
  HitGlowSeconds = 0.22'f32
  FlasherSeconds = 0.6'f32
  BurstSeconds = 0.55'f32
  BurstColour = color(1.0, 0.85, 0.35, 1)
  EaseRate = 18'f32                ## How fast moving parts settle, per second.
  SpinnerSpeed = 22'f32            ## Radians per second while a spinner turns.
  GateOpenDegrees = 70'f32

type
  PieceView = object
    ## What the view remembers about one component.
    id: int32
    signature: Hash
    parts: seq[Part]
    sink: float32       ## 0 up .. 1 down, for drop targets and up-posts.
    turn: float32       ## Radians, for a spinner flag or a gate flap.
    swing: float32      ## Degrees, for a diverter blade.
    hitGlow: float32    ## 1 just touched .. 0.
    wasSolid: bool
    stillThere: bool

  Burst = object
    at: Vec3
    age: float32

  TableView* = ref object
    toon: ToonContext
    marks: ShapeRenderer     ## Flat see-through marks on the playfield.
    glows: ShapeRenderer     ## Light: halos, bursts, flashes.
    starfield: GLuint
    playfield, cabinet, rails, wires, apron: ToonMesh
    plungerMesh, flipperBody, flipperBand, ballMesh: ToonMesh
    pieceViews: seq[PieceView]
    viewProjection: Mat4
    time: float32
    flasherGlow: float32
    bursts: seq[Burst]

proc toVec2(point: FixedVec2): Vec2 =
  vec2(toFloat32(point.x), toFloat32(point.y))

proc onTable(point: FixedVec2, height = 0'f32): Vec3 =
  vec3(toFloat32(point.x), height, toFloat32(point.y))

proc placed(at: Vec3, degrees: float32): Mat4 =
  ## The transform of a piece at `at`, turned by `degrees` the way the table
  ## counts angles: the piece's own x axis lies along the angle.
  let
    c = cos(degToRad(degrees))
    s = sin(degToRad(degrees))
  result = mat4()
  result[0, 0] = c
  result[0, 2] = s
  result[2, 0] = -s
  result[2, 2] = c
  result[3, 0] = at.x
  result[3, 1] = at.y
  result[3, 2] = at.z

proc scaledColour(colour: Color, amount: float32): Color =
  color(colour.r * amount, colour.g * amount, colour.b * amount, 1)

proc faded(colour: Color, alpha: float32): ColorRGBX =
  ## For the shape renderers. The alpha stays below 255, because they halve
  ## a fully opaque colour.
  rgbx(uint8(clamp(colour.r, 0, 1) * 255), uint8(clamp(colour.g, 0, 1) * 255),
    uint8(clamp(colour.b, 0, 1) * 255), uint8(clamp(alpha, 0, 0.99) * 255))

# --- Fixed parts -------------------------------------------------------------------

proc buildFixedParts(view: TableView) =
  let outline = playfieldOutline()
  var ground: seq[Vec2]
  for point in outline:
    ground.add point.toVec2
  view.playfield = ToonMesh()
  view.playfield.addFlatPolygon(ground, 0, uvSize = vec2(PlayfieldWidth, PlayfieldHeight))

  # The cabinet: a frame round the playfield, filled in behind the arch.
  view.cabinet = ToonMesh()
  let
    width = PlayfieldWidth.float32
    length = PlayfieldHeight.float32
  for index in 1 .. ground.high:
    let
      a = ground[index - 1]
      b = ground[index]
    if a.y < length and b.y < length and b.x > a.x:
      view.cabinet.addQuad(
        vec3(a.x, CabinetHeight, a.y), vec3(b.x, CabinetHeight, b.y),
        vec3(b.x, CabinetHeight, -CabinetMargin), vec3(a.x, CabinetHeight, -CabinetMargin))
  view.cabinet.addBox(vec3(-CabinetMargin, 0, -CabinetMargin), vec3(0, CabinetHeight, length + CabinetMargin))
  view.cabinet.addBox(vec3(width, 0, -CabinetMargin), vec3(width + CabinetMargin, CabinetHeight, length + CabinetMargin))
  view.cabinet.addBox(vec3(0, 0, length), vec3(width, CabinetHeight, length + CabinetMargin))

  # Walls, arch, lane divider and lane guides, straight from the collision
  # shapes. The one-way gate at the top of the shooter lane is a low wire.
  view.rails = ToonMesh()
  view.wires = ToonMesh()
  for collider in fixedColliders():
    let
      a = collider.a.toVec2
      b = collider.b.toVec2
      radius = toFloat32(collider.radius)
    if collider.passDirection != fixedVec2(0'fx, 0'fx):
      view.wires.addTube([vec3(a.x, 11, a.y), vec3(b.x, 11, b.y)], 1.3)
      view.wires.addPost(vec3(a.x, 0, a.y), 13, 1.5)
      view.wires.addPost(vec3(b.x, 0, b.y), 13, 1.5)
    else:
      view.rails.addWall(a, b, radius, 0, WallHeight)

  # The apron covers the drain: a ball that rolls under its far edge is gone.
  view.apron = ToonMesh()
  view.apron.addBox(vec3(0, 0, ApronTopZ), vec3(LaneDividerX, ApronHeight, length))
  view.rails.addTube([vec3(0, ApronHeight, ApronTopZ), vec3(LaneDividerX, ApronHeight, ApronTopZ)], 2.5)

  # The plunger at rest: the bar the ball sits on and the rod behind it.
  let tip = plungerCollider(0'fx)
  view.plungerMesh = ToonMesh()
  view.plungerMesh.addWall(tip.a.toVec2, tip.b.toVec2, toFloat32(tip.radius), 0, 18)
  let middle = (tip.a.toVec2 + tip.b.toVec2) / 2
  view.plungerMesh.addTube([vec3(middle.x, 10, middle.y), vec3(middle.x, 10, length + CabinetMargin)], 3.5)

  # A flipper, lying along +x from its pivot.
  let
    flipperLength = toFloat32(FlipperLength)
    flipperRadius = toFloat32(FlipperRadius)
  view.flipperBody = ToonMesh()
  view.flipperBody.addWall(vec2(0, 0), vec2(flipperLength, 0), flipperRadius - 1, 1, 19)
  view.flipperBody.addCylinder(vec3(0, 0, 0), flipperRadius + 2.5, 21)
  view.flipperBand = ToonMesh()
  view.flipperBand.addWall(vec2(0, 0), vec2(flipperLength, 0), flipperRadius, 6, 14)

  view.ballMesh = ToonMesh()
  view.ballMesh.addBall(vec3(0, 0, 0), toFloat32(BallRadius))

proc newTableView*(): TableView =
  ## Needs a current GL context.
  result = TableView()
  result.toon = newToonContext()
  result.toon.setRamp(rampImage(0.0, 0.95))
  result.toon.shadowColor = ShadowTint
  result.toon.rimColor = RimTint
  result.marks = initShapeRenderer()
  result.glows = initShapeRenderer()
  result.glows.additive = true
  result.starfield = uploadTexture(starfieldImage())

  sunAzimuth = LightAzimuthDegrees
  sunElevation = LightElevationDegrees
  sunLightTarget = vec3(PlayfieldWidth / 2, 0, PlayfieldHeight / 2)
  sunShadowStrength = 0.9
  initSunShadows(lightRadius = 720, lightDistance = 1600)
  updateSunMatrix()
  result.toon.lightDirection = -sunDirection

  result.buildFixedParts()

# --- Camera ------------------------------------------------------------------------

proc aimCamera(view: TableView, framebufferSize: IVec2) =
  let
    aspect = framebufferSize.x.float32 / max(framebufferSize.y, 1).float32
    pitch = degToRad(CameraPitchDegrees)
    eye = CameraTarget + vec3(0, sin(pitch), cos(pitch)) * CameraDistance
  var fov = CameraFovDegrees
  if aspect < DesignAspect:
    fov = radToDeg(2 * arctan(tan(degToRad(CameraFovDegrees) / 2) * DesignAspect / aspect))
  view.toon.view = lookAt(eye, CameraTarget, vec3(0, 1, 0))
  view.toon.proj = perspective(fov, aspect, 500'f32, 8000'f32)
  view.toon.cameraPosition = eye
  view.viewProjection = view.toon.proj * view.toon.view

# --- Pieces ------------------------------------------------------------------------

proc shapeSignature(table: Table, piece: Component): Hash =
  ## Changes when the meshes of the piece must be built again.
  const LiveSettings = {setLamp, setEnabled, setPosition}   # These only move or light parts.
  result = hash((ord(piece.kind), int32(piece.pos.x), int32(piece.pos.y),
    int32(piece.rotation), piece.sizePercent, piece.level))
  for setting in Setting:
    if setting notin LiveSettings:
      result = result !& hash(int32(piece.settings[setting]))
  if piece.kind == ckTrack:
    # A track follows its two mouths.
    for setting in [setMouthA, setMouthB]:
      let index = table.componentIndex(toInt(piece.settings[setting]))
      if index >= 0:
        let mouth = table.components[index]
        result = result !& hash((int32(mouth.pos.x), int32(mouth.pos.y),
          int32(mouth.rotation), mouth.sizePercent, mouth.level,
          int32(mouth.settings[setWidthB])))
  result = !$result

proc release(pieceView: PieceView) =
  for part in pieceView.parts:
    part.mesh.release()

proc pieceViewIndex(view: TableView, id: int32): int =
  for index, pieceView in view.pieceViews:
    if pieceView.id == id:
      return index
  -1

proc syncPieces(view: TableView, table: Table) =
  ## Build the meshes of new and changed pieces and drop those of pieces
  ## that are gone.
  for pieceView in view.pieceViews.mitems:
    pieceView.stillThere = false
  for piece in table.components:
    let signature = shapeSignature(table, piece)
    var index = view.pieceViewIndex(piece.id)
    if index < 0:
      view.pieceViews.add PieceView(id: piece.id, signature: signature,
        parts: buildParts(table, piece), wasSolid: piece.phase == phaseSolid,
        sink: if piece.isDown: 1 else: 0)
      index = view.pieceViews.high
    elif view.pieceViews[index].signature != signature:
      view.pieceViews[index].release()
      view.pieceViews[index].signature = signature
      view.pieceViews[index].parts = buildParts(table, piece)
    view.pieceViews[index].stillThere = true
  var index = 0
  while index < view.pieceViews.len:
    if view.pieceViews[index].stillThere:
      inc index
    else:
      view.pieceViews[index].release()
      view.pieceViews.delete index

proc isOn(piece: Component): bool =
  piece.settings[setEnabled] == 1'fx

proc lampBrightness(view: TableView, piece: Component, pieceView: PieceView): float32 =
  ## 0 dark .. 1 fully lit, for the glowing parts of a piece.
  let blink = if (view.time * FlashesPerSecond) mod 1 < 0.5: 1'f32 else: 0.15'f32
  result = case LampState(clamp(toInt(piece.settings[setLamp]), 0, ord(high(LampState))))
    of lampOff: 0'f32
    of lampOn: 1'f32
    of lampFlashing: blink
  case piece.kind
  of ckKickback:
    result = if piece.isOn: 1 else: 0
  of ckMagnet:
    result = if piece.isOn: 0.65 + 0.35 * sin(view.time * 9) else: 0
  of ckFlasher:
    result = max(result, view.flasherGlow * blink)
  else:
    discard
  result = clamp(result + pieceView.hitGlow, 0, 1.4)

proc animate(view: TableView, table: Table, seconds: float32) =
  ## Move the parts that move toward where the game says they are.
  let ease = min(seconds * EaseRate, 1)
  for piece in table.components:
    let index = view.pieceViewIndex(piece.id)
    template pieceView: untyped = view.pieceViews[index]
    pieceView.hitGlow = max(pieceView.hitGlow - seconds / HitGlowSeconds, 0)
    if piece.phase == phaseSolid and not pieceView.wasSolid:
      pieceView.hitGlow = 1          # A flash as the hologram turns solid.
    pieceView.wasSolid = piece.phase == phaseSolid
    case piece.kind
    of ckDropTarget:
      pieceView.sink += ((if piece.isDown: 1'f32 else: 0'f32) - pieceView.sink) * ease
    of ckUpPost:
      pieceView.sink += ((if piece.isOn: 0'f32 else: 1'f32) - pieceView.sink) * ease
    of ckSpinner:
      if piece.spinsLeft > 0:
        pieceView.turn += seconds * SpinnerSpeed
      else:
        # Come to rest hanging straight down, at the nearest half turn.
        let rest = round(pieceView.turn / PI) * PI
        pieceView.turn += (rest - pieceView.turn) * ease * 0.5
    of ckGate:
      let target = if piece.isOn: degToRad(GateOpenDegrees) else: pieceView.hitGlow * 0.9
      pieceView.turn += (target - pieceView.turn) * ease
    of ckDiverter:
      let target = if piece.settings[setPosition] == 1'fx: DiverterSwingDegrees
                   else: -DiverterSwingDegrees
      pieceView.swing += (target - pieceView.swing) * ease
    else:
      discard

proc observe*(view: TableView, table: Table) =
  ## Call after every tick. Picks up what happened in the tick that the view
  ## shows for a moment: a glow on a piece that was touched, and the flasher
  ## and burst effects that rules ask for.
  for event in table.events:
    if event.kind in {evHit, evDrop, evFlip, evSpin, evRollover, evCaptured, evReleased,
        evLocked, evFired, evGrabbed, evPassed, evBankComplete, evTrackEntered,
        evTrackCompleted}:
      let index = view.pieceViewIndex(event.componentId)
      if index >= 0:
        view.pieceViews[index].hitGlow = 1
  for cue in table.cues:
    case cue.kind
    of cueKindFlashers:
      view.flasherGlow = 1
    of cueKindBurst:
      let index = table.componentIndex(cue.componentId)
      let at =
        if index >= 0:
          table.components[index].pos.onTable(levelY(table.components[index].level) + 4)
        else:
          vec3(PlayfieldWidth / 2, 4, PlayfieldHeight * 0.45)
      view.bursts.add Burst(at: at)
    of cueKindSound:
      discard

proc partTransform(piece: Component, pieceView: PieceView, part: Part): Mat4 =
  if piece.kind == ckTrack:
    return mat4()   # Built in table coordinates.
  result = placed(piece.pos.onTable(levelY(piece.level)), toFloat32(piece.rotation))
  case part.motion
  of motionNone:
    discard
  of motionSink:
    result = result * translate(vec3(0, -part.travel * pieceView.sink, 0))
  of motionTurn:
    result = result * translate(part.pivot) * rotate(pieceView.turn, part.axis) *
      translate(-part.pivot)
  of motionSwing:
    result = result * placed(vec3(0, 0, 0), pieceView.swing)

# --- Balls -------------------------------------------------------------------------

proc ballHeight(table: Table, ball: Ball): float32 =
  ## How high the ball's level is where the ball is now. On a ramp that is
  ## part of the way between the levels of its two mouths.
  result = levelY(ball.level)
  if ball.state != ballOnTrack:
    return
  let trackIndex = table.componentIndex(ball.holderId)
  if trackIndex < 0:
    return
  let
    track = table.components[trackIndex]
    mouthA = table.componentIndex(toInt(track.settings[setMouthA]))
    mouthB = table.componentIndex(toInt(track.settings[setMouthB]))
    length = toFloat32(table.trackLength(track))
  if mouthA >= 0 and mouthB >= 0 and length > 0:
    result = trackHeight(table.components[mouthA].level, table.components[mouthB].level,
      clamp(toFloat32(ball.trackDistance) / length, 0, 1))

proc isHidden(table: Table, ball: Ball): bool =
  ## A ball inside a scoop is under the table.
  if ball.state != ballHeld:
    return false
  let index = table.componentIndex(ball.holderId)
  index >= 0 and table.components[index].kind == ckScoop

# --- Light effects -----------------------------------------------------------------

proc addHalo(shapes: var ShapeRenderer, centre: Vec3, radius: float32, colour: Color,
             strength: float32) =
  ## A soft round glow that fades to nothing at its edge.
  const Sides = 18
  let
    middle = faded(colour, strength)
    rim = faded(colour, 0)
  for side in 0 ..< Sides:
    let
      a = TAU.float32 * side.float32 / Sides.float32
      b = TAU.float32 * (side + 1).float32 / Sides.float32
    shapes.addTriangle(
      [centre, centre + vec3(cos(a), 0, sin(a)) * radius, centre + vec3(cos(b), 0, sin(b)) * radius],
      [middle, rim, rim])

proc addRing(shapes: var ShapeRenderer, centre: Vec3, radius, width: float32, colour: ColorRGBX,
             dashes = 0, turn = 0'f32) =
  ## A flat ring. With `dashes`, only every other piece of it is drawn.
  let sides = if dashes > 0: dashes * 2 else: 32
  for side in 0 ..< sides:
    if dashes > 0 and side mod 2 == 1:
      continue
    let
      a = turn + TAU.float32 * side.float32 / sides.float32
      b = turn + TAU.float32 * (side + 1).float32 / sides.float32
      inner = radius - width / 2
      outer = radius + width / 2
    shapes.addQuad(
      centre + vec3(cos(a), 0, sin(a)) * inner, centre + vec3(cos(a), 0, sin(a)) * outer,
      centre + vec3(cos(b), 0, sin(b)) * outer, centre + vec3(cos(b), 0, sin(b)) * inner, colour)

proc addEffects(view: TableView, seconds: float32) =
  ## The rules' flasher and burst cues.
  view.flasherGlow = max(view.flasherGlow - seconds / FlasherSeconds, 0)
  if view.flasherGlow > 0:
    # The whole playfield lights up for a moment.
    let
      blink = if (view.time * FlashesPerSecond * 2) mod 1 < 0.5: 1'f32 else: 0.4'f32
      wash = faded(color(0.8, 0.85, 1.0, 1), 0.22 * view.flasherGlow * blink)
    view.glows.addQuad(vec3(0, 1, 0), vec3(PlayfieldWidth, 1, 0),
      vec3(PlayfieldWidth, 1, PlayfieldHeight), vec3(0, 1, PlayfieldHeight), wash)
  var index = 0
  while index < view.bursts.len:
    view.bursts[index].age += seconds
    let
      burst = view.bursts[index]
      share = burst.age / BurstSeconds
    if share >= 1:
      view.bursts.delete index
      continue
    let strength = 1 - share
    view.glows.addHalo(burst.at, 40 + 90 * share, BurstColour, 0.7 * strength)
    view.glows.addRing(burst.at, 20 + 110 * share, 5, faded(BurstColour, 0.9 * strength))
    for ray in 0 ..< 10:
      let
        angle = TAU.float32 * ray.float32 / 10 + 0.3
        along = vec3(cos(angle), 0, sin(angle))
        across = vec3(-along.z, 0, along.x) * 2.5
        near = burst.at + along * (25 + 80 * share)
        far = burst.at + along * (55 + 120 * share)
      view.glows.addQuad(near - across, near + across, far + across, far - across,
        faded(BurstColour, 0.8 * strength))
    inc index

# --- The frame ---------------------------------------------------------------------

type DrawItem = object
  mesh: ToonMesh
  material: ToonMaterial
  transform: Mat4
  castsShadow: bool

proc isSeeThrough(material: ToonMaterial): bool =
  material.color.a < 1 or material.ghost > 0

proc collectFixed(view: TableView, table: Table, items: var seq[DrawItem]) =
  items.add DrawItem(mesh: view.playfield, transform: mat4(),
    material: ToonMaterial(color: color(1, 1, 1, 1), texture: view.starfield))
  items.add DrawItem(mesh: view.cabinet, transform: mat4(), castsShadow: true,
    material: ToonMaterial(color: CabinetColour, chrome: 0.12))
  items.add DrawItem(mesh: view.rails, transform: mat4(), castsShadow: true,
    material: ToonMaterial(color: RailColour, chrome: 0.75))
  items.add DrawItem(mesh: view.wires, transform: mat4(), castsShadow: true,
    material: ToonMaterial(color: color(1, 1, 1, 1), chrome: 1))
  items.add DrawItem(mesh: view.apron, transform: mat4(), castsShadow: true,
    material: ToonMaterial(color: ApronColour, chrome: 0.2))
  items.add DrawItem(mesh: view.plungerMesh, castsShadow: true,
    transform: translate(vec3(0, 0, toFloat32(PlungerTravel * table.plunger.pull))),
    material: ToonMaterial(color: RailColour, chrome: 0.8))

  for side in FlipperSide:
    let
      collider = flipperCollider(side, table.flippers[side].angle)
      along = collider.b.toVec2 - collider.a.toVec2
      transform = placed(collider.a.onTable, radToDeg(arctan2(along.y, along.x)))
    items.add DrawItem(mesh: view.flipperBody, transform: transform, castsShadow: true,
      material: ToonMaterial(color: FlipperColour, chrome: 0.1))
    items.add DrawItem(mesh: view.flipperBand, transform: transform, castsShadow: true,
      material: ToonMaterial(color: FlipperBandColour))

  for ball in table.balls:
    if not table.isHidden(ball):
      items.add DrawItem(mesh: view.ballMesh, castsShadow: true,
        transform: translate(ball.pos.onTable(ballHeight(table, ball) + toFloat32(BallRadius))),
        material: ToonMaterial(color: color(1, 1, 1, 1), chrome: 1))

proc collectPieces(view: TableView, table: Table, items: var seq[DrawItem]) =
  for piece in table.components:
    let
      pieceView = view.pieceViews[view.pieceViewIndex(piece.id)]
      brightness = view.lampBrightness(piece, pieceView)
      phaseShare =
        if table.settings.beamInTicks > 0:
          1 - clamp(piece.phaseTicks.float32 / table.settings.beamInTicks.float32, 0, 1)
        else: 1'f32
      at = piece.pos.onTable(levelY(piece.level))
      footprintRadius = max(toFloat32(scaled(KindInfos[piece.kind].radius, piece.sizePercent)), 10)

    for part in pieceView.parts:
      if part.face >= 0 and part.face != piece.face:
        continue
      var item = DrawItem(mesh: part.mesh, material: part.material,
        transform: partTransform(piece, pieceView, part),
        castsShadow: part.castsShadow and piece.phase == phaseSolid)
      if part.glows:
        item.material.color = mix(part.material.color, part.glowColour, clamp(brightness, 0, 1) * 0.6)
        item.material.emissive = scaledColour(part.glowColour, brightness * 0.75)
      elif pieceView.hitGlow > 0:
        item.material.emissive = scaledColour(color(1, 1, 1, 1), pieceView.hitGlow * 0.25)
      case piece.phase
      of phaseSolid:
        discard
      of phaseBeamingIn:
        # A projection of the piece to come. It firms up as the time runs out.
        item.material = ToonMaterial(color: HologramColour, ghost: 0.55 + 0.45 * phaseShare)
      of phaseFadingOut:
        item.material.dissolve = phaseShare
        item.material.emissive = scaledColour(HologramColour, 0.5 * phaseShare)
      items.add item

    if piece.kind == ckTrack:
      continue
    case piece.phase
    of phaseBeamingIn:
      # A ring on the playfield closes in on the place where the piece will stand.
      let spread = 1 + (1 - phaseShare) * 0.8
      view.marks.addRing(at + vec3(0, 0.8, 0), footprintRadius * spread + 4, 2.2, HologramRing,
        dashes = 8, turn = view.time * 3)
      view.glows.addHalo(at + vec3(0, 0.6, 0), footprintRadius * 2.2, HologramColour,
        0.30 + 0.12 * sin(view.time * 30))
    of phaseFadingOut:
      view.glows.addHalo(at + vec3(0, 0.6, 0), footprintRadius * 2, HologramColour,
        0.3 * (1 - phaseShare))
    of phaseSolid:
      if brightness > 0.02:
        for part in pieceView.parts:
          if part.glows:
            view.glows.addHalo(at + vec3(0, 1.2, 0), footprintRadius * 2.4, part.glowColour,
              0.42 * min(brightness, 1))
            break
      if piece.kind == ckMagnet and piece.isOn:
        view.marks.addRing(at + vec3(0, 0.6, 0), toFloat32(piece.settings[setRadius]), 1.5,
          faded(color(0.9, 0.3, 0.9, 1), 0.35), dashes = 16, turn = -view.time)

proc draw*(view: TableView, table: Table, framebufferSize: IVec2, seconds: float32) =
  ## Draw one frame of the table as it is now. `seconds` is the time since
  ## the last frame, for the view's own small animations.
  view.time += seconds
  view.aimCamera(framebufferSize)
  view.syncPieces(table)
  view.animate(table, seconds)

  view.marks.clear()
  view.glows.clear()
  var items: seq[DrawItem]
  view.collectFixed(table, items)
  view.collectPieces(table, items)
  view.addEffects(seconds)

  sunDepthPass(framebufferSize):
    view.toon.beginDepth()
    for item in items:
      if item.castsShadow:
        view.toon.drawDepth(item.mesh, item.transform)

  glClearColor(Backdrop.r, Backdrop.g, Backdrop.b, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  # See-through parts must not make the canvas itself see-through: in a
  # browser the page would show through them.
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_FALSE)
  view.toon.time = view.time
  view.toon.beginDraw()
  for item in items:
    if not item.material.isSeeThrough:
      view.toon.draw(item.mesh, item.material, item.transform)
  for item in items:
    if item.material.isSeeThrough:
      view.toon.draw(item.mesh, item.material, item.transform)
  view.toon.endDraw()
  view.marks.draw(view.viewProjection)
  view.glows.draw(view.viewProjection)
  glDisable(GL_BLEND)
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE)
