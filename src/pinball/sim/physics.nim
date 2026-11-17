## Ball physics: gravity down the slope, collisions with capsules, the
## flippers, the plunger and nudges. Physics knows only `Collider`s. What a
## component does when it is hit is decided in `components.nim`, from the
## contacts that physics reports.

import types, layout

proc setFlipper*(table: var Table, side: FlipperSide, pressed: bool) =
  ## Press or release a flipper button. A tilted table ignores presses.
  discard

proc setPlunger*(table: var Table, pressed: bool) =
  ## Hold to pull the plunger back. Releasing fires it, and the pull length
  ## sets the launch strength.
  discard

proc nudge*(table: var Table, direction: NudgeDirection) =
  ## Shove every free ball slightly. Counts toward the tilt warnings.
  discard

proc stepPhysics*(table: var Table) =
  ## Advance the flippers, the plunger and every free ball by one tick.
  ## Balls collide with the fixed parts, the flippers, each other, and the
  ## colliders of solid components on their own level. Each touch of a
  ## component's collider is added to `table.contacts`.
  discard
