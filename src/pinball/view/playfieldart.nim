## The picture on the playfield: a deep navy and purple starfield with soft
## nebula clouds and two planets. It is painted in code when the game starts,
## so the game ships no artwork, and it is the same picture every time.
##
## The table changes while it is played, so the picture says nothing about
## where things are. The pieces themselves must tell the player what they are.

import
  std/[math, random],
  pixie, vmath

const
  ArtWidth = 512
  ArtHeight = 1024
  StarCount = 700
  GlintStarCount = 14      ## Bright stars with a four-point glint.
  ColourLevels = 40
    ## Each colour channel is cut down to this many steps with a dither
    ## pattern, for the banded look of a 256-colour picture.

  SpaceTop = vec3(0.020, 0.030, 0.130)
  SpaceBottom = vec3(0.105, 0.035, 0.190)
  NebulaMagenta = vec3(0.55, 0.12, 0.50)
  NebulaBlue = vec3(0.10, 0.28, 0.70)
  NebulaTeal = vec3(0.05, 0.45, 0.48)

type Canvas = object
  pixels: seq[Vec3]

proc `[]`(canvas: var Canvas, x, y: int): var Vec3 =
  canvas.pixels[y * ArtWidth + x]

proc latticeValue(x, y, seed: int): float32 =
  ## A fixed pseudo-random number in 0 .. 1 for one grid corner.
  var h = uint32(x) * 374761393'u32 + uint32(y) * 668265263'u32 + uint32(seed) * 2246822519'u32
  h = (h xor (h shr 13)) * 1274126177'u32
  float32((h xor (h shr 16)) and 0xffff) / 65535'f32

proc cloud(x, y: float32, seed: int): float32 =
  ## Smooth noise in 0 .. 1, built from three sizes of blobs.
  var
    total = 0'f32
    weight = 0.5'f32
    scale = 1'f32
  for octave in 0 ..< 3:
    let
      px = x * scale
      py = y * scale
      cellX = int(floor(px))
      cellY = int(floor(py))
      fx = px - floor(px)
      fy = py - floor(py)
      sx = fx * fx * (3 - 2 * fx)
      sy = fy * fy * (3 - 2 * fy)
      top = mix(latticeValue(cellX, cellY, seed + octave),
                latticeValue(cellX + 1, cellY, seed + octave), sx)
      bottom = mix(latticeValue(cellX, cellY + 1, seed + octave),
                   latticeValue(cellX + 1, cellY + 1, seed + octave), sx)
    total += mix(top, bottom, sy) * weight
    weight *= 0.5
    scale *= 2
  total / 0.875

proc paintSpace(canvas: var Canvas) =
  for y in 0 ..< ArtHeight:
    for x in 0 ..< ArtWidth:
      let
        u = x.float32 / ArtWidth.float32
        v = y.float32 / ArtHeight.float32
      var colour = mix(SpaceTop, SpaceBottom, clamp(v * 0.8 + u * 0.2, 0, 1))
      # The clouds are stretched down the table, so use the same scale both ways.
      let
        magenta = smoothstep(0.52'f32, 0.85'f32, cloud(u * 3.0, v * 6.0, 11))
        blue = smoothstep(0.50'f32, 0.85'f32, cloud(u * 2.5 + 7, v * 5.0 + 3, 23))
        teal = smoothstep(0.60'f32, 0.90'f32, cloud(u * 4.0 + 2, v * 8.0 + 9, 37))
      colour += NebulaMagenta * magenta * 0.55
      colour += NebulaBlue * blue * 0.50
      colour += NebulaTeal * teal * 0.35
      canvas[x, y] = colour

proc addGlow(canvas: var Canvas, centre: Vec2, radius: float32, colour: Vec3) =
  ## A soft round spot of light, brightest in the middle.
  let reach = int(ceil(radius))
  for y in max(int(centre.y) - reach, 0) .. min(int(centre.y) + reach, ArtHeight - 1):
    for x in max(int(centre.x) - reach, 0) .. min(int(centre.x) + reach, ArtWidth - 1):
      let distance = length(vec2(x.float32, y.float32) - centre) / radius
      if distance < 1:
        canvas[x, y] += colour * (1 - distance) * (1 - distance)

