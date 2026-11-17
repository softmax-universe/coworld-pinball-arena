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

const FloatTextTicks = 2 * TicksPerSecond
  ## How long a floating message from a rule stays on screen.

# --- Building FSMs -----------------------------------------------------------

const UnknownTarget = CommandOutcome(reason: rejectUnknownTarget)

proc createFsm*(table: var Table): CommandOutcome =
  ## A new FSM with only its initial node (node 0). `id` is the FSM id.
  if table.fsms.len >= MaxFsms:
    return CommandOutcome(reason: rejectLimit)
  result.id = table.nextFsmId
  inc table.nextFsmId
  table.fsms.add Fsm(id: result.id, nodes: @[Node()])

proc deleteFsm*(table: var Table, fsmId: int32): CommandOutcome =
  let index = table.fsmIndex(fsmId)
  if index < 0:
    return UnknownTarget
  table.fsms.delete(index)

proc resetFsm*(table: var Table, fsmId: int32): CommandOutcome =
  ## Back to the initial node, counts cleared, running again.
  let index = table.fsmIndex(fsmId)
  if index < 0:
    return UnknownTarget
  table.fsms[index].currentNode = 0
  table.fsms[index].ticksInNode = 0
  for hits in table.fsms[index].edgeHits.mitems:
    hits = 0
  table.fsms[index].stopped = false

proc addNode*(table: var Table, fsmId: int32): CommandOutcome =
  ## `id` is the index of the new node.
  let index = table.fsmIndex(fsmId)
  if index < 0:
    return UnknownTarget
  if table.fsms[index].nodes.len >= MaxNodesPerFsm:
    return CommandOutcome(reason: rejectLimit)
  result.id = int32(table.fsms[index].nodes.len)
  table.fsms[index].nodes.add Node()

proc addEdge*(table: var Table, fsmId: int32, edge: Edge): CommandOutcome =
  let index = table.fsmIndex(fsmId)
  if index < 0:
    return UnknownTarget
  let nodeCount = int32(table.fsms[index].nodes.len)
  if edge.fromNode notin 0 ..< nodeCount or edge.toNode notin 0 ..< nodeCount:
    return UnknownTarget
  if edge.isTimeout:
    if edge.timeoutTicks < 1:
      return CommandOutcome(reason: rejectBadValue)
  elif edge.count notin 1 .. MaxEdgeCount:
    return CommandOutcome(reason: rejectBadValue)
  if table.fsms[index].edges.len >= MaxEdgesPerFsm:
    return CommandOutcome(reason: rejectLimit)
  table.fsms[index].edges.add edge
  table.fsms[index].edgeHits.add 0

proc isWithinLimits(nodeResult: NodeResult): bool =
  ## Targets are not checked here: a rule may name a piece that is built later.
  case nodeResult.kind
  of resultScore:
    abs(nodeResult.amount) <= MaxScoreChange
  of resultSignal:
    nodeResult.amount in 0 ..< SignalCount
  of resultPanelText, resultFloatText:
    isValidText(nodeResult.text)
  of resultBallAction:
    nodeResult.ballAction != ballActionSave or nodeResult.amount >= 0
  else:
    true

proc addResult*(table: var Table, fsmId, nodeIndex: int32, nodeResult: NodeResult): CommandOutcome =
  let index = table.fsmIndex(fsmId)
  if index < 0 or nodeIndex notin 0 ..< table.fsms[index].nodes.len:
    return UnknownTarget
  if not isWithinLimits(nodeResult):
    return CommandOutcome(reason: rejectBadValue)
  table.fsms[index].nodes[nodeIndex].results.add nodeResult

proc setFinal*(table: var Table, fsmId, nodeIndex: int32): CommandOutcome =
  let index = table.fsmIndex(fsmId)
  if index < 0 or nodeIndex notin 0 ..< table.fsms[index].nodes.len:
    return UnknownTarget
  table.fsms[index].nodes[nodeIndex].isFinal = true

# --- Results -----------------------------------------------------------------

proc setLamps(table: var Table, targetId, targetGroup: int32, lamp: LampState) =
  for component in table.components.mitems:
    let isTarget =
      if targetGroup != 0: component.group == targetGroup
      else: component.id == targetId
    if isTarget:
      component.settings[setLamp] = fixed(int32(ord(lamp)))

