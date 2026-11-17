## Rules: the finite state machines of section 5 and Appendix G of the design.
##
## The tests build FSMs through the public procs of `rules.nim` and drive them
## with hand-made events, the way `simulation.step` will: one `runRules` call
## per tick, with the events of that tick in `game.events`.

import std/[unittest, strutils]
import pinball/sim/types
import pinball/sim/rules

const
  Bumper = 7'i32
  OtherBumper = 8'i32

proc tick(game: var Table, events: varargs[Event]) =
  ## One tick as the real driver runs it: the outputs of the last tick are
  ## cleared, events raised last tick (signals) are delivered, then the rules
  ## run on them and on the events given here.
  game.cues.setLen(0)
  game.scoreChanges.setLen(0)
  game.events = game.pendingEvents
  game.pendingEvents.setLen(0)
  for event in events:
    game.events.add event
  runRules(game)
  game.events.setLen(0)

proc ticks(game: var Table, count: int) =
  for _ in 1 .. count:
    game.tick()

proc hit(componentId: int32): Event =
  Event(kind: evHit, componentId: componentId, level: 1, strength: 800'fx)

proc edgeOn(fromNode, toNode: int32, event: EventKind): Edge =
  Edge(fromNode: fromNode, toNode: toNode, event: event, value: -1, count: 1)

proc timeoutEdge(fromNode, toNode, timeoutTicks: int32): Edge =
  Edge(fromNode: fromNode, toNode: toNode, isTimeout: true,
       timeoutTicks: timeoutTicks, value: -1, count: 1)

proc scoreResult(amount: int32): NodeResult =
  NodeResult(kind: resultScore, amount: amount)

proc soundResult(sound: SoundCue): NodeResult =
  NodeResult(kind: resultSound, sound: sound)

proc addScoreNode(game: var Table, fsmId, amount: int32): int32 =
  ## A new node whose only result is a score change.
  result = game.addNode(fsmId).id
  check game.addResult(fsmId, result, scoreResult(amount)).accepted

proc addScoreRule(game: var Table, edge: Edge, amount: int32): int32 =
  ## A whole FSM: `edge` (from the initial node) leads to a node that scores.
  ## Returns the FSM id.
  result = game.createFsm().id
  var edgeToNode = edge
  edgeToNode.fromNode = 0
  edgeToNode.toNode = game.addScoreNode(result, amount)
  check game.addEdge(result, edgeToNode).accepted

proc addPiece(game: var Table, id: int32, kind: ComponentKind, group = 0'i32) =
  game.components.add Component(id: id, kind: kind, group: group, level: 1,
                                sizePercent: 100, phase: phaseSolid)

proc lampOf(game: Table, componentId: int32): Fixed =
  game.components[game.componentIndex(componentId)].settings[setLamp]

proc lampValue(lamp: LampState): Fixed =
  fixed(int32(ord(lamp)))

proc scoresOn(edge: Edge, event: Event): bool =
  ## Whether a rule with this edge awards its score for this one event.
  var game = Table()
  discard game.addScoreRule(edge, 1)
  game.tick(event)
  game.score == 1

suite "rules":

  test "the simplest rule scores on every pop bumper hit":
    var game = Table()
    let fsmId = game.createFsm().id
    let node = game.addNode(fsmId).id
    check node == 1
    check game.addResult(fsmId, node, scoreResult(5)).accepted
    check game.addResult(fsmId, node, soundResult(cuePing)).accepted
    var edge = edgeOn(0, node, evHit)
    edge.componentId = Bumper
    check game.addEdge(fsmId, edge).accepted

    game.tick(hit(Bumper))
    check game.score == 5
    check game.scoreChanges == @[ScoreChange(amount: 5, componentId: Bumper)]
    check game.cues == @[ViewCue(kind: cueKindSound, sound: cuePing)]

    # The node has no outgoing edges, so the FSM is back at the initial node
    # and the next hit scores again.
    game.tick(hit(Bumper))
    game.tick(hit(Bumper))
    check game.score == 15

    game.tick()
    check game.score == 15
    check game.cues.len == 0

  test "an edge fires only on the event it names":
    check scoresOn(edgeOn(0, 1, evHit), hit(Bumper))
    check not scoresOn(edgeOn(0, 1, evHit), Event(kind: evRollover, componentId: Bumper))

  test "each filter narrows the edge":
    var byComponent = edgeOn(0, 1, evHit)
    byComponent.componentId = Bumper
    check scoresOn(byComponent, hit(Bumper))
    check not scoresOn(byComponent, hit(OtherBumper))

    var byGroup = edgeOn(0, 1, evDrop)
    byGroup.group = 2
    check scoresOn(byGroup, Event(kind: evDrop, componentId: 3, group: 2))
    check not scoresOn(byGroup, Event(kind: evDrop, componentId: 3, group: 1))
    check not scoresOn(byGroup, Event(kind: evDrop, componentId: 3))

    var byLevel = edgeOn(0, 1, evBallChangedLevel)
    byLevel.level = 2
    check scoresOn(byLevel, Event(kind: evBallChangedLevel, level: 2))
    check not scoresOn(byLevel, Event(kind: evBallChangedLevel, level: 1))

    var byValue = edgeOn(0, 1, evFlipperUp)
    byValue.value = ord(flipperRight).int32
    check scoresOn(byValue, Event(kind: evFlipperUp, value: ord(flipperRight).int32))
    check not scoresOn(byValue, Event(kind: evFlipperUp, value: ord(flipperLeft).int32))

    var byStrength = edgeOn(0, 1, evHit)
    byStrength.minStrength = 1000'fx
    check scoresOn(byStrength, Event(kind: evHit, componentId: Bumper, strength: 1500'fx))
    check not scoresOn(byStrength, Event(kind: evHit, componentId: Bumper, strength: 500'fx))

  test "a count edge fires on the Nth matching event and then counts again":
    var game = Table()
    var edge = edgeOn(0, 1, evHit)
    edge.componentId = Bumper
    edge.count = 3
    discard game.addScoreRule(edge, 10)

    game.tick(hit(Bumper))
    game.tick(hit(OtherBumper))   # Does not pass the filter, so does not count.
    game.tick(hit(Bumper))
    check game.score == 0
    game.tick(hit(Bumper))
    check game.score == 10

    # The node was left and the initial node entered again: the count restarts.
    game.tick(hit(Bumper))
    game.tick(hit(Bumper))
    check game.score == 10

    # Events of one tick are counted one by one.
    game.tick(hit(Bumper), hit(Bumper), hit(Bumper))
    check game.score == 20

  test "a timeout edge fires after its ticks in the node":
    var game = Table()
    let fsmId = game.createFsm().id
    let node = game.addScoreNode(fsmId, 7)
    check game.addEdge(fsmId, timeoutEdge(0, node, 5)).accepted

    game.ticks(4)
    check game.score == 0
    game.tick()
    check game.score == 7
    check game.scoreChanges == @[ScoreChange(amount: 7, componentId: 0)]

    # Back at the initial node, the time in the node starts from zero.
    game.ticks(4)
    check game.score == 7
    game.tick()
    check game.score == 14

  test "a timeout does not fire once the FSM has left the node":
    var game = Table()
    let fsmId = game.createFsm().id
    let waiting = game.addNode(fsmId).id
    let tooLate = game.addScoreNode(fsmId, 100)
    let inTime = game.addScoreNode(fsmId, 1)
    check game.addEdge(fsmId, edgeOn(0, waiting, evHit)).accepted
    check game.addEdge(fsmId, timeoutEdge(waiting, tooLate, 5)).accepted
    check game.addEdge(fsmId, edgeOn(waiting, inTime, evRollover)).accepted

    game.tick(hit(Bumper))
    game.ticks(2)
    game.tick(Event(kind: evRollover, componentId: 9))
    check game.score == 1
    game.ticks(10)
    check game.score == 1

    # Without the rollover the timeout does fire.
    game.tick(hit(Bumper))
    game.ticks(6)
    check game.score == 101

  test "visual and text results land in the table":
    var game = Table()
    game.addPiece(20, ckInsert, group = 3)
    game.addPiece(21, ckInsert, group = 3)
    game.addPiece(22, ckInsert)
    let fsmId = game.createFsm().id
    let node = game.addNode(fsmId).id
    check game.addResult(fsmId, node,
      NodeResult(kind: resultLamp, targetGroup: 3, lamp: lampFlashing)).accepted
    check game.addResult(fsmId, node,
      NodeResult(kind: resultBurst, targetId: Bumper)).accepted
    check game.addResult(fsmId, node,
      NodeResult(kind: resultFloatText, targetId: Bumper, text: "NICE SHOT!")).accepted
    check game.addEdge(fsmId, edgeOn(0, node, evHit)).accepted

    game.tick(hit(Bumper))
    check game.lampOf(20) == lampValue(lampFlashing)
    check game.lampOf(21) == lampValue(lampFlashing)
    check game.lampOf(22) == lampValue(lampOff)
    check game.cues == @[ViewCue(kind: cueKindBurst, componentId: Bumper)]
    check game.floatingMessages.len == 1
    if game.floatingMessages.len == 1:
      check game.floatingMessages[0].componentId == Bumper
      check game.floatingMessages[0].text == "NICE SHOT!"
      check game.floatingMessages[0].ticksLeft > 0

  test "one event advances every matching FSM once, in creation order":
    var game = Table()
    for sound in [cuePing, cueBell]:
      let fsmId = game.createFsm().id
      let node = game.addNode(fsmId).id
      check game.addResult(fsmId, node, soundResult(sound)).accepted
      check game.addEdge(fsmId, edgeOn(0, node, evHit)).accepted

    game.tick(hit(Bumper))
    check game.cues == @[
      ViewCue(kind: cueKindSound, sound: cuePing),
      ViewCue(kind: cueKindSound, sound: cueBell)]

  test "inside one FSM the first matching edge wins":
    var game = Table()
    let fsmId = game.createFsm().id
    let first = game.addScoreNode(fsmId, 1)
    let second = game.addScoreNode(fsmId, 100)
    check game.addEdge(fsmId, edgeOn(0, first, evHit)).accepted
    check game.addEdge(fsmId, edgeOn(0, second, evHit)).accepted

    game.tick(hit(Bumper))
    check game.score == 1

  test "an FSM advances at most once per event":
    var game = Table()
    let fsmId = game.createFsm().id
    let first = game.addScoreNode(fsmId, 1)
    let second = game.addScoreNode(fsmId, 100)
    check game.addEdge(fsmId, edgeOn(0, first, evHit)).accepted
    check game.addEdge(fsmId, edgeOn(first, second, evHit)).accepted

    game.tick(hit(Bumper))
    check game.score == 1
    game.tick(hit(Bumper))
    check game.score == 101

  test "a signal reaches other FSMs on the next tick, not the same tick":
    var game = Table()
    let sender = game.createFsm().id
    let raise3 = game.addNode(sender).id
    check game.addResult(sender, raise3, NodeResult(kind: resultSignal, amount: 3)).accepted
    check game.addEdge(sender, edgeOn(0, raise3, evHit)).accepted

    # The listener is created after the sender, so it is evaluated after the
    # signal was raised and would see it if signals were delivered at once.
    var onSignal3 = edgeOn(0, 1, evFsmSignal)
    onSignal3.value = 3
    discard game.addScoreRule(onSignal3, 10)
    var onSignal4 = edgeOn(0, 1, evFsmSignal)
    onSignal4.value = 4
    discard game.addScoreRule(onSignal4, 1000)

    game.events.add hit(Bumper)
    runRules(game)
    game.events.setLen(0)
    check game.score == 0
    check game.pendingEvents == @[Event(kind: evFsmSignal, value: 3)]

    game.tick()
    check game.score == 10
    game.tick()
    check game.score == 10

  test "a ball added by a rule on an event reaches other rules on the next tick":
    var game = Table()
    let adder = game.createFsm().id
    let added = game.addNode(adder).id
    check game.addResult(adder, added,
      NodeResult(kind: resultBallAction, ballAction: ballActionAdd)).accepted
    check game.addEdge(adder, edgeOn(0, added, evHit)).accepted
    discard game.addScoreRule(edgeOn(0, 1, evBallAdded), 100)

    # Two events in the tick: the first adds the ball while the second waits.
    game.tick(hit(Bumper), hit(OtherBumper))
    check game.balls.len == 2
    check game.score == 0
    game.tick()
    check game.score == 200

  test "a final node stops the FSM until it is reset, and a deleted FSM is gone":
    var game = Table()
    let fsmId = game.createFsm().id
    let once = game.addScoreNode(fsmId, 5)
    check game.setFinal(fsmId, once).accepted
    check game.addEdge(fsmId, edgeOn(0, once, evHit)).accepted

    game.tick(hit(Bumper))
    check game.score == 5
    game.tick(hit(Bumper))
    game.tick(hit(Bumper))
    check game.score == 5

    check game.resetFsm(fsmId).accepted
    game.tick(hit(Bumper))
    check game.score == 10
    game.tick(hit(Bumper))
    check game.score == 10

    check game.resetFsm(fsmId).accepted
    check game.deleteFsm(fsmId).accepted
    check game.fsms.len == 0
    game.tick(hit(Bumper))
    check game.score == 10
    check game.deleteFsm(fsmId).reason == rejectUnknownTarget

  test "rules can subtract, and the score never goes below zero":
    var game = Table()
    discard game.addScoreRule(edgeOn(0, 1, evHit), 30)
    discard game.addScoreRule(edgeOn(0, 1, evRollover), -20)
    discard game.addScoreRule(edgeOn(0, 1, evSpin), -100)

    game.tick(hit(Bumper))
    game.tick(Event(kind: evRollover, componentId: 9))
    check game.score == 10
    game.tick(Event(kind: evSpin, componentId: 10))
    check game.score == 0
    # The floor leaves no hidden debt behind.
    game.tick(hit(Bumper))
    check game.score == 30

  test "rule firings count how often each node was entered":
    var game = Table()
    let fsmId = game.addScoreRule(edgeOn(0, 1, evHit), 5)
    for _ in 1 .. 3:
      game.tick(hit(Bumper))

    var entries = 0
    var count = 0'i32
    for firing in game.ruleFirings:
      if firing.fsmId == fsmId and firing.nodeIndex == 1:
        inc entries
        count += firing.count
    check entries == 1
    check count == 3

suite "the quest of Figure 2":
  const
    BankA = 1'i32
    DropTargets = [1'i32, 2, 3]
    RampLamp = 4'i32
    TrackR = 5'i32
    QuestTimeoutTicks = 20 * TicksPerSecond

  proc questGame(): Table =
    for id in DropTargets:
      result.addPiece(id, ckDropTarget, group = BankA)
    result.addPiece(RampLamp, ckInsert)
    result.addPiece(TrackR, ckTrack)

    let resetBankA = NodeResult(kind: resultEdit,
                                edit: Edit(kind: editReset, targetGroup: BankA))
    let fsmId = result.createFsm().id

    let bankDown = result.addNode(fsmId).id
    check result.addResult(fsmId, bankDown,
      NodeResult(kind: resultLamp, targetId: RampLamp, lamp: lampOn)).accepted
    check result.addResult(fsmId, bankDown,
      NodeResult(kind: resultPanelText, slot: slotQuest, text: "RAMP IS LIT")).accepted

    let jackpot = result.addNode(fsmId).id
    check result.addResult(fsmId, jackpot, scoreResult(50_000)).accepted
    check result.addResult(fsmId, jackpot, NodeResult(kind: resultFlashers)).accepted
    check result.addResult(fsmId, jackpot, soundResult(cueFanfare)).accepted
    check result.addResult(fsmId, jackpot, resetBankA).accepted

    let missed = result.addNode(fsmId).id
    check result.addResult(fsmId, missed,
      NodeResult(kind: resultLamp, targetId: RampLamp, lamp: lampOff)).accepted
    check result.addResult(fsmId, missed,
      NodeResult(kind: resultPanelText, slot: slotAward, text: "TOO SLOW")).accepted
    check result.addResult(fsmId, missed, resetBankA).accepted

    var bankDrops = edgeOn(0, bankDown, evDrop)
    bankDrops.group = BankA
    bankDrops.count = 3
    check result.addEdge(fsmId, bankDrops).accepted
    var trackCompleted = edgeOn(bankDown, jackpot, evTrackCompleted)
    trackCompleted.componentId = TrackR
    check result.addEdge(fsmId, trackCompleted).accepted
    check result.addEdge(fsmId, timeoutEdge(bankDown, missed, QuestTimeoutTicks)).accepted

  proc dropBankA(game: var Table) =
    for id in DropTargets:
      game.tick(Event(kind: evDrop, componentId: id, group: BankA, level: 1))

  let trackRCompleted = Event(kind: evTrackCompleted, componentId: TrackR)

  test "the ramp shot in time pays the jackpot":
    var game = questGame()

    # The ramp is worth nothing before the bank is down.
    game.tick(trackRCompleted)
    check game.score == 0

    game.dropBankA()
    check game.lampOf(RampLamp) == lampValue(lampOn)
    check game.questText == "RAMP IS LIT"
    check game.score == 0

    game.ticks(QuestTimeoutTicks div 2)
    game.tick(trackRCompleted)
    check game.score == 50_000
    check game.scoreChanges == @[ScoreChange(amount: 50_000, componentId: TrackR)]
    check game.cues == @[
      ViewCue(kind: cueKindFlashers),
      ViewCue(kind: cueKindSound, sound: cueFanfare)]

    # The quest is over: the timeout of "Bank down" no longer applies and a
    # second ramp shot pays nothing.
    game.ticks(QuestTimeoutTicks + 2)
    game.tick(trackRCompleted)
    check game.score == 50_000
    check game.awardText == ""

    # It can be played again from the start.
    game.dropBankA()
    game.tick(trackRCompleted)
    check game.score == 100_000

  test "taking too long loses the quest":
    var game = questGame()
    game.dropBankA()

    game.ticks(QuestTimeoutTicks - 2)
    check game.lampOf(RampLamp) == lampValue(lampOn)
    check game.awardText == ""

    game.ticks(3)
    check game.lampOf(RampLamp) == lampValue(lampOff)
    check game.awardText == "TOO SLOW"
    check game.questText == "RAMP IS LIT"

    game.tick(trackRCompleted)
    check game.score == 0

suite "rule limits and validation":

  test "a table holds at most 32 FSMs":
    var game = Table()
    for _ in 1 .. MaxFsms:
      check game.createFsm().accepted
    check game.createFsm().reason == rejectLimit
    check game.fsms.len == MaxFsms

  test "FSM ids are not reused":
    var game = Table()
    let first = game.createFsm().id
    let second = game.createFsm().id
    check first != second
    check game.deleteFsm(second).accepted
    check game.createFsm().id notin [first, second]

  test "an FSM holds at most 64 nodes and 64 edges":
    var game = Table()
    let fsmId = game.createFsm().id
    for expectedIndex in 1 ..< MaxNodesPerFsm:
      let outcome = game.addNode(fsmId)
      check outcome.accepted
      check outcome.id == expectedIndex
    check game.addNode(fsmId).reason == rejectLimit

    for _ in 1 .. MaxEdgesPerFsm:
      check game.addEdge(fsmId, edgeOn(0, 1, evHit)).accepted
    check game.addEdge(fsmId, edgeOn(0, 1, evHit)).reason == rejectLimit

  test "unknown FSMs and nodes are rejected":
    var game = Table()
    let fsmId = game.createFsm().id
    let node = game.addNode(fsmId).id
    let unknownFsm = fsmId + 50
    let unknownNode = node + 1

    check game.deleteFsm(unknownFsm).reason == rejectUnknownTarget
    check game.resetFsm(unknownFsm).reason == rejectUnknownTarget
    check game.addNode(unknownFsm).reason == rejectUnknownTarget
    check game.addEdge(unknownFsm, edgeOn(0, 0, evHit)).reason == rejectUnknownTarget
    check game.addResult(unknownFsm, 0, scoreResult(5)).reason == rejectUnknownTarget
    check game.setFinal(unknownFsm, 0).reason == rejectUnknownTarget

    check game.addEdge(fsmId, edgeOn(0, unknownNode, evHit)).reason == rejectUnknownTarget
    check game.addEdge(fsmId, edgeOn(unknownNode, 0, evHit)).reason == rejectUnknownTarget
    check game.addEdge(fsmId, edgeOn(-1, 0, evHit)).reason == rejectUnknownTarget
    check game.addResult(fsmId, unknownNode, scoreResult(5)).reason == rejectUnknownTarget
    check game.setFinal(fsmId, unknownNode).reason == rejectUnknownTarget

  test "values outside their limits are rejected":
    var game = Table()
    let fsmId = game.createFsm().id
    let node = game.addNode(fsmId).id

    for count in [0'i32, MaxEdgeCount + 1]:
      var edge = edgeOn(0, node, evHit)
      edge.count = count
      check game.addEdge(fsmId, edge).reason == rejectBadValue
    var lastCount = edgeOn(0, node, evHit)
    lastCount.count = MaxEdgeCount
    check game.addEdge(fsmId, lastCount).accepted

    check game.addResult(fsmId, node, scoreResult(MaxScoreChange)).accepted
    check game.addResult(fsmId, node, scoreResult(-MaxScoreChange)).accepted
    check game.addResult(fsmId, node, scoreResult(MaxScoreChange + 1)).reason == rejectBadValue
    check game.addResult(fsmId, node, scoreResult(-MaxScoreChange - 1)).reason == rejectBadValue

    proc signal(number: int32): NodeResult =
      NodeResult(kind: resultSignal, amount: number)
    check game.addResult(fsmId, node, signal(0)).accepted
    check game.addResult(fsmId, node, signal(SignalCount - 1)).accepted
    check game.addResult(fsmId, node, signal(SignalCount)).reason == rejectBadValue
    check game.addResult(fsmId, node, signal(-1)).reason == rejectBadValue

  test "text must be short and use capitals, digits and basic punctuation":
    var game = Table()
    let fsmId = game.createFsm().id
    let node = game.addNode(fsmId).id

    proc panelText(text: string): NodeResult =
      NodeResult(kind: resultPanelText, slot: slotAward, text: text)
    proc floatText(text: string): NodeResult =
      NodeResult(kind: resultFloatText, targetId: Bumper, text: text)

    check game.addResult(fsmId, node, panelText("JACKPOT! +50,000.")).accepted
    check game.addResult(fsmId, node, panelText(repeat('A', MaxTextLength))).accepted
    check game.addResult(fsmId, node, panelText(repeat('A', MaxTextLength + 1))).reason == rejectBadValue
    check game.addResult(fsmId, node, panelText("Ramp is lit")).reason == rejectBadValue
    check game.addResult(fsmId, node, panelText("TWO\nLINES")).reason == rejectBadValue
    check game.addResult(fsmId, node, floatText(repeat('A', MaxTextLength + 1))).reason == rejectBadValue
    check game.addResult(fsmId, node, floatText("nice")).reason == rejectBadValue
