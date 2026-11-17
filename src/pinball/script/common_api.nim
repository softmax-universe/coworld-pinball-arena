## What both seats get besides the view: the named constants and the maths.
## Bassy has no built-in maths or random numbers, so the host supplies them,
## all on fixxy integer maths so that every machine gets the same answers.

import std/strutils
import bassy
import ../sim/[simulation, geometry]
import ../../polyworld/rngs
import base

proc addConstants(host: var Host, T: typedesc[enum], prefix, enumPrefix: string) =
  ## One constant per enum value, named from the Nim name: `ckPopBumper`
  ## becomes `kind_popbumper`.
  for value in low(T) .. high(T):
    let name = ($value)[enumPrefix.len .. ^1].toLowerAscii
    discard host.addData(prefix & name, int32(ord(value)))

proc addAllConstants*(host: var Host) =
  host.addConstants(ComponentKind, "kind_", "ck")
  host.addConstants(EventKind, "ev_", "ev")
  host.addConstants(Setting, "set_", "set")
  host.addConstants(SoundCue, "cue_", "cue")
  host.addConstants(LampState, "lamp_", "lamp")
  host.addConstants(LampColour, "colour_", "colour")
  host.addConstants(PanelSlot, "slot_", "slot")
  host.addConstants(NudgeDirection, "nudge_", "nudge")
  # For reading the view and the outcome of a call.
  host.addConstants(RejectReason, "reject_", "reject")
  host.addConstants(BallState, "state_", "ball")
  host.addConstants(ComponentPhase, "phase_", "phase")
  discard host.addData("left", int32(ord(flipperLeft)))
  discard host.addData("right", int32(ord(flipperRight)))

proc bothIntegers(args: openArray[Value]): bool =
  args[0].kind == IntegerValue and args[1].kind == IntegerValue

proc addMaths*(host: var Host, script: Script) =
  ## A whole number stays a whole number through `abs`, `min`, `max` and
  ## `floor`, so scores above the fixed-point range survive them.
  host.call("abs", 1):
    if args[0].kind == IntegerValue:
      toValue(int32(min(abs(int64(args[0].asInt)), int64(high(int32)))))
    else:
      toValue(abs(args[0].asFixed))

  host.call("min", 2):
    if bothIntegers(args): toValue(min(args[0].asInt, args[1].asInt))
    else: toValue(min(args[0].asFixed, args[1].asFixed))

  host.call("max", 2):
    if bothIntegers(args): toValue(max(args[0].asInt, args[1].asInt))
    else: toValue(max(args[0].asFixed, args[1].asFixed))

  host.call("floor", 1):
    if args[0].kind == IntegerValue: args[0]
    else: toValue(toInt(floor(args[0].asFixed)))

  host.call("sqrt", 1):
    let value = args[0].asFixed
    if value < 0'fx:
      raise newException(BasicError, "sqrt of a negative number")
    fixxy.sqrt(value)

  # The angle is brought into one turn first: the product of a large angle
  # and pi would wrap.
  host.call("sin", 1):
    fixxy.sin(radians(floorMod(args[0].asFixed, 360'fx)))

  host.call("cos", 1):
    fixxy.cos(radians(floorMod(args[0].asFixed, 360'fx)))

  host.call("atan2", 2):
    arctan2(args[0].asFixed, args[1].asFixed) * 180'i32 / FixedPi

  host.call("rnd", 1):
    script.rng.below(args[0].asInt)
