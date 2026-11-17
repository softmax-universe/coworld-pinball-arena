## Building meshes in code. Everything on the table is made from the few
## shapes here: turned shapes (cylinders, domes, balls, rings), flat-topped
## prisms (boxes, wedges, plates), rounded walls, and tubes for wire.
##
## Coordinates are millimetres with `y` up. A flat `Vec2` outline is `(x, z)`
## on the ground plane. Each proc adds to a mesh, so one mesh can hold many
## shapes that share a material.

import
  std/math,
  vmath,
  ../../polyworld/toon

export toon.ToonMesh, toon.ToonMaterial

const
  RoundSides = 20        ## Straight pieces round a turned shape.
  WallEndSides = 6       ## Straight pieces round each end of a rounded wall.

proc addPoint(mesh: ToonMesh, point, normal: Vec3, uv = vec2(0, 0)): uint32 =
  result = mesh.points.len.uint32
  mesh.points.add point
  mesh.normals.add normal
  mesh.uvs.add uv

proc addQuad*(mesh: ToonMesh, a, b, c, d: Vec3, facing = vec3(0, 1, 0)) =
  ## A flat four-sided face. `facing` is roughly the way its lit side looks.
  var normal = normalize(cross(b - a, d - a))
  if dot(normal, facing) < 0:
    normal = -normal
  let first = mesh.points.len.uint32
  for point in [a, b, c, d]:
    discard mesh.addPoint(point, normal)
  mesh.indices.add [first, first + 1, first + 2, first, first + 2, first + 3]

proc addFlatPolygon*(mesh: ToonMesh, outline: openArray[Vec2], height: float32,
                     uvSize = vec2(1, 1)) =
  ## A level face inside a convex outline, looking up. Texture coordinates
  ## are the ground position divided by `uvSize`.
  var centre = vec2(0, 0)
  for point in outline:
    centre += point / outline.len.float32
  let
    up = vec3(0, 1, 0)
    hub = mesh.addPoint(vec3(centre.x, height, centre.y), up, centre / uvSize)
  for point in outline:
    discard mesh.addPoint(vec3(point.x, height, point.y), up, point / uvSize)
  for index in 0 ..< outline.len:
    let next = (index + 1) mod outline.len
    mesh.indices.add [hub, hub + 1 + index.uint32, hub + 1 + next.uint32]

proc addPrism*(mesh: ToonMesh, outline: openArray[Vec2], bottom, top: float32) =
  ## A convex outline pulled straight up from `bottom` to `top`, with a flat
  ## top and sharp edges. It has no underside.
  var centre = vec2(0, 0)
  for point in outline:
    centre += point / outline.len.float32
  for index in 0 ..< outline.len:
    let
      a = outline[index]
      b = outline[(index + 1) mod outline.len]
      outward = (a + b) / 2 - centre
    mesh.addQuad(
      vec3(a.x, bottom, a.y), vec3(b.x, bottom, b.y),
      vec3(b.x, top, b.y), vec3(a.x, top, a.y),
      vec3(outward.x, 0, outward.y))
  mesh.addFlatPolygon(outline, top)

proc addBox*(mesh: ToonMesh, low, high: Vec3) =
  ## A box with its sides along the axes.
  mesh.addPrism([vec2(low.x, low.z), vec2(high.x, low.z), vec2(high.x, high.z),
                 vec2(low.x, high.z)], low.y, high.y)

proc addLathe*(mesh: ToonMesh, base: Vec3, profile: openArray[Vec2],
               smooth = false, sides = RoundSides) =
  ## A shape turned round the upright line through `base`. The profile lists
  ## `(radius, height)` pairs up the outside of the shape. With `smooth` the
  ## corners of the profile are shaded round (a dome), otherwise sharp (a
  ## cylinder with a flat top).
  proc outward(a, b: Vec2): Vec2 =
    let along = b - a
    if along.length < 1e-6: vec2(0, 1) else: normalize(vec2(along.y, -along.x))

  for index in 0 ..< profile.high:
    let
      a = profile[index]
      b = profile[index + 1]
    var
      normalA = outward(a, b)
      normalB = normalA
    if smooth:
      normalA = outward(profile[max(index - 1, 0)], b)
      normalB = outward(a, profile[min(index + 2, profile.high)])
    let first = mesh.points.len.uint32
    for side in 0 .. sides:
      let
        angle = TAU.float32 * side.float32 / sides.float32
        c = cos(angle)
        s = sin(angle)
      discard mesh.addPoint(base + vec3(a.x * c, a.y, a.x * s),
        vec3(normalA.x * c, normalA.y, normalA.x * s))
      discard mesh.addPoint(base + vec3(b.x * c, b.y, b.x * s),
        vec3(normalB.x * c, normalB.y, normalB.x * s))
    for side in 0 ..< sides:
      let corner = first + side.uint32 * 2
      mesh.indices.add [corner, corner + 1, corner + 2, corner + 1, corner + 3, corner + 2]

