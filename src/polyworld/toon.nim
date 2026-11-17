## Lit meshes with a shading ramp.
##
## 1. Lambert from exactly one light: `max(dot(N, L), 0)`, scaled by the
##    light's shadow map.
## 2. That intensity is a texture coordinate into a 256 wide ramp. The ramp is
##    data, so it can be a hard cel band or a long soft gradient.
## 3. The top of the ramp maps to a highlight colour and the bottom to a
##    shadow colour, and the result multiplies the colour of the material.
##
## On top of that a material can glow (`emissive`), be see-through (an alpha
## below 1), and be `chrome`: a mirror finish faked with a painted sky and a
## bright window in it, with no environment map. Two effects serve the hologram
## pieces of the pinball table: `ghost` draws a mesh as a shimmering
## projection, and `dissolve` eats holes into it.
##
## From Polyworld. Changed for Pinball Arena: this draws plain `ToonMesh`
## values built in code, not glTF node trees, so skinning, poses, packed
## character parts, the palette table and the background gradient are gone.
## Lighting is always per pixel. Chrome, ghost and dissolve are new.

import
  std/math,
  opengl, vmath, chroma, pixie, shady,
  shadows

## Shaders

var
  toonModel: Uniform[Mat4]
  toonNormalMatrix: Uniform[Mat3]
  toonView: Uniform[Mat4]
  toonProj: Uniform[Mat4]
  toonLightDirection: Uniform[Vec3]   # direction the light travels
  toonCameraPosition: Uniform[Vec3]
  toonBaseColorTexture: Uniform[Sampler2d]
  toonBaseColorFactor: Uniform[Vec4]
  toonEmissiveFactor: Uniform[Vec3]
  toonRamp: Uniform[Sampler2d]
  toonHighlightColor: Uniform[Vec4]
  toonShadowColor: Uniform[Vec4]
  toonRimColor: Uniform[Vec4]
  toonUnlit: Uniform[float32]
  toonChrome: Uniform[float32]
  toonGhost: Uniform[float32]
  toonDissolve: Uniform[float32]
  toonTime: Uniform[float32]
  toonShadowMvp: Uniform[Mat4]
  toonShadowMap: Uniform[Sampler2dShadow]
  toonShadowStrength: Uniform[float32]
  toonShadowBias: Uniform[float32]
  toonShadowTexel: Uniform[float32]
  toonShadowSoftness: Uniform[float32]

proc sunShadowFactor(worldPos: Vec3): float32 =
  ## How lit by the light a fragment is, 1 clear .. (1 - strength) shadowed:
  ## a 3x3 grid of hardware-PCF taps, each itself bilinearly filtered by the
  ## comparison sampler. Positions outside the map count as lit.
  var lit = 1.0'f32
  let
    shadowCoord: Vec4 = toonShadowMvp * vec4(worldPos, 1.0'f)
    su = shadowCoord.x * 0.5'f + 0.5'f
    sv = shadowCoord.y * 0.5'f + 0.5'f
    sd = shadowCoord.z * 0.5'f + 0.5'f - toonShadowBias
  if su > 0.0'f and su < 1.0'f and sv > 0.0'f and sv < 1.0'f and sd < 1.0'f:
    let spread = toonShadowTexel * toonShadowSoftness
    lit = 0.0'f32
    lit = lit + texture(toonShadowMap, vec3(su - spread, sv - spread, sd))
    lit = lit + texture(toonShadowMap, vec3(su, sv - spread, sd))
    lit = lit + texture(toonShadowMap, vec3(su + spread, sv - spread, sd))
    lit = lit + texture(toonShadowMap, vec3(su - spread, sv, sd))
    lit = lit + texture(toonShadowMap, vec3(su, sv, sd))
    lit = lit + texture(toonShadowMap, vec3(su + spread, sv, sd))
    lit = lit + texture(toonShadowMap, vec3(su - spread, sv + spread, sd))
    lit = lit + texture(toonShadowMap, vec3(su, sv + spread, sd))
    lit = lit + texture(toonShadowMap, vec3(su + spread, sv + spread, sd))
    lit = lit / 9.0'f
  result = 1.0'f - (1.0'f - lit) * toonShadowStrength

