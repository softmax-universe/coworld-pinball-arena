## The calls of the Flipper seat.

import bassy
import ../sim/simulation
import base

proc addFlipperCalls*(host: var Host, script: Script) =
  host.call("flip", 2):
    script.give Command(kind: cmdFlipper, side: toEnum[FlipperSide](args[0]),
                        pressed: args[1].asBool)

  host.call("plunger", 1):
    script.give Command(kind: cmdPlunger, pressed: args[0].asBool)

  host.call("nudge", 1):
    script.give Command(kind: cmdNudge, direction: toEnum[NudgeDirection](args[0]))

proc goLimp*(script: Script) =
  ## What a failed Flipper program leaves behind: nothing held.
  for side in FlipperSide:
    discard script.give Command(kind: cmdFlipper, side: side, pressed: false)
  discard script.give Command(kind: cmdPlunger, pressed: false)
