## The fixed parts of the table, which the Arena player cannot change: the
## outer walls and top arch, the shooter lane with its plunger on the right,
## the inlanes and outlanes beside the flippers, the apron and the drain.
## Also the keep-out zones, where nothing can be built.

import types

proc fixedColliders*(): seq[Collider] =
  ## The collision shapes of every fixed part except the flippers.
  discard

proc flipperCollider*(side: FlipperSide, angle: Fixed): Collider =
  ## The capsule of one flipper when it is `angle` degrees above rest.
  discard

proc shooterLaneStart*(): FixedVec2 =
  ## Where a served ball rests on the plunger.
  discard

proc isDrained*(pos: FixedVec2): bool =
  ## True when a ball at `pos` has left play through the drain.
  discard

proc inKeepOut*(shape: Collider): bool =
  ## True when the shape reaches into a keep-out zone (the area the flippers
  ## sweep plus a margin, the drain mouth, the shooter lane) or lies outside
  ## the playfield walls.
  discard
