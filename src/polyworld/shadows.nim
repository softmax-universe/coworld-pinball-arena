## The shadow map of the one directional light.
##
## The light renders every caster into a depth map, and the lit shader in
## `toon` darkens whatever the light cannot see, with hardware PCF filtering
## for soft edges. This module owns the depth framebuffer and the light
## matrix. `toon` owns the depth shader and draws the casters inside the
## `sunDepthPass` bracket.
##
## From Polyworld. Changed for Pinball Arena: the light is fixed, so the day
## clock, the moon and the second cross-faded map are gone, and so are the
## depth programs for terrain and foliage. The light can aim at any point
## (`sunLightTarget`), not only at the origin.

import
  std/math,
  opengl, vmath

const
  SunShadowMapSize* = 2048
  SunShadowTexel* = 1.0'f32 / SunShadowMapSize.float32

var
  sunAzimuth* = 48.0'f32         ## Degrees around the vertical axis.
  sunElevation* = 53.0'f32       ## Degrees above the horizon.
  sunShadowStrength* = 0.75'f32  ## 1: full shadow drops to the shadow colour.
  sunShadowBias* = 0.0012'f32    ## Depth offset that hides self-shadow acne.
  sunShadowSoftness* = 1.5'f32   ## PCF spread in shadow-map texels.
  sunLightTarget* = vec3(0)      ## The point the light looks at.
  sunDirection* = normalize(vec3(0.45, 0.8, 0.4))  ## Toward the light.
  sunLightMvp*: Mat4             ## The light's view-projection.
  sunShadowTexture*: GLuint      ## The depth texture, compare mode on.
  sunLightRadius = 100.0'f32
  sunLightDistance = 170.0'f32
  sunFramebuffer: GLuint

proc updateSunMatrix*() =
  ## Recompute the light direction and matrix from the angles and the target.
  let
    a = sunAzimuth * PI.float32 / 180.0
    e = sunElevation * PI.float32 / 180.0
  sunDirection = vec3(cos(e) * sin(a), sin(e), cos(e) * cos(a))
  let
    view = lookAt(
      sunLightTarget + sunDirection * sunLightDistance, sunLightTarget, vec3(0, 1, 0))
    projection = ortho(
      -sunLightRadius, sunLightRadius, -sunLightRadius, sunLightRadius,
      sunLightDistance - sunLightRadius, sunLightDistance + sunLightRadius)
  sunLightMvp = projection * view

proc initSunShadows*(lightRadius = 100.0'f32, lightDistance = 170.0'f32) =
  ## Create the shadow framebuffer. Needs a current GL context. The radius
  ## must cover the whole scene as the light sees it.
  if sunFramebuffer != 0:
    return
  sunLightRadius = lightRadius
  sunLightDistance = lightDistance

  # Linear filtering plus the comparison mode turns every sampler2DShadow
  # tap into a bilinearly filtered depth test (hardware PCF).
  glGenTextures(1, sunShadowTexture.addr)
  glBindTexture(GL_TEXTURE_2D, sunShadowTexture)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24.GLint,
    SunShadowMapSize, SunShadowMapSize, 0,
    GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, nil
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(
    GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_FUNC, GL_LEQUAL.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)

  glGenFramebuffers(1, sunFramebuffer.addr)
  glBindFramebuffer(GL_FRAMEBUFFER, sunFramebuffer)
  glFramebufferTexture2D(
    GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, sunShadowTexture, 0)
  var drawTargets = [GL_NONE]
  glDrawBuffers(1, cast[ptr GLenum](drawTargets.addr))
  glReadBuffer(GL_NONE)
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
  # Start the map at far depth so everything counts as lit until the first
  # real depth pass runs.
  glClear(GL_DEPTH_BUFFER_BIT)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  updateSunMatrix()

template sunDepthPass*(framebufferSize: IVec2, body: untyped) =
  ## Draw the shadow casters in `body` into the shadow map, then go back to
  ## drawing into the window.
  glBindFramebuffer(GL_FRAMEBUFFER, sunFramebuffer)
  glViewport(0, 0, SunShadowMapSize, SunShadowMapSize)
  glClear(GL_DEPTH_BUFFER_BIT)
  glEnable(GL_DEPTH_TEST)
  glDepthMask(GL_TRUE)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  body
  glBindVertexArray(0)
  glUseProgram(0)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)
  glViewport(0, 0, framebufferSize.x.GLsizei, framebufferSize.y.GLsizei)
