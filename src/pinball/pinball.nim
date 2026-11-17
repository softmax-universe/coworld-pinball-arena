## Pinball Arena: the program a person plays. It opens the window (in a
## browser, the page's canvas), runs the game at 120 ticks per second, and
## each frame draws the table, plays its sounds, reads the controls and
## talks to the web page.
##
## The same code builds natively, for development, and to WebAssembly:
##
##   nim r src/pinball/pinball.nim --demo-table
##   nim r src/pinball/pinball.nim --demo-table --screenshot shot.png --ticks 700
##   tools/build_web.sh
##
## Options:
##   --demo-table            Put one piece of every kind on the table (temporary, see
##                           view/demotable.nim).
##   --demo-play             With --demo-table: also launch the ball and flip.
##   --screenshot PATH       Run --ticks ticks, save one frame as a PNG and exit. Native only.
##   --ticks N               How many ticks to run before the screenshot. Default 0.
##   --size WxH              Window size in pixels. Native only.

import
  std/[os, strutils, times],
  opengl, pixie, vmath, windy,
  game,
  sim/simulation,
  view/[tableview, sound, input, bridge, demotable]

const
  TickSeconds = 1.0 / TicksPerSecond.float64
  MaxCatchUpSeconds = 0.1
    ## After a stall (a hidden tab, a debugger) the game runs at most this
    ## much simulated time in one frame and drops the rest, so it does not
    ## spend ever longer catching up.
  DefaultWindowSize = ivec2(620, 1000)
  TicksPerScreenshotFrame = 2
    ## On the way to a screenshot the game draws a frame every so many ticks,
    ## as if it ran at 60 frames per second, so that the view's own short
    ## animations are where they would be in a live game.

when defined(emscripten):
  # Give the browser the rest of each frame. Without this the loop would
  # draw frames the browser never shows. A hidden tab gets no animation
  # frames, so the timeout keeps the game ticking there.
  {.emit: """
  #include <emscripten.h>
  EM_ASYNC_JS(void, pinballWaitForDisplay, (), {
    await new Promise(function(resolve) {
      requestAnimationFrame(resolve);
      setTimeout(resolve, 100);
    });
  });
  """.}
  proc pinballWaitForDisplay() {.importc, nodecl.}

type
  Options = object
    demoTable, demoPlay: bool
    screenshotPath: string
    ticks: int
    windowSize: IVec2

  App = object
    options: Options
    window: Window
    game: Game
    view: TableView
    controls: Controls
    bridge: Bridge

proc parseOptions(): Options =
  result.windowSize = DefaultWindowSize
  let arguments = commandLineParams()
  var index = 0
  proc value(): string =
    inc index
    if index >= arguments.len:
      quit("Missing value after " & arguments[index - 1])
    arguments[index]
  while index < arguments.len:
    case arguments[index]
    of "--demo-table": result.demoTable = true
    of "--demo-play": result.demoPlay = true
    of "--screenshot": result.screenshotPath = value()
    of "--ticks": result.ticks = parseInt(value())
    of "--size":
      let parts = value().split('x')
      result.windowSize = ivec2(parseInt(parts[0]).int32, parseInt(parts[1]).int32)
    else: quit("Unknown option " & arguments[index])
    inc index

proc advance(app: var App, audible = true) =
  ## One tick of the game, and everything that follows a tick.
  if app.options.demoTable:
    demoTick(app.game, app.options.demoPlay)
  app.game.tick()
  app.view.observe(app.game.table)
  app.bridge.noteTick(app.game.table)
  if audible:
    playTickSounds(app.game.table)
  for message in app.game.takeMessages():
    sendToPage(message)

proc frame(app: var App, seconds: float32) =
  app.view.draw(app.game.table, app.window.size, seconds)
  app.bridge.publish(app.game, app.view, seconds)

proc saveScreenshot(app: var App) =
  for tick in 0 ..< app.options.ticks:
    app.advance(audible = false)
    if tick mod TicksPerScreenshotFrame == 0:
      app.frame(TicksPerScreenshotFrame / TicksPerSecond)
  app.frame(0)
  let
    size = app.window.size
    image = newImage(size.x, size.y)
  glReadPixels(0, 0, size.x.GLsizei, size.y.GLsizei, GL_RGBA, GL_UNSIGNED_BYTE,
    image.data[0].addr)
  image.flipVertical()
  image.writeFile(app.options.screenshotPath)
  echo "Saved ", app.options.screenshotPath

proc run(app: var App) =
  var
    lastFrame = epochTime()
    owed = 0.0   # Simulated time that has not been run yet.
  while not app.window.closeRequested:
    pollEvents()
    let now = epochTime()
    let seconds = clamp(now - lastFrame, 0.0, 0.25)
    lastFrame = now

    deliverInbox(app.game)
    app.controls.readControls(app.window, app.game)
    owed = min(owed + seconds, MaxCatchUpSeconds)
    while owed >= TickSeconds:
      owed -= TickSeconds
      app.advance()
    app.frame(seconds.float32)
    app.window.swapBuffers()
    when defined(emscripten):
      pinballWaitForDisplay()

proc main() =
  var app = App(options: parseOptions())
  let takingScreenshot = app.options.screenshotPath.len > 0
  app.window = newWindow("Pinball Arena", app.options.windowSize,
    visible = not takingScreenshot, msaa = msaa4x)
  app.window.makeContextCurrent()
  when not defined(emscripten):
    loadExtensions()
  app.game = newGame()
  app.view = newTableView()

  if takingScreenshot:
    app.saveScreenshot()
    return
  initSound()
  app.controls = initControls()
  app.run()
  closeSound()

main()
