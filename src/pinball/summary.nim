## What the game tells the cogent about a table program: the summary of an
## Episode, and the description of a program failure. Both are JSON for the
## page, which passes them on (design section 7).

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
