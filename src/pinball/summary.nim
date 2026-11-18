## What the game tells the page, and through it the clients of the game API,
## as JSON: the summary of an Episode, the description of a program failure,
## the table as it is now, and the events of a tick.

import std/[json, math, strutils]
import sim/simulation
import script/hosts

proc word(value: enum, prefix: string): string =
  ## The name of an enum value as a word for the cogent: `rejectKeepOut`
  ## without its prefix is `keepOut`.
  result = ($value)[prefix.len .. ^1]
  result[0] = result[0].toLowerAscii

proc seconds(ticks: SomeInteger): float =
  round(float(ticks) / TicksPerSecond, 1)

proc scriptErrorJson*(script: Script): JsonNode =
  ## Null for a program that is running. Otherwise where it failed, the
  ## message, and the last lines it printed.
  let stage =
    case script.status
    of scriptRunning: return newJNull()
    of scriptCompileError: "compile"
    of scriptFailed: "run"
    of scriptOverBudget: "budget"
  %*{"stage": stage, "message": script.error, "output": script.output}

proc episodeSummary*(table: Table, programName: string, programVersion: int,
                     arena: Script): JsonNode =
  ## The summary of the Episode that this table has just finished, for the
  ## program that held the Arena seat at the end.
  ##
  ## The hit counts are read from the pieces that are on the table now, so a
  ## piece that was deleted during the Episode is not listed.
  var balls, components, rules, rejectedEdits = newJArray()
  for ticks in table.ballTicks:
    balls.add %*{"seconds": seconds(ticks)}
  for component in table.components:
    if component.hitCount > 0:
      components.add %*{
        "id": component.id,
        "kind": word(component.kind, "ck").toLowerAscii,   # As in BASIC: `kind_popbumper`.
        "group": component.group,
        "hits": component.hitCount}
  for firing in table.ruleFirings:
    rules.add %*{"fsm": firing.fsmId, "node": firing.nodeIndex, "count": firing.count}
  for rejected in table.rejectedEdits:
    rejectedEdits.add %*{
      "second": seconds(rejected.tick),
      "reason": word(rejected.reason, "reject"),
      "edit": word(rejected.edit.kind, "edit")}
  %*{
    "program": {"name": programName, "version": programVersion},
    "score": table.score,
    "endReason": word(table.endReason, "end"),
    "balls": balls,
    "components": components,
    "rules": rules,
    "rejectedEdits": rejectedEdits,
    "scriptError": scriptErrorJson(arena)}

proc number(value: Fixed): float =
  ## Millimetres, mm/s and degrees to three places.
  round(float(toFloat32(value)), 3)

proc tableState*(table: Table): JsonNode =
  ## The table as it is now. It holds what a BASIC program sees in its view
  ## (`script/README.md`), under the same names with the constants as words,
  ## and also the two messages of the side panel and the current node of
  ## every FSM.
  var balls, pieces, fsms = newJArray()
  for ball in table.balls:
    balls.add %*{
      "id": ball.id, "x": number(ball.pos.x), "y": number(ball.pos.y),
      "vx": number(ball.vel.x), "vy": number(ball.vel.y),
      "level": ball.level, "state": word(ball.state, "ball").toLowerAscii}
  for piece in table.components:
    if piece.phase == phaseFadingOut and not piece.hasPendingMove:
      continue   # Deleted and still fading out, as in the BASIC view.
    pieces.add %*{
      "id": piece.id, "kind": word(piece.kind, "ck").toLowerAscii,
      "x": number(piece.pos.x), "y": number(piece.pos.y),
      "rotation": number(piece.rotation), "size": piece.sizePercent,
      "level": piece.level, "group": piece.group,
      "phase": word(piece.phase, "phase").toLowerAscii,
      "lamp": word(LampState(toInt(piece.settings[setLamp])), "lamp").toLowerAscii,
      "down": piece.isDown, "face": piece.face, "hits": piece.hitCount}
  for fsm in table.fsms:
    fsms.add %*{"id": fsm.id, "node": fsm.currentNode, "nodes": fsm.nodes.len,
                "stopped": fsm.stopped}
  const PhaseNames: array[EpisodePhase, string] = ["build", "play", "over"]
  %*{
    "tick": table.tick,
    "phase": PhaseNames[table.phase],
    "ballNumber": table.ballNumber,
    "score": table.score,
    "clockSeconds": max(EpisodeClockTicks - table.clockTicks, 0) div TicksPerSecond,
    "quest": table.questText,
    "award": table.awardText,
    "ballSaveActive": table.ballSaveTicks > 0,
    "tiltWarnings": table.tiltWarnings,
    "tilted": table.tilted,
    "budgetLeft": table.settings.buildBudget - table.budgetUsed,
    "rejectCount": table.rejectedEdits.len,
    "flippers": {
      "left": {"pressed": table.flippers[flipperLeft].pressed,
               "angle": number(table.flippers[flipperLeft].angle)},
      "right": {"pressed": table.flippers[flipperRight].pressed,
                "angle": number(table.flippers[flipperRight].angle)}},
    "plunger": {"pressed": table.plunger.pressed, "pull": number(table.plunger.pull)},
    "balls": balls,
    "pieces": pieces,
    "fsms": fsms}

proc eventsJson*(table: Table): JsonNode =
  ## The events of the tick that has just run. `kind` is the name of the
  ## `ev_` constant without its prefix. The other fields are there when they
  ## are not 0.
  result = newJArray()
  for event in table.events:
    let node = %*{"kind": word(event.kind, "ev").toLowerAscii, "value": event.value}
    if event.componentId != 0: node["component"] = %event.componentId
    if event.group != 0: node["group"] = %event.group
    if event.level != 0: node["level"] = %event.level
    if event.ballId != 0: node["ball"] = %event.ballId
    if event.strength != 0'fx: node["strength"] = %number(event.strength)
    result.add node
