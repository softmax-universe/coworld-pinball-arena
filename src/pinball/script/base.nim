## What the modules of this folder share: the `Script` type, the one place
## where a BASIC call becomes a command, and the conversions from BASIC
## values that the calls need.

import bassy
import ../sim/simulation
import ../../polyworld/rngs

type
  ScriptStatus* = enum
    scriptRunning, scriptCompileError, scriptFailed, scriptOverBudget

  Script* = ref object
    seat*: Seat
    status*: ScriptStatus
    error*: string            ## The message, with line numbers that match the author's source.
    output*: seq[string]
      ## The last lines the program printed, oldest first, over all its
      ## decisions. At most `KeptOutputLines`.
    issued*: seq[Command]
      ## The commands the program gave during the latest decision, in order,
      ## rejected ones included. A replay applies them all: a rejected edit
      ## is logged in the table, so leaving it out would change the state hash.

    # The rest is for the modules of this folder.
    runtime*: Runtime
    table*: ptr Table
      ## The table of the decision that is running, and nil between
      ## decisions. The host calls are closures made when the program is
      ## loaded, and a closure cannot capture the `var Table` of `decide`.
    rng*: Rng                 ## For `rnd`.
    openLine*: string         ## Printed text that has not had its newline yet.

proc give*(script: Script, command: Command): int32 =
  ## Apply a command for the script's seat now, record it, and turn the
  ## outcome into what the BASIC call returns: the new id or index (or 1)
  ## when accepted, and `-ord(RejectReason)` when rejected.
  var command = command
  command.seat = script.seat
  command.tick = script.table.tick
  let outcome = script.table[].apply(command)
  script.issued.add command
  if outcome.accepted: max(outcome.id, 1) else: -int32(ord(outcome.reason))

template call*(host: var Host, name: string, argumentCount: int, body: untyped) =
  ## Registers one BASIC function. `body` sees the arguments as `args` and
  ## gives the value the call returns.
  discard host.addFunction(name, argumentCount,
    proc(args {.inject.}: openArray[Value]): Value = body)

proc toEnum*[T: enum](value: Value): T =
  ## A number outside the enum is a bug in the program, and no command can
  ## carry it, so it stops the program like any run-time error.
  let number = value.asInt
  if number < ord(low(T)) or number > ord(high(T)):
    raise newException(BasicError, $number & " is not a " & $T)
  T(number)

proc toTicks*(seconds: Value): int32 =
  ## Seconds may have a fraction. The product is formed in 64 bits because
  ## the 480 seconds of an Episode times 120 would wrap a `Fixed`.
  int32(int64(int32(seconds.asFixed)) * TicksPerSecond div FixedScale)