proc toonVert(
  vertexPosition: Vec3,
  vertexNormal: Vec3,
  vertexUV: Vec2,
  gl_Position: var Vec4,
  worldPos: var Vec3,
  normal: var Vec3,
  uv: var Vec2
) =
  worldPos = (toonModel * vec4(vertexPosition, 1.0'f)).xyz
  uv = vertexUV
  normal = normalize(toonNormalMatrix * vertexNormal)
  gl_Position = toonProj * toonView * vec4(worldPos, 1.0'f)

proc toonFrag(
  worldPos: Vec3,
  normal: Vec3,
  uv: Vec2,
  fragColor: var Vec4
) =
  let
    albedo: Vec4 = texture(toonBaseColorTexture, uv) * toonBaseColorFactor
    n: Vec3 = normalize(normal)
    eye: Vec3 = normalize(toonCameraPosition - worldPos)
    toLight: Vec3 = normalize(-toonLightDirection)
    facing = 1.0'f - abs(dot(eye, n))

  if toonDissolve > 0.0'f:
    # Holes open in small cubes of space, more of them as the value rises.
    let
      cell: Vec3 = floor(worldPos * 0.35'f)
      noise = fract(sin(dot(cell, vec3(12.9898'f, 78.233'f, 37.719'f))) * 43758.5453'f)
    if noise < toonDissolve:
      discardFragment()

  if toonGhost > 0.0'f:
    # A projection: bright where the surface turns away from the eye, so the
    # outline of the shape shows, with scan lines that climb and a flicker.
    let
      lines = 0.5'f + 0.5'f * sin(worldPos.y * 1.6'f - toonTime * 14.0'f)
      flicker = 0.82'f + 0.18'f * sin(toonTime * 41.0'f)
      glow = (0.30'f + 0.90'f * facing * facing + 0.35'f * lines) * flicker
    fragColor = vec4(
      toonBaseColorFactor.rgb * (0.7'f + glow),
      clamp(toonBaseColorFactor.a * glow, 0.0'f, 1.0'f) * toonGhost)
    return

  if toonUnlit > 0.5'f:
    fragColor = vec4(albedo.rgb + toonEmissiveFactor, albedo.a)
    return

  # Steps 1 and 2: the intensity, scaled by the shadow test, is a texture
  # coordinate into the ramp.
  let
    sunFactor = sunShadowFactor(worldPos)
    lambert = max(dot(n, toLight), 0.0'f)
    band = texture(toonRamp, vec2(lambert * sunFactor, 0.5'f)).r
  # Step 3: two hand-picked colours, then the colour of the material on top.
  var lit: Vec3 = mix(toonShadowColor.rgb, toonHighlightColor.rgb, band)
  let rim = facing * facing * facing * facing
  lit = mix(lit, toonRimColor.rgb, rim * toonRimColor.a)
  var shaded: Vec3 = lit * albedo.rgb

  if toonChrome > 0.0'f:
    # A mirror with nothing real to reflect: a dark floor, a pale sky and a
    # bright window in the sky where the light is, picked by where the
    # reflected ray points.
    let
      mirrored: Vec3 = reflect(-eye, n)
      sky = smoothstep(-0.25'f, 0.7'f, mirrored.y)
      toward = max(dot(mirrored, toLight), 0.0'f)
      window = pow(toward, 6.0'f) * 0.55'f + pow(toward, 70.0'f) * 1.2'f
      shade = 0.5'f + 0.5'f * sunFactor
    var metal: Vec3 = mix(vec3(0.05'f, 0.04'f, 0.12'f), vec3(0.50'f, 0.56'f, 0.72'f), sky)
    metal = (metal + vec3(window)) * albedo.rgb * shade
    shaded = mix(shaded, metal, toonChrome)

  fragColor = vec4(shaded + toonEmissiveFactor, albedo.a)

## Depth pass: the same vertices projected by the light's matrix, for the
## shadow map (polyworld/shadows).

var toonDepthLightMvp: Uniform[Mat4]

proc toonDepthVert(vertexPosition: Vec3, gl_Position: var Vec4) =
  gl_Position = toonDepthLightMvp * toonModel * vec4(vertexPosition, 1.0'f)

proc toonDepthFrag(fragColor: var Vec4) =
  fragColor = vec4(1.0'f, 1.0'f, 1.0'f, 1.0'f)

const
  ToonShaderTarget =
    when defined(emscripten):
      glsl3WebGL
    else:
      glsl4Desktop
  ToonVertSrc = toShader(toonVert, ToonShaderTarget, shaderVertex)
  ToonFragSrc = toShader(toonFrag, ToonShaderTarget, shaderFragment)
  ToonDepthVertSrc = toShader(toonDepthVert, ToonShaderTarget, shaderVertex)
  ToonDepthFragSrc = toShader(toonDepthFrag, ToonShaderTarget, shaderFragment)

  # Vertex attribute slots, the same in both programs.
  PositionSlot = 0.GLuint
  NormalSlot = 1.GLuint
  UvSlot = 2.GLuint

## Ramp

const RampWidth = 256

proc rampImage*(shadowEnd = 0.47'f32, highlightStart = 0.53'f32): Image =
  ## The shading ramp: black, a linear rise, white. Both edges are fractions
  ## of the full intensity range. Edges close together give a hard cel band,
  ## and edges far apart give soft shading.
  result = newImage(RampWidth, 1)
  for x in 0 ..< RampWidth:
    let
      t = x.float32 / (RampWidth - 1).float32
      v = clamp((t - shadowEnd) / max(highlightStart - shadowEnd, 0.001'f32), 0, 1)
      byte = (v * 255).round.uint8
    result.data[x] = rgbx(byte, byte, byte, 255)

## Meshes and materials

type
  ToonMesh* = ref object
    ## Triangles with one normal and one texture coordinate per point. Fill
    ## the four lists, then draw. The mesh is sent to the GPU on its first
    ## draw. Call `release` before dropping a mesh that was drawn.
    points*: seq[Vec3]
    normals*: seq[Vec3]
    uvs*: seq[Vec2]
    indices*: seq[uint32]
    vertexArray: GLuint
    buffers: array[4, GLuint]

  ToonMaterial* = object
    color*: Color          ## An alpha below 1 makes the material see-through.
    emissive*: Color       ## Added after lighting: glows in the dark.
    texture*: GLuint       ## Multiplies `color`. 0 for none.
    chrome*: float32       ## 0 painted .. 1 mirror.
    unlit*: bool           ## Ignore the light and the shadows.
    ghost*: float32        ## Above 0, draw as a projection in `color`. 1 is full strength.
    dissolve*: float32     ## 0 whole .. 1 nothing left.

  ToonUniforms = object
    model, normalMatrix, view, proj: GLint
    lightDirection, cameraPosition: GLint
    baseColorTexture, baseColorFactor, emissiveFactor, ramp: GLint
    highlightColor, shadowColor, rimColor: GLint
    unlit, chrome, ghost, dissolve, time: GLint
    shadowMvp, shadowMap, shadowStrength: GLint
    shadowBias, shadowTexel, shadowSoftness: GLint

  ToonContext* = ref object
    shader: GLuint
    uniforms: ToonUniforms
    depthShader: GLuint
    depthModel, depthLightMvp: GLint
    rampTexture: GLuint
    whiteTexture: GLuint
    view*, proj*: Mat4
    cameraPosition*: Vec3
    lightDirection*: Vec3        ## Direction the light travels.
    highlightColor*: Color
    shadowColor*: Color
    rimColor*: Color             ## Alpha is the rim strength.
    time*: float32               ## Seconds. Drives the ghost shimmer.

proc compileStage(kind: GLenum, source, label: string): GLuint =
  result = glCreateShader(kind)
  var sourceArray = allocCStringArray([source])
  defer: deallocCStringArray(sourceArray)
  glShaderSource(result, 1.GLsizei, sourceArray, nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetShaderInfoLog(result, length, nil, log.cstring)
    quit(label & " shader failed:\n" & log & "\nsource:\n" & source)

proc compileProgram(vertexSource, fragmentSource, label: string): GLuint =
  let
    vertexShader = compileStage(GL_VERTEX_SHADER, vertexSource, label & " vertex")
    fragmentShader = compileStage(GL_FRAGMENT_SHADER, fragmentSource, label & " fragment")
  result = glCreateProgram()
  glBindAttribLocation(result, PositionSlot, "vertexPosition")
  glBindAttribLocation(result, NormalSlot, "vertexNormal")
  glBindAttribLocation(result, UvSlot, "vertexUV")
  glAttachShader(result, vertexShader)
  glAttachShader(result, fragmentShader)
  glLinkProgram(result)
  glDeleteShader(vertexShader)
  glDeleteShader(fragmentShader)
  var ok: GLint
  glGetProgramiv(result, GL_LINK_STATUS, ok.addr)
  if ok == 0:
    var length: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, length.addr)
    var log = newString(length)
    glGetProgramInfoLog(result, length, nil, log.cstring)
    quit(label & " program failed:\n" & log)

proc uploadTexture*(image: Image, repeat = false): GLuint =
  ## A GL texture with mipmaps from a pixie image.
  glGenTextures(1, result.addr)
  glBindTexture(GL_TEXTURE_2D, result)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA.GLint, image.width.GLint, image.height.GLint,
    0, GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr)
  glGenerateMipmap(GL_TEXTURE_2D)
  let wrap = if repeat: GL_REPEAT.GLint else: GL_CLAMP_TO_EDGE.GLint
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrap)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrap)
  glBindTexture(GL_TEXTURE_2D, 0)

proc setRamp*(ctx: ToonContext, image: Image) =
  ## Replaces the ramp with any width x 1 image (the red channel is read).
  if ctx.rampTexture != 0:
    glDeleteTextures(1, ctx.rampTexture.addr)
  glGenTextures(1, ctx.rampTexture.addr)
  glBindTexture(GL_TEXTURE_2D, ctx.rampTexture)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA.GLint, image.width.GLint, image.height.GLint,
    0, GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)

proc newToonContext*(): ToonContext =
  result = ToonContext(
    lightDirection: normalize(vec3(0.7, -0.4, -0.6)),
    highlightColor: color(1, 1, 1, 1),
    shadowColor: color(0.64, 0.60, 0.57, 1),
    rimColor: color(1, 1, 1, 0),
  )
  result.shader = compileProgram(ToonVertSrc, ToonFragSrc, "toon")
  template loc(field: untyped, name: string) =
    result.uniforms.field = glGetUniformLocation(result.shader, name)
  loc(model, "toonModel")
  loc(normalMatrix, "toonNormalMatrix")
  loc(view, "toonView")
  loc(proj, "toonProj")
  loc(lightDirection, "toonLightDirection")
  loc(cameraPosition, "toonCameraPosition")
  loc(baseColorTexture, "toonBaseColorTexture")
  loc(baseColorFactor, "toonBaseColorFactor")
  loc(emissiveFactor, "toonEmissiveFactor")
  loc(ramp, "toonRamp")
  loc(highlightColor, "toonHighlightColor")
  loc(shadowColor, "toonShadowColor")
  loc(rimColor, "toonRimColor")
  loc(unlit, "toonUnlit")
  loc(chrome, "toonChrome")
  loc(ghost, "toonGhost")
  loc(dissolve, "toonDissolve")
  loc(time, "toonTime")
  loc(shadowMvp, "toonShadowMvp")
  loc(shadowMap, "toonShadowMap")
  loc(shadowStrength, "toonShadowStrength")
  loc(shadowBias, "toonShadowBias")
  loc(shadowTexel, "toonShadowTexel")
  loc(shadowSoftness, "toonShadowSoftness")
  result.setRamp(rampImage())

  result.depthShader = compileProgram(ToonDepthVertSrc, ToonDepthFragSrc, "toon depth")
  result.depthModel = glGetUniformLocation(result.depthShader, "toonModel")
  result.depthLightMvp = glGetUniformLocation(result.depthShader, "toonDepthLightMvp")

  let white = newImage(1, 1)
  white.fill(rgbx(255, 255, 255, 255))
  result.whiteTexture = uploadTexture(white)

proc upload(mesh: ToonMesh) =
  glGenVertexArrays(1, mesh.vertexArray.addr)
  glBindVertexArray(mesh.vertexArray)
  glGenBuffers(4, mesh.buffers[0].addr)

  template attribute(slot: GLuint, buffer: GLuint, values: untyped, floats: int) =
    glBindBuffer(GL_ARRAY_BUFFER, buffer)
    glBufferData(GL_ARRAY_BUFFER, values.len * sizeof(values[0]), values[0].addr, GL_STATIC_DRAW)
    glEnableVertexAttribArray(slot)
    glVertexAttribPointer(slot, floats.GLint, cGL_FLOAT, GL_FALSE, 0, nil)

  attribute(PositionSlot, mesh.buffers[0], mesh.points, 3)
  attribute(NormalSlot, mesh.buffers[1], mesh.normals, 3)
  attribute(UvSlot, mesh.buffers[2], mesh.uvs, 2)
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, mesh.buffers[3])
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, mesh.indices.len * sizeof(uint32),
    mesh.indices[0].addr, GL_STATIC_DRAW)
  glBindVertexArray(0)

proc release*(mesh: ToonMesh) =
  ## Free the GPU copy of the mesh. Drawing it again sends it again.
  if mesh.vertexArray != 0:
    glDeleteVertexArrays(1, mesh.vertexArray.addr)
    glDeleteBuffers(4, mesh.buffers[0].addr)
    mesh.vertexArray = 0

proc bindMesh(mesh: ToonMesh): bool =
  ## False for a mesh with nothing in it.
  if mesh.indices.len == 0:
    return false
  if mesh.vertexArray == 0:
    mesh.upload()
  glBindVertexArray(mesh.vertexArray)
  true

## Drawing. Bracket the draws of one frame: `beginDepth`, `drawDepth` ... inside
## `sunDepthPass`, then `beginDraw`, `draw` ..., `endDraw`.

proc beginDraw*(ctx: ToonContext) =
  ## Select the lit shader and send it everything that stays the same for the
  ## frame.
  glUseProgram(ctx.shader)
  let u = ctx.uniforms
  var
    viewMat = ctx.view
    projMat = ctx.proj
    lightMatrix = sunLightMvp
  glUniformMatrix4fv(u.view, 1, GL_FALSE, cast[ptr float32](viewMat.addr))
  glUniformMatrix4fv(u.proj, 1, GL_FALSE, cast[ptr float32](projMat.addr))
  glUniform3f(u.lightDirection, ctx.lightDirection.x, ctx.lightDirection.y, ctx.lightDirection.z)
  glUniform3f(u.cameraPosition, ctx.cameraPosition.x, ctx.cameraPosition.y, ctx.cameraPosition.z)
  glUniform4f(u.highlightColor, ctx.highlightColor.r, ctx.highlightColor.g,
    ctx.highlightColor.b, ctx.highlightColor.a)
  glUniform4f(u.shadowColor, ctx.shadowColor.r, ctx.shadowColor.g, ctx.shadowColor.b,
    ctx.shadowColor.a)
  glUniform4f(u.rimColor, ctx.rimColor.r, ctx.rimColor.g, ctx.rimColor.b, ctx.rimColor.a)
  glUniform1f(u.time, ctx.time)
  glUniformMatrix4fv(u.shadowMvp, 1, GL_FALSE, cast[ptr float32](lightMatrix.addr))
  glUniform1f(u.shadowStrength, sunShadowStrength)
  glUniform1f(u.shadowBias, sunShadowBias)
  glUniform1f(u.shadowTexel, SunShadowTexel)
  glUniform1f(u.shadowSoftness, sunShadowSoftness)
  glUniform1i(u.baseColorTexture, 0)
  glUniform1i(u.ramp, 1)
  glUniform1i(u.shadowMap, 2)
  glActiveTexture(GL_TEXTURE1)
  glBindTexture(GL_TEXTURE_2D, ctx.rampTexture)
  glActiveTexture(GL_TEXTURE2)
  glBindTexture(GL_TEXTURE_2D, sunShadowTexture)
  glActiveTexture(GL_TEXTURE0)
  glEnable(GL_DEPTH_TEST)
  glDepthFunc(GL_LEQUAL)
  # Meshes built in code are not careful about which way their triangles
  # wind, so both sides of every triangle are drawn.
  glDisable(GL_CULL_FACE)

proc draw*(ctx: ToonContext, mesh: ToonMesh, material: ToonMaterial, transform = mat4()) =
  ## Draw one mesh. Draw the see-through ones after all the others, so that
  ## what is behind them is already there: they do not write depth.
  if not mesh.bindMesh():
    return
  let u = ctx.uniforms
  var
    modelMat = transform
    normalMat = mat3(
      transform[0, 0], transform[0, 1], transform[0, 2],
      transform[1, 0], transform[1, 1], transform[1, 2],
      transform[2, 0], transform[2, 1], transform[2, 2]
    ).inverse.transpose
  glUniformMatrix4fv(u.model, 1, GL_FALSE, cast[ptr float32](modelMat.addr))
  glUniformMatrix3fv(u.normalMatrix, 1, GL_FALSE, cast[ptr float32](normalMat.addr))
  glUniform4f(u.baseColorFactor, material.color.r, material.color.g, material.color.b,
    material.color.a)
  glUniform3f(u.emissiveFactor, material.emissive.r, material.emissive.g, material.emissive.b)
  glUniform1f(u.unlit, if material.unlit: 1 else: 0)
  glUniform1f(u.chrome, material.chrome)
  glUniform1f(u.ghost, material.ghost)
  glUniform1f(u.dissolve, material.dissolve)
  glBindTexture(GL_TEXTURE_2D,
    if material.texture != 0: material.texture else: ctx.whiteTexture)
  if material.color.a < 1 or material.ghost > 0:
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
    glDepthMask(GL_FALSE)
  else:
    glDisable(GL_BLEND)
    glDepthMask(GL_TRUE)
  glDrawElements(GL_TRIANGLES, mesh.indices.len.GLint, GL_UNSIGNED_INT, nil)

proc endDraw*(ctx: ToonContext) =
  glDisable(GL_BLEND)
  glDepthMask(GL_TRUE)
  glBindVertexArray(0)
  glUseProgram(0)

proc beginDepth*(ctx: ToonContext) =
  ## Select the depth shader. Call inside `sunDepthPass`.
  glUseProgram(ctx.depthShader)
  var lightMatrix = sunLightMvp
  glUniformMatrix4fv(ctx.depthLightMvp, 1, GL_FALSE, cast[ptr float32](lightMatrix.addr))

proc drawDepth*(ctx: ToonContext, mesh: ToonMesh, transform = mat4()) =
  ## Draw one mesh into the shadow map, so that it casts a shadow.
  if not mesh.bindMesh():
    return
  var modelMat = transform
  glUniformMatrix4fv(ctx.depthModel, 1, GL_FALSE, cast[ptr float32](modelMat.addr))
  glDrawElements(GL_TRIANGLES, mesh.indices.len.GLint, GL_UNSIGNED_INT, nil)