proc addCylinder*(mesh: ToonMesh, base: Vec3, radius, height: float32) =
  ## Upright, standing on `base`, with a flat top.
  mesh.addLathe(base, [vec2(radius, 0), vec2(radius, height), vec2(0, height)])

proc addDisc*(mesh: ToonMesh, centre: Vec3, radius: float32, innerRadius = 0'f32) =
  ## A level disc or ring that looks up.
  mesh.addLathe(centre, [vec2(radius, 0), vec2(innerRadius, 0)])

proc addDome*(mesh: ToonMesh, base: Vec3, radius, height: float32) =
  ## The top half of a ball, squashed or stretched to `height`.
  const Steps = 6
  var profile: seq[Vec2]
  for step in 0 .. Steps:
    let angle = PI.float32 / 2 * step.float32 / Steps.float32
    profile.add vec2(cos(angle) * radius, sin(angle) * height)
  mesh.addLathe(base, profile, smooth = true)

proc addBall*(mesh: ToonMesh, centre: Vec3, radius: float32) =
  const Steps = 12
  var profile: seq[Vec2]
  for step in 0 .. Steps:
    let angle = PI.float32 * (step.float32 / Steps.float32 - 0.5)
    profile.add vec2(cos(angle) * radius, sin(angle) * radius)
  mesh.addLathe(centre, profile, smooth = true, sides = 24)

proc addHoop*(mesh: ToonMesh, centre: Vec3, radius, thickness: float32) =
  ## A level ring with a round section, like a rubber ring on a post.
  const Steps = 8
  var profile: seq[Vec2]
  for step in 0 .. Steps:
    let angle = TAU.float32 * step.float32 / Steps.float32 - PI.float32
    profile.add vec2(radius + cos(angle) * thickness, sin(angle) * thickness)
  mesh.addLathe(centre, profile, smooth = true)

proc addWall*(mesh: ToonMesh, a, b: Vec2, radius, bottom, top: float32) =
  ## An upright wall from `a` to `b` with rounded ends: the shape of a
  ## collision capsule pulled up. The sides are shaded round at the ends.
  var along = b - a
  along = if along.length < 1e-4: vec2(1, 0) else: normalize(along)
  var outline, normals: seq[Vec2]
  for (centre, forward) in [(b, along), (a, -along)]:
    # Half a circle round this end, from one side of the wall to the other.
    for step in 0 .. WallEndSides:
      let
        angle = PI.float32 * (step.float32 / WallEndSides.float32 - 0.5)
        left = vec2(-forward.y, forward.x)
        normal = forward * cos(angle) + left * sin(angle)
      outline.add centre + normal * radius
      normals.add normal
  let first = mesh.points.len.uint32
  for index in 0 ..< outline.len:
    let
      point = outline[index]
      normal = vec3(normals[index].x, 0, normals[index].y)
    discard mesh.addPoint(vec3(point.x, bottom, point.y), normal)
    discard mesh.addPoint(vec3(point.x, top, point.y), normal)
  for index in 0 ..< outline.len:
    let
      corner = first + index.uint32 * 2
      next = first + ((index + 1) mod outline.len).uint32 * 2
    mesh.indices.add [corner, corner + 1, next, corner + 1, next + 1, next]
  mesh.addFlatPolygon(outline, top)

proc addWallPath*(mesh: ToonMesh, path: openArray[Vec2], radius, bottom, top: float32) =
  ## A wall along a line of points.
  for index in 1 .. path.high:
    mesh.addWall(path[index - 1], path[index], radius, bottom, top)

proc addTube*(mesh: ToonMesh, path: openArray[Vec3], radius: float32, sides = 8) =
  ## A round wire along a line of points in space. The ends are open.
  if path.len < 2:
    return
  let first = mesh.points.len.uint32
  for index, point in path:
    var along = path[min(index + 1, path.high)] - path[max(index - 1, 0)]
    along = if along.length < 1e-4: vec3(0, 1, 0) else: normalize(along)
    # Two directions across the wire. An upright wire has no "level" side
    # direction of its own, so it borrows the x axis.
    var side = cross(along, vec3(0, 1, 0))
    side = if side.length < 1e-3: vec3(1, 0, 0) else: normalize(side)
    let lift = normalize(cross(side, along))
    for step in 0 .. sides:
      let
        angle = TAU.float32 * step.float32 / sides.float32
        normal = side * cos(angle) + lift * sin(angle)
      discard mesh.addPoint(point + normal * radius, normal)
  let ring = (sides + 1).uint32
  for index in 0 ..< path.high:
    for step in 0 ..< sides:
      let corner = first + index.uint32 * ring + step.uint32
      mesh.indices.add [corner, corner + ring, corner + 1,
                        corner + 1, corner + ring, corner + ring + 1]

proc addPost*(mesh: ToonMesh, foot: Vec3, height, radius: float32) =
  ## A thin upright rod.
  mesh.addTube([foot, foot + vec3(0, height, 0)], radius, sides = 6)