proc applyResult(table: var Table, nodeResult: NodeResult, eventComponentId: int32) =
  ## `eventComponentId` is the component of the event that led here, or 0.
  case nodeResult.kind
  of resultScore:
    table.score = max(0, table.score + nodeResult.amount)
    table.scoreChanges.add ScoreChange(amount: nodeResult.amount, componentId: eventComponentId)
  of resultSound:
    table.cues.add ViewCue(kind: cueKindSound, sound: nodeResult.sound)
  of resultFlashers:
    table.cues.add ViewCue(kind: cueKindFlashers)
  of resultBurst:
    table.cues.add ViewCue(kind: cueKindBurst, componentId: nodeResult.targetId)
  of resultLamp:
    table.setLamps(nodeResult.targetId, nodeResult.targetGroup, nodeResult.lamp)
  of resultPanelText:
    case nodeResult.slot
    of slotQuest: table.questText = nodeResult.text
    of slotAward: table.awardText = nodeResult.text
  of resultFloatText:
    table.floatingMessages.add FloatingMessage(
      componentId: nodeResult.targetId, text: nodeResult.text, ticksLeft: FloatTextTicks)
  of resultSignal:
    table.emitNext Event(kind: evFsmSignal, value: nodeResult.amount)
  of resultEdit:
    # An edit that cannot be applied is skipped. `applyEdit` logs it.
    discard table.applyEdit(nodeResult.edit, rateLimited = false)
  of resultBallAction:
    case nodeResult.ballAction
    of ballActionAdd: discard table.addBall()
    of ballActionSave: table.startBallSave(nodeResult.amount)
    of ballActionExtraBall: table.awardExtraBall()
    of ballActionRelease: table.releaseBalls(nodeResult.targetId, nodeResult.targetGroup)

# --- Running FSMs ------------------------------------------------------------

proc matches(edge: Edge, event: Event): bool =
  not edge.isTimeout and
    edge.event == event.kind and
    (edge.componentId == 0 or edge.componentId == event.componentId) and
    (edge.group == 0 or edge.group == event.group) and
    (edge.level == 0 or edge.level == event.level) and
    (edge.value == -1 or edge.value == event.value) and
    event.strength >= edge.minStrength

proc hasOutgoingEdges(fsm: Fsm, nodeIndex: int32): bool =
  for edge in fsm.edges:
    if edge.fromNode == nodeIndex:
      return true

proc countFiring(table: var Table, fsmId, nodeIndex: int32) =
  for firing in table.ruleFirings.mitems:
    if firing.fsmId == fsmId and firing.nodeIndex == nodeIndex:
      inc firing.count
      return
  table.ruleFirings.add RuleFiring(fsmId: fsmId, nodeIndex: nodeIndex, count: 1)

proc enterNode(table: var Table, fsmIndex: int, nodeIndex, eventComponentId: int32) =
  ## Move the FSM along an edge to `nodeIndex` and run the results there.
  let node = table.fsms[fsmIndex].nodes[nodeIndex]
  table.fsms[fsmIndex].currentNode = nodeIndex
  table.fsms[fsmIndex].ticksInNode = 0
  for hits in table.fsms[fsmIndex].edgeHits.mitems:
    hits = 0
  table.countFiring(table.fsms[fsmIndex].id, nodeIndex)

  for nodeResult in node.results:
    table.applyResult(nodeResult, eventComponentId)

  if node.isFinal:
    table.fsms[fsmIndex].stopped = true
  elif not table.fsms[fsmIndex].hasOutgoingEdges(nodeIndex):
    # The return to the initial node is not an entry: it runs no results.
    table.fsms[fsmIndex].currentNode = 0

proc firedEdge(fsm: var Fsm, event: Event): int =
  ## Count `event` on every edge it matches out of the current node. Returns
  ## the first edge that has now seen enough events, or -1.
  result = -1
  for edgeIndex, edge in fsm.edges:
    if edge.fromNode == fsm.currentNode and edge.matches(event):
      inc fsm.edgeHits[edgeIndex]
      if result < 0 and fsm.edgeHits[edgeIndex] >= edge.count:
        result = edgeIndex

proc timedOutEdge(fsm: Fsm): int =
  result = -1
  for edgeIndex, edge in fsm.edges:
    if edge.isTimeout and edge.fromNode == fsm.currentNode and
        fsm.ticksInNode >= edge.timeoutTicks:
      return edgeIndex

proc runRules*(table: var Table) =
  ## Feed this tick's `table.events` to every FSM, then fire timeouts.
  for event in table.events:
    for fsmIndex in 0 ..< table.fsms.len:
      if table.fsms[fsmIndex].stopped:
        continue
      let edgeIndex = table.fsms[fsmIndex].firedEdge(event)
      if edgeIndex >= 0:
        table.enterNode(fsmIndex, table.fsms[fsmIndex].edges[edgeIndex].toNode, event.componentId)

  for fsmIndex in 0 ..< table.fsms.len:
    if table.fsms[fsmIndex].stopped:
      continue
    inc table.fsms[fsmIndex].ticksInNode
    let edgeIndex = table.fsms[fsmIndex].timedOutEdge()
    if edgeIndex >= 0:
      table.enterNode(fsmIndex, table.fsms[fsmIndex].edges[edgeIndex].toNode, eventComponentId = 0)
