## Rules: the finite state machines that award and show everything.
##
## An FSM has nodes joined by edges and one current node. An edge names the
## event that fires it. Entering a node runs its results, which are the only
## way that score, lamps, messages and sounds happen.
##
## Evaluation order (Appendix G of the design):
##
## - When one event matches several FSMs, each advances once, in the order the
##   FSMs were created. Inside one FSM the first matching edge wins.
## - Whatever a result raises (signals, edit events, ball events) goes through
##   `emitNext`, so it is delivered on the next tick. Rules cannot loop within
##   one tick.
## - A node with no outgoing edges returns to the initial node straight after
##   its results run. A final node stops the FSM.

import types, editing, episode, components

proc createFsm*(table: var Table): CommandOutcome =
  ## A new FSM with only its initial node (node 0). `id` is the FSM id.
  discard

proc deleteFsm*(table: var Table, fsmId: int32): CommandOutcome =
  discard

proc resetFsm*(table: var Table, fsmId: int32): CommandOutcome =
  ## Back to the initial node, counts cleared, running again.
  discard

proc addNode*(table: var Table, fsmId: int32): CommandOutcome =
  ## `id` is the index of the new node.
  discard

proc addEdge*(table: var Table, fsmId: int32, edge: Edge): CommandOutcome =
  discard

proc addResult*(table: var Table, fsmId, nodeIndex: int32, nodeResult: NodeResult): CommandOutcome =
  discard

proc setFinal*(table: var Table, fsmId, nodeIndex: int32): CommandOutcome =
  discard

proc runRules*(table: var Table) =
  ## Feed this tick's `table.events` to every FSM, then fire timeouts.
  discard