proc paintStars(canvas: var Canvas, rng: var Rand) =
  for star in 0 ..< StarCount:
    let
      centre = vec2(rng.rand(ArtWidth.float32), rng.rand(ArtHeight.float32))
      brightness = 0.15'f32 + 0.85'f32 * pow(rng.rand(1.0).float32, 3)
      warmth = rng.rand(1.0).float32
      colour = mix(vec3(0.75, 0.85, 1.0), vec3(1.0, 0.92, 0.75), warmth) * brightness
    canvas.addGlow(centre, 1.0 + brightness * 1.6, colour)
  for star in 0 ..< GlintStarCount:
    let centre = vec2(rng.rand(ArtWidth.float32), rng.rand(ArtHeight.float32))
    canvas.addGlow(centre, 5, vec3(0.9, 0.95, 1.0))
    for step in -9 .. 9:
      let fade = (1 - abs(step).float32 / 10) * 0.5
      canvas.addGlow(centre + vec2(step.float32, 0), 1.2, vec3(0.8, 0.9, 1.0) * fade)
      canvas.addGlow(centre + vec2(0, step.float32), 1.2, vec3(0.8, 0.9, 1.0) * fade)

proc paintPlanet(canvas: var Canvas, centre: Vec2, radius: float32,
                 light, dark: Vec3, bands: float32, ringColour = vec3(0)) =
  ## A ball lit from the upper left, with cloud bands, and a tilted ring when
  ## `ringColour` is not black.
  let
    toLight = normalize(vec3(-0.55, -0.6, 0.6))
    reach = int(radius * 2.4)
  for y in max(int(centre.y) - reach, 0) .. min(int(centre.y) + reach, ArtHeight - 1):
    for x in max(int(centre.x) - reach, 0) .. min(int(centre.x) + reach, ArtWidth - 1):
      let offset = (vec2(x.float32, y.float32) - centre) / radius
      if offset.length < 1:
        let
          normal = vec3(offset.x, offset.y, sqrt(1 - offset.lengthSq))
          lit = max(dot(normal, toLight), 0) * 0.9 + 0.06
          band = 0.5 + 0.5 * sin(offset.y * bands + offset.x * 1.5)
          edge = smoothstep(1.0'f32, 0.92'f32, offset.length)
        canvas[x, y] = mix(canvas[x, y], mix(dark, light, band) * lit, edge)
      elif ringColour != vec3(0):
        # The ring is a circle seen from the side: squash it and tilt it.
        let
          tilted = vec2(offset.x * 0.94 + offset.y * 0.34, (offset.y * 0.94 - offset.x * 0.34) * 3.2)
          distance = tilted.length
        if distance > 1.35 and distance < 2.1:
          let gap = 0.6 + 0.4 * sin(distance * 26)
          canvas[x, y] = mix(canvas[x, y], ringColour, 0.55 * gap)

proc ditherAndPack(canvas: Canvas): Image =
  ## Cut each channel to a few levels. The 4 x 4 pattern decides which way
  ## each pixel rounds, so smooth areas become fine cross-hatching, not bands.
  const Pattern = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
  result = newImage(ArtWidth, ArtHeight)
  for y in 0 ..< ArtHeight:
    for x in 0 ..< ArtWidth:
      let
        nudge = (Pattern[(y mod 4) * 4 + x mod 4].float32 + 0.5) / 16
        colour = canvas.pixels[y * ArtWidth + x]
      var channels: array[3, uint8]
      for index in 0 .. 2:
        let level = floor(clamp(colour[index], 0, 1) * (ColourLevels - 1).float32 + nudge)
        channels[index] = uint8(clamp(level / (ColourLevels - 1).float32, 0, 1) * 255)
      result.data[y * ArtWidth + x] = rgbx(channels[0], channels[1], channels[2], 255)

proc starfieldImage*(): Image =
  ## The playfield picture. Its left edge is the left wall of the table and
  ## its top edge is the far end.
  var
    canvas = Canvas(pixels: newSeq[Vec3](ArtWidth * ArtHeight))
    rng = initRand(1995)
  canvas.paintSpace()
  canvas.paintStars(rng)
  canvas.paintPlanet(vec2(150, 300), 44, vec3(0.95, 0.66, 0.36), vec3(0.62, 0.30, 0.20), 9,
    ringColour = vec3(0.80, 0.70, 0.55))
  canvas.paintPlanet(vec2(350, 640), 24, vec3(0.45, 0.70, 0.95), vec3(0.15, 0.30, 0.65), 5)
  canvas.ditherAndPack()
