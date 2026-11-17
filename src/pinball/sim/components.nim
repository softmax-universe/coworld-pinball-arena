## What each component kind does: its collision shape, and how it reacts when
## a ball touches it (kick, drop, capture, count a spin, ...). Reactions
## change the component and raise the events of Appendix A.

import types, catalogue

proc rebuildColliders*(component: var Component) =
  ## Derive `component.colliders` from its kind, place, size and settings.
  ## A piece that is not solid, or a drop target that is down, has none.
  discard

proc applyForces*(table: var Table) =
  ## Magnets pull, push or hold the free balls in their reach.
  discard

proc resolveContacts*(table: var Table) =
  ## Turn this tick's `table.contacts` into component reactions and events.
  discard

proc advanceComponents*(table: var Table) =
  ## Count down hold and travel timers, eject balls whose time is up, and
  ## report pending spinner turns.
  discard

proc releaseBalls*(table: var Table, componentId, group: int32) =
  ## Let go of every ball held by the component, or by each piece of the group.
  discard

proc resetTargets*(table: var Table, componentId, group: int32) =
  ## Raise drop targets again and relight kickbacks.
  discard

proc ballSearch*(table: var Table) =
  ## Fire every kicker and pulse every magnet, to free a stuck ball.
  discard
