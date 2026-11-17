## The editing rules: how the arena changes while the ball is in play.
##
## New and moved pieces beam in as holograms and turn solid after a delay, and
## a hologram with a ball inside it waits. Pieces never slide: a move fades
## the piece out and beams it in at the new place. An edit that breaks a rule
## (keep-out zone, build budget, piece cap, overlap, edit rate) does nothing
## and is reported.

import types, catalogue, layout, components

proc applyEdit*(table: var Table, edit: Edit, rateLimited: bool): CommandOutcome =
  ## Check one edit and carry it out. Edits from the Arena script are rate
  ## limited during play. Edits from rule results are not. A rejected edit is
  ## added to `table.rejectedEdits` and raises `evEditRejected`.
  discard

proc advanceBeamIns*(table: var Table) =
  ## Count down holograms and fade-outs by one tick.
  discard

proc clearArena*(table: var Table) =
  ## Fade out every piece. A piece that holds a ball releases it.
  discard
