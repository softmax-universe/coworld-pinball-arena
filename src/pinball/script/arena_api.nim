## The calls of the Arena seat: edit the pieces, build the rules.
##
## Each call makes one command (`track` makes several) and returns
## what `give` returns. The edits that a rule node can also make as a result
## (`docreate`, `domove`, ...) take the same arguments after the FSM and the
## node, so each of those edits is built by one small proc that both use.

import bassy
import ../sim/simulation
import base

# --- Edits -------------------------------------------------------------------

proc createEdit(args: openArray[Value]): Edit =
  ## kind, x, y, rotation, size, level, group
  Edit(kind: editCreate, componentKind: toEnum[ComponentKind](args[0]),
       pos: fixedVec2(args[1].asFixed, args[2].asFixed), rotation: args[3].asFixed,
       sizePercent: args[4].asInt, level: args[5].asInt, group: args[6].asInt)

proc moveEdit(args: openArray[Value]): Edit =
  ## id, x, y
  Edit(kind: editMove, targetId: args[0].asInt,
       pos: fixedVec2(args[1].asFixed, args[2].asFixed))

proc settingEdit(args: openArray[Value]): Edit =
  ## id, which, value
  Edit(kind: editSetting, targetId: args[0].asInt, setting: toEnum[Setting](args[1]),
       value: args[2].asFixed)

proc groupSettingEdit(args: openArray[Value]): Edit =
  ## group, which, value
  Edit(kind: editSetting, targetGroup: args[0].asInt, setting: toEnum[Setting](args[1]),
       value: args[2].asFixed)

proc giveEdit(script: Script, edit: Edit): int32 =
  script.give Command(kind: cmdEdit, edit: edit)

proc giveTrack(script: Script, args: openArray[Value]): int32 =
  ## moutha, mouthb, cax, cay, cbx, cby. A track is one piece and six
  ## settings, so this is seven commands. It stops at the first rejected one
  ## and returns its reason. A track piece made before that stays.
  const TrackSettings = [setMouthA, setMouthB, setControlAX, setControlAY,
                         setControlBX, setControlBY]
  var values: array[TrackSettings.len, Fixed]
  for index in 0 ..< values.len:
    values[index] = args[index].asFixed

  # A track has no place of its own: it runs between its mouths.
  result = script.giveEdit Edit(kind: editCreate, componentKind: ckTrack, sizePercent: 100, level: 1)
  if result < 0:
    return
  for index, setting in TrackSettings:
    let outcome = script.giveEdit Edit(kind: editSetting, targetId: result, setting: setting,
                                       value: values[index])
    if outcome < 0:
      return outcome

# --- Rules -------------------------------------------------------------------

proc eventEdge(args: openArray[Value]): Edge =
  ## fromnode, tonode, event, component, group, count, and for `edgex` also
  ## level, value, minstrength. The short form matches any level and value.
  result = Edge(fromNode: args[0].asInt, toNode: args[1].asInt,
                event: toEnum[EventKind](args[2]), componentId: args[3].asInt,
                group: args[4].asInt, count: args[5].asInt, value: -1)
  if args.len > 6:
    result.level = args[6].asInt
    result.value = args[7].asInt
    result.minStrength = args[8].asFixed

proc giveEdge(script: Script, fsm: Value, edge: Edge): int32 =
  script.give Command(kind: cmdFsmAddEdge, fsmId: fsm.asInt, edge: edge)

proc giveResult(script: Script, fsm, node: Value, nodeResult: NodeResult): int32 =
  script.give Command(kind: cmdFsmAddResult, fsmId: fsm.asInt, nodeIndex: node.asInt,
                      result: nodeResult)

proc currentNode(table: Table, fsmId: int32): int32 =
  let index = table.fsmIndex(fsmId)
  if index < 0: -1'i32 else: table.fsms[index].currentNode

