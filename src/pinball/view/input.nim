## The human's controls: keyboard and gamepad, turned into `Command`s.
##
## Keys and sticks are read once per frame. Everything becomes a discrete
## command (flipper up or down, plunger pulled or let go, one nudge) before it
## reaches the game, so no analogue value ever enters the simulation.
##
## | Action        | Keyboard          | Gamepad                             |
## | Left flipper  | Z or Left Shift   | Left trigger or bumper              |
## | Right flipper | / or Right Shift  | Right trigger or bumper             |
## | Plunger       | Space (hold)      | Right stick pulled down, let go     |
## | Nudge         | X, . and Up       | A flick of the left stick           |

import
  windy, paddy,
  ../sim/types,
  ../game

const
  TriggerPressed = 0.5'f32     ## How far a trigger must be squeezed.
  PlungerPulled = 0.5'f32      ## How far down the right stick counts as pulled.
  FlickOut = 0.7'f32           ## The left stick this far from the middle is a nudge ...
  FlickBack = 0.35'f32         ## ... and it must come back this near before the next one.
  ScanEveryFrames = 120
    ## A browser only shows a gamepad after a button on it was pressed, so
    ## the game keeps looking for new ones.

type Controls* = object
  ## What was last sent to the game, to send only changes.
  flipperHeld: array[FlipperSide, bool]
  plungerHeld: bool
  nudgeKeyHeld: array[NudgeDirection, bool]
  stickFlicked: bool
  frames: int

proc initControls*(): Controls =
  initGamepads()

proc stickDown(pad: Gamepad, axis: GamepadAxis): float32 =
  ## A stick's up-and-down axis with down as positive. macOS reports up as
  ## positive; browsers and the others report down.
  when defined(macosx) and not defined(emscripten):
    -pad.axis(axis)
  else:
    pad.axis(axis)

proc readControls*(controls: var Controls, window: Window, game: Game) =
  ## Call once per frame, after the window has polled its events.
  inc controls.frames
  when defined(emscripten):
    if controls.frames mod ScanEveryFrames == 0:
      scanGamepads()

  var
    flipper = [flipperLeft: window.buttonDown[KeyZ] or window.buttonDown[KeyLeftShift],
               flipperRight: window.buttonDown[KeySlash] or window.buttonDown[KeyRightShift]]
    plunger = window.buttonDown[KeySpace]
    nudgeKey = [nudgeLeft: window.buttonDown[KeyX],
                nudgeRight: window.buttonDown[KeyPeriod],
                nudgeUp: window.buttonDown[KeyUp]]
    stick: tuple[x, down: float32]

  for pad in pollGamepads():
    flipper[flipperLeft] = flipper[flipperLeft] or pad.button(GamepadL1) or
      pad.buttonPressure(GamepadL2) > TriggerPressed
    flipper[flipperRight] = flipper[flipperRight] or pad.button(GamepadR1) or
      pad.buttonPressure(GamepadR2) > TriggerPressed
    plunger = plunger or pad.stickDown(GamepadRStickY) > PlungerPulled
    if abs(pad.axis(GamepadLStickX)) + abs(pad.stickDown(GamepadLStickY)) > abs(stick.x) + abs(stick.down):
      stick = (pad.axis(GamepadLStickX), pad.stickDown(GamepadLStickY))

  for side in FlipperSide:
    if flipper[side] != controls.flipperHeld[side]:
      controls.flipperHeld[side] = flipper[side]
      game.humanInput(Command(kind: cmdFlipper, side: side, pressed: flipper[side]))

  if plunger != controls.plungerHeld:
    controls.plungerHeld = plunger
    game.humanInput(Command(kind: cmdPlunger, pressed: plunger))

  for direction in NudgeDirection:
    if nudgeKey[direction] and not controls.nudgeKeyHeld[direction]:
      game.humanInput(Command(kind: cmdNudge, direction: direction))
    controls.nudgeKeyHeld[direction] = nudgeKey[direction]

  # A flick of the left stick is one nudge, the way the stick went. Pushing
  # it toward the player does nothing: a table cannot be nudged that way.
  let reach = max(abs(stick.x), abs(stick.down))
  if reach < FlickBack:
    controls.stickFlicked = false
  elif reach > FlickOut and not controls.stickFlicked:
    controls.stickFlicked = true
    if abs(stick.x) >= abs(stick.down):
      game.humanInput(Command(kind: cmdNudge,
        direction: if stick.x < 0: nudgeLeft else: nudgeRight))
    elif stick.down < 0:
      game.humanInput(Command(kind: cmdNudge, direction: nudgeUp))
