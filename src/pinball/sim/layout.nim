## The fixed parts of the table, which the Arena player cannot change: the
## outer walls and top arch, the shooter lane with its plunger on the right,
## the inlanes and outlanes beside the flippers, the apron and the drain.
## Also the keep-out zones, where nothing can be built.
##
## The table from top to bottom (millimetres, `y` grows toward the player):
##
## - An arch spans the top. It leaves the right wall smoothly, so a launched
##   ball rides it over the top, and meets the left wall at a corner, which
##   throws the ball out into the playfield instead of down the left side.
## - The shooter lane runs down the right edge behind a divider. A sloped
##   one-way gate closes the top of the lane, so a ball that comes back rolls
##   off it into the playfield.
## - Near the bottom, a guide rail on each side leads onto its flipper. The
##   gap between a guide and the side wall is the outlane.
## - Everything below `DrainY` is under the apron: a ball there has drained.
##
## All of these are starting values for playtest.

import types, geometry

const
  SlopeGravity* = 800'fx
    ## mm/s^2 for a solid ball rolling down a 6.5 degree slope:
    ## (5/7) * g * sin(6.5 degrees), rounded.

  FlipperStroke* = 50'fx
    ## How far a flipper turns from rest to fully raised, in degrees. A starting
    ## value: tune it together with the flipper geometry.

  WallRadius = 4'fx             ## Half the thickness of the outer walls and arch.
  ArchCentre = FixedVec2(x: 220'fx, y: 300'fx)
  ArchRadius = 300'fx           ## To the centre line of the arch wall.
  ArchLeftAngle = 223'fx        ## Degrees. Where the arch meets the left wall.
  ArchSegments = 28             ## Straight pieces from there round to the right wall.

  LaneDividerX = 478'fx
  LaneDividerTopY = 330'fx
  LaneDividerRadius = 3'fx
  LaneCentreX = 498.5'fx
  GateWallEnd = FixedVec2(x: 518'fx, y: 288'fx)
    ## The gate runs from here down to the top of the divider.
  GateRadius = 2'fx

  PlungerRestY = 990'fx         ## The centre line of the plunger tip at rest.
  PlungerTravel* = 40'fx        ## How far a full pull draws the tip back.
  PlungerHalfWidth = 13.5'fx
  PlungerRadius = 4'fx

  FlipperCentreX = 240'fx       ## The flippers and guides mirror about this line.
  FlipperPivotOffset = 83'fx    ## From the centre line out to each pivot.
  FlipperPivotY = 950'fx
  FlipperLength* = 70'fx        ## Pivot to the centre of the round tip.
  FlipperRadius* = 6'fx
  FlipperRestAngle = 30'fx      ## Degrees below level at rest.

  GuideRadius = 3'fx
  GuideSlopeLength = 132'fx     ## The part that continues the line of the resting flipper.
  GuideUprightLength = 80'fx    ## The part above it, beside the outlane.

  DrainY* = 1045'fx             ## A ball whose centre is below this has drained.

  # Keep-out zones.
  ApronTopY = 1005'fx           ## Nothing is built below the flippers.
  FlipperZone = Collider(
    a: FixedVec2(x: 157'fx, y: 956'fx), b: FixedVec2(x: 323'fx, y: 956'fx),
    radius: 52'fx)              ## The sweep of both flippers plus about 12 mm.
  LaneZone = Collider(
    a: FixedVec2(x: 498.5'fx, y: 310'fx), b: FixedVec2(x: 498.5'fx, y: 1080'fx),
    radius: 30'fx)              ## The shooter lane with its gate and divider.

proc mirrored(point: FixedVec2): FixedVec2 =
  fixedVec2(FlipperCentreX * 2'i32 - point.x, point.y)

proc flipperPivot*(side: FlipperSide): FixedVec2 =
  let left = fixedVec2(FlipperCentreX - FlipperPivotOffset, FlipperPivotY)
  if side == flipperLeft: left else: mirrored(left)

proc flipperCollider*(side: FlipperSide, angle: Fixed): Collider =
  ## The capsule of one flipper when it is `angle` degrees above rest. End
  ## `a` is the pivot.
  let
    pivot = flipperPivot(side)
    heading =
      if side == flipperLeft: FlipperRestAngle - angle
      else: 180'fx - FlipperRestAngle + angle
  Collider(a: pivot, b: pivot + direction(radians(heading)) * FlipperLength,
    radius: FlipperRadius, surface: surfaceRubber)

proc plungerCollider*(pull: Fixed): Collider =
  ## The tip of the plunger, a bar across the shooter lane. `pull` is 0 .. 1.
  let y = PlungerRestY + PlungerTravel * pull
  Collider(a: fixedVec2(LaneCentreX - PlungerHalfWidth, y),
    b: fixedVec2(LaneCentreX + PlungerHalfWidth, y),
    radius: PlungerRadius, surface: surfaceDead)

proc shooterLaneStart*(): FixedVec2 =
  ## Where a served ball rests on the plunger.
  fixedVec2(LaneCentreX, PlungerRestY - PlungerRadius - BallRadius)

proc archPoint(index: int): FixedVec2 =
  ## Point `index` of the arch, from the left wall (0) over the top to the
  ## right wall (`ArchSegments`).
  let degrees = ArchLeftAngle + (360'fx - ArchLeftAngle) * int32(index) / int32(ArchSegments)
  ArchCentre + direction(radians(degrees)) * ArchRadius

proc playfieldOutline*(): seq[FixedVec2] =
  ## The centre line of the outer wall as a closed loop, starting at the
  ## bottom left corner and going up and over the arch.
  result.add fixedVec2(0'fx, fixed(PlayfieldHeight))
  result.add fixedVec2(0'fx, archPoint(0).y)
  for index in 0 .. ArchSegments:
    result.add archPoint(index)
  result.add fixedVec2(fixed(PlayfieldWidth), fixed(PlayfieldHeight))

proc buildFixedColliders(): seq[Collider] =
  proc wall(a, b: FixedVec2, radius = WallRadius): Collider =
    Collider(a: a, b: b, radius: radius, surface: surfaceMetal)

  # Outer walls and arch. The outline is a closed loop, so the last piece is
  # the bottom wall.
  let outline = playfieldOutline()
  for index in 0 ..< outline.len:
    result.add wall(outline[index], outline[(index + 1) mod outline.len])

  # Shooter lane: the divider, and the one-way gate across its top. The gate
  # slopes down toward the playfield, and lets a ball through from below.
  let dividerTop = fixedVec2(LaneDividerX, LaneDividerTopY)
  result.add wall(dividerTop, fixedVec2(LaneDividerX, fixed(PlayfieldHeight)),
    LaneDividerRadius)
  var gate = wall(GateWallEnd, dividerTop, GateRadius)
  gate.passDirection = normalize(perpendicular(dividerTop - GateWallEnd))  # Up and to the left.
  result.add gate

  # Lane guides. The sloped part lies along the top face of the resting
  # flipper, so a ball rolls from one onto the other without a step, and a
  # raised flipper forms a crook with it where a ball can be cradled.
  let
    rest = flipperCollider(flipperLeft, 0'fx)
    along = normalize(rest.b - rest.a)
    upward = -perpendicular(along)
    foot = rest.a + upward * (FlipperRadius - GuideRadius)
    corner = foot - along * GuideSlopeLength
    top = corner - fixedVec2(0'fx, GuideUprightLength)
  result.add wall(foot, corner, GuideRadius)
  result.add wall(corner, top, GuideRadius)
  result.add wall(mirrored(foot), mirrored(corner), GuideRadius)
  result.add wall(mirrored(corner), mirrored(top), GuideRadius)

let fixedParts = buildFixedColliders()

proc fixedColliders*(): seq[Collider] =
  ## The collision shapes of every fixed part except the flippers and the
  ## plunger. They never change, so they are built once.
  fixedParts

proc isDrained*(pos: FixedVec2): bool =
  ## True when a ball at `pos` has left play through the drain. Both the gap
  ## between the flippers and the outlanes lead there. The bottom of the
  ## shooter lane is not part of it.
  pos.y > DrainY and pos.x < LaneDividerX

proc inKeepOut*(shape: Collider): bool =
  ## True when the shape reaches into a keep-out zone (the area the flippers
  ## sweep plus a margin, the drain mouth, the shooter lane) or lies outside
  ## the playfield walls.
  for point in [shape.a, shape.b]:
    if point.x - shape.radius < WallRadius or
        point.x + shape.radius > fixed(PlayfieldWidth) - WallRadius or
        point.y - shape.radius < WallRadius or
        point.y + shape.radius > ApronTopY:
      return true
    if point.y < ArchCentre.y and
        distance(point, ArchCentre) + shape.radius > ArchRadius - WallRadius:
      return true
  capsulesOverlap(shape, FlipperZone) or capsulesOverlap(shape, LaneZone)