proc addArenaCalls*(host: var Host, script: Script) =
  template rest: untyped = args.toOpenArray(1, args.high)      # After the FSM.
  template resultArgs: untyped = args.toOpenArray(2, args.high) # After the FSM and the node.

  # Pieces.
  host.call("create", 7): script.giveEdit createEdit(args)
  host.call("move", 3): script.giveEdit moveEdit(args)
  host.call("rotate", 2):
    script.giveEdit Edit(kind: editRotate, targetId: args[0].asInt, rotation: args[1].asFixed)
  host.call("resize", 2):
    script.giveEdit Edit(kind: editResize, targetId: args[0].asInt, sizePercent: args[1].asInt)
  host.call("remove", 1): script.giveEdit Edit(kind: editDelete, targetId: args[0].asInt)
  host.call("removegroup", 1): script.giveEdit Edit(kind: editDelete, targetGroup: args[0].asInt)
  host.call("setting", 3): script.giveEdit settingEdit(args)
  host.call("groupsetting", 3): script.giveEdit groupSettingEdit(args)
  host.call("reset", 1): script.giveEdit Edit(kind: editReset, targetId: args[0].asInt)
  host.call("resetgroup", 1): script.giveEdit Edit(kind: editReset, targetGroup: args[0].asInt)
  host.call("track", 6): script.giveTrack(args)

  # Rules: FSMs, their nodes and edges.
  host.call("fsm", 0): script.give Command(kind: cmdFsmCreate)
  host.call("node", 1): script.give Command(kind: cmdFsmAddNode, fsmId: args[0].asInt)
  host.call("edge", 7): script.giveEdge(args[0], eventEdge(rest))
  host.call("edgex", 10): script.giveEdge(args[0], eventEdge(rest))
  host.call("timeout", 4):
    script.giveEdge(args[0], Edge(fromNode: args[1].asInt, toNode: args[2].asInt,
                                  isTimeout: true, timeoutTicks: toTicks(args[3])))
  host.call("final", 2):
    script.give Command(kind: cmdFsmSetFinal, fsmId: args[0].asInt, nodeIndex: args[1].asInt)
  host.call("fsmreset", 1): script.give Command(kind: cmdFsmReset, fsmId: args[0].asInt)
  host.call("fsmremove", 1): script.give Command(kind: cmdFsmDelete, fsmId: args[0].asInt)
  host.call("signal", 1): script.give Command(kind: cmdSignal, signal: args[0].asInt)
  host.call("ready", 0): script.give Command(kind: cmdReady, pressed: true)
  host.call("fsmnode", 1): script.table[].currentNode(args[0].asInt)

  # Results of a node. Every one starts with the FSM and the node.
  template nodeResult(name: string, moreArguments: int, value: untyped) =
    host.call(name, 2 + moreArguments): script.giveResult(args[0], args[1], value)
  template editResult(name: string, moreArguments: int, value: untyped) =
    nodeResult name, moreArguments, NodeResult(kind: resultEdit, edit: value)

  nodeResult "doscore", 1, NodeResult(kind: resultScore, amount: args[2].asInt)
  nodeResult "dosound", 1, NodeResult(kind: resultSound, sound: toEnum[SoundCue](args[2]))
  nodeResult "dolamp", 2, NodeResult(kind: resultLamp, targetId: args[2].asInt,
                                     lamp: toEnum[LampState](args[3]))
  nodeResult "dolampgroup", 2, NodeResult(kind: resultLamp, targetGroup: args[2].asInt,
                                          lamp: toEnum[LampState](args[3]))
  nodeResult "doflash", 0, NodeResult(kind: resultFlashers)
  nodeResult "doburst", 1, NodeResult(kind: resultBurst, targetId: args[2].asInt)
  nodeResult "domessage", 2, NodeResult(kind: resultPanelText, slot: toEnum[PanelSlot](args[2]),
                                        text: script.runtime.getString(args[3]))
  nodeResult "dosignal", 1, NodeResult(kind: resultSignal, amount: args[2].asInt)

  editResult "docreate", 7, createEdit(resultArgs)
  editResult "domove", 3, moveEdit(resultArgs)
  editResult "doremove", 1, Edit(kind: editDelete, targetId: args[2].asInt)
  editResult "doremovegroup", 1, Edit(kind: editDelete, targetGroup: args[2].asInt)
  editResult "dosetting", 3, settingEdit(resultArgs)
  editResult "dogroupsetting", 3, groupSettingEdit(resultArgs)
  editResult "doreset", 1, Edit(kind: editReset, targetId: args[2].asInt)
  editResult "doresetgroup", 1, Edit(kind: editReset, targetGroup: args[2].asInt)

  nodeResult "doaddball", 0, NodeResult(kind: resultBallAction, ballAction: ballActionAdd)
  nodeResult "dorelease", 1, NodeResult(kind: resultBallAction, ballAction: ballActionRelease,
                                        targetId: args[2].asInt)
  nodeResult "dosave", 1, NodeResult(kind: resultBallAction, ballAction: ballActionSave,
                                     amount: toTicks(args[2]))
  nodeResult "doextraball", 0, NodeResult(kind: resultBallAction, ballAction: ballActionExtraBall)
