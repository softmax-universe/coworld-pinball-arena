## The two entry points of the simulation: `apply` takes a command from a
## player, and `step` advances the table by one tick. Everything else in
## `sim/` is called from here.

import ../../polyworld/hashes
import types, physics, components, editing, tracks, episode, rules

export types

proc initTable*(settings = DefaultSettings): Table =
  ## An empty table at the start of the build phase of a new Episode.
  result.settings = settings
  result.phase = episodeBuild
  result.nextBallId = 1
  result.nextComponentId = 1
  result.nextFsmId = 1

proc mayGive(seat: Seat, kind: CommandKind): bool =
  case kind
  of cmdFlipper, cmdPlunger, cmdNudge: seat == seatFlipper
  else: seat == seatArena

proc apply*(table: var Table, command: Command): CommandOutcome =
  ## Carry out one command now. A rejected command changes nothing.
  if table.phase == episodeOver or not mayGive(command.seat, command.kind):
    return CommandOutcome(reason: rejectNotAllowed)
  case command.kind
  of cmdFlipper:
    table.setFlipper(command.side, command.pressed)
  of cmdPlunger:
    table.setPlunger(command.pressed)
  of cmdNudge:
    table.nudge(command.direction)
  of cmdEdit:
    result = table.applyEdit(command.edit, rateLimited = true)
  of cmdFsmCreate:
    result = table.createFsm()
  of cmdFsmDelete:
    result = table.deleteFsm(command.fsmId)
  of cmdFsmReset:
    result = table.resetFsm(command.fsmId)
  of cmdFsmAddNode:
    result = table.addNode(command.fsmId)
  of cmdFsmAddEdge:
    result = table.addEdge(command.fsmId, command.edge)
  of cmdFsmAddResult:
    result = table.addResult(command.fsmId, command.nodeIndex, command.result)
  of cmdFsmSetFinal:
    result = table.setFinal(command.fsmId, command.nodeIndex)
  of cmdSignal:
    if command.signal notin 0 ..< SignalCount:
      return CommandOutcome(reason: rejectUnknownTarget)
    table.emitNext Event(kind: evScriptSignal, value: command.signal)
  of cmdClearArena:
    table.clearArena()
    table.fsms.setLen 0

proc step*(table: var Table) =
  ## Advance the table by one tick (1/120 s). After `step` returns,
  ## `table.events`, `table.cues` and `table.scoreChanges` hold what happened
  ## during the tick, for the view and the Episode summary.
  table.events = move table.pendingEvents
  table.pendingEvents = @[]
  table.cues.setLen 0
  table.scoreChanges.setLen 0
  table.contacts.setLen 0
  if table.phase == episodeOver:
    return

  table.advanceEpisode()
  table.advanceBeamIns()
  table.applyForces()
  table.stepPhysics()
  table.stepTracks()
  table.resolveContacts()
  table.advanceComponents()
  table.runRules()
  inc table.tick

proc stateHash*(table: Table): uint64 =
  ## A hash of the whole table. A replay checks it after every tick.
  uint64(hashy(table))
