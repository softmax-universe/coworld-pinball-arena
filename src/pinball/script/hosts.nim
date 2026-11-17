## The two BASIC hosts: one lets a program play the Arena seat (build the
## table and its rules) and one lets a program play the Flipper seat.
##
## A program runs from the top once per decision with a fresh instruction
## budget, and its variables persist between decisions. Before each decision
## the host fills the program's read-only view of the table. A call that
## changes the table becomes a `Command` that is applied at once through
## `simulation.apply`, and the call returns the outcome to the program: a
## positive id or index (or 1) when accepted, and `-ord(RejectReason)` when
## rejected.
##
## The view records are declared in a BASIC prelude that the host puts in
## front of the author's source, so the line numbers of errors are corrected
## back to the author's own lines.
##
## A program that fails at run time or overruns its budget never runs again.
## For the Arena seat the table then stays as it is and its rules keep
## running. For the Flipper seat the flippers go limp.
##
## The modules: `base` has the `Script` type and `give`, the one place where
## a call becomes a command. `view` fills what a program sees. `common_api`,
## `flipper_api` and `arena_api` hold the BASIC calls. `README.md` is the
## reference of the whole BASIC interface.

import std/[parseutils, strutils]
import bassy
import ../sim/simulation
import ../../polyworld/rngs
import base, view, common_api, flipper_api, arena_api

export simulation
export ScriptStatus, Script

const
  # Starting values, taken from the range that the Polyworld games use.
  ArenaInstructionBudget* = 200_000    ## Per decision.
  FlipperInstructionBudget* = 50_000   ## Per decision.
  ScriptMemoryBytes* = 2 * 1024 * 1024
  MaxSourceBytes* = 256 * 1024
  KeptOutputLines* = 16
    ## How many printed lines a script keeps. They go into the Episode
    ## summary next to a script error.

  WorkPerInstruction = 20
    ## Bassy also meters "work": an instruction is one unit, a host call is
    ## 16 more, and string operations cost their length. The instruction
    ## budget is the one authors are told about, so the work budget is set
    ## where a program of host calls alone does not reach it first.
  PrintBytesPerDecision = 2048
  PrintEventsPerDecision = 256
  BudgetMessages = ["BASIC instruction limit exceeded", "BASIC work limit exceeded"]
    ## Bassy raises one error type for everything, so an overrun is told from
    ## a bug in the program by these exact messages.

proc limitsFor(seat: Seat): Limits =
  result = defaultLimits()
  result.maxSourceBytes = MaxSourceBytes + Prelude.len
  result.maxInstructions =
    if seat == seatArena: ArenaInstructionBudget else: FlipperInstructionBudget
  result.maxWorkUnits = result.maxInstructions * WorkPerInstruction
  result.maxMemoryBytes = ScriptMemoryBytes
  result.maxPrintBytes = PrintBytesPerDecision
  result.maxPrintEvents = PrintEventsPerDecision

proc withAuthorLine(message: string): string =
  ## Bassy reports a position as "line L, column C: ..." counted from the top
  ## of the prelude. Give the line in the author's own source.
  const Start = "line "
  var line: int
  if not message.startsWith(Start):
    return message
  let digits = parseInt(message, line, Start.len)
  if digits == 0:
    return message
  Start & $(line - PreludeLines) & message[Start.len + digits .. ^1]

proc loadScript*(seat: Seat, source: string): Script =
  ## Compiles a program for a seat. A compile error gives a Script with
  ## `scriptCompileError`.
  let script = Script(seat: seat, rng: initRng(int32(ord(seat)) + 1))
  if source.len > MaxSourceBytes:
    script.status = scriptCompileError
    script.error = "the program is " & $source.len & " bytes long and the limit is " &
      $MaxSourceBytes
    return script

  var host = initHost()
  for (name, value) in viewNumbers(Table(), seat):
    discard host.addData(name, value)
  host.addAllConstants()
  host.addMaths(script)
  case seat
  of seatFlipper: host.addFlipperCalls(script)
  of seatArena: host.addArenaCalls(script)

  let limits = limitsFor(seat)
  try:
    script.runtime = initRuntime(compile(Prelude & source, host, limits), host, limits)
  except BasicError as error:
    script.status = scriptCompileError
    script.error = withAuthorLine(error.msg)
  script

proc keepLine(script: Script) =
  script.output.add script.openLine
  script.openLine = ""
  if script.output.len > KeptOutputLines:
    script.output.delete(0)

proc keepPrint(script: Script, event: PrintEvent) =
  case event.kind
  of TextPrint, FixedPrint: script.openLine.add event.text
  of ValuePrint: script.openLine.add $event.value
  of NewlinePrint: script.keepLine()

proc decide*(script: Script, table: var Table) =
  ## Runs the program once from the top. Its calls are applied to the table
  ## at once through `simulation.apply`. Does nothing unless the status is
  ## `scriptRunning`.
  ##
  ## A Flipper program that fails here releases both flippers and the
  ## plunger, and those releases are listed in `issued` like any command.
  script.issued.setLen 0
  if script.status != scriptRunning:
    return
  script.table = addr table
  script.runtime.restart()
  script.fillView(table)
  try:
    discard script.runtime.run(proc(event: PrintEvent) = script.keepPrint(event))
  except BasicError as error:
    script.status = if error.msg in BudgetMessages: scriptOverBudget else: scriptFailed
    script.error = error.msg
    if script.seat == seatFlipper:
      script.goLimp()
  if script.openLine.len > 0:
    script.keepLine()   # A line that the program left without its newline.
  script.table = nil
