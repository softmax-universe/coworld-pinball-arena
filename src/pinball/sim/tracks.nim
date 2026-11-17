## Track: two mouth pieces joined by a curve.
##
## A ball that rolls into the open end of a mouth is taken onto the track and
## then moves along the centre line of the curve only (one dimension). The
## slope of the table and the climb of a ramp slow it or speed it up. It
## leaves through the other mouth (track completed) or rolls back out of the
## mouth it came in by (track failed). Mouths on different levels make a ramp,
## and a ball on a raised track touches nothing on the playfield below.

import types

proc trackLength*(table: Table, track: Component): Fixed =
  ## The length of the curve between the two mouths, in millimetres.
  discard

proc trackPoint*(table: Table, track: Component, distance: Fixed): FixedVec2 =
  ## The point on the curve `distance` millimetres from mouth A.
  discard

proc stepTracks*(table: var Table) =
  ## Take free balls that enter a mouth onto its track, move the balls that
  ## are on tracks by one tick, and put the ones that reach an end back on
  ## the table.
  discard
