## The read-only view of the table that a program gets before each decision:
## named numbers, and the `balls` and `pieces` record arrays that the BASIC
## prelude declares.

import std/strutils
import bassy
import ../sim/simulation
import base

const
  ViewPieces* = 128   ## The length of `pieces`. The default piece cap of a table.
  Prelude* = staticRead("view.bas") &
    "dim balls(" & $(MaxBallsInPlay - 1) & ") as BallView\n" &
    "dim pieces(" & $(ViewPieces - 1) & ") as PieceView\n"
  PreludeLines* = Prelude.count('\n')
    ## How far the prelude pushes the author's line numbers down.

proc isShown(piece: Component): bool =
  ## A deleted piece that is still fading out is left out: it touches nothing
  ## and no edit can name it.
  not (piece.phase == phaseFadingOut and not piece.hasPendingMove)

proc shownPieceCount(table: Table): int32 =
  for piece in table.components:
    if piece.isShown and result < ViewPieces:
      inc result

proc flag(value: bool): int32 =
  ## Flags are 1 and 0, so `if tilted then` and `tilted = 0` both read well.
  int32(ord(value))

proc viewNumbers*(table: Table, seat: Seat): seq[(string, Value)] =
  ## Every named number of the view with its value now. The names are
  ## registered from this same list when a program is loaded, so the two
  ## cannot drift apart.
  template number(name: string, value: untyped) =
    result.add (name, toValue(value))

  let ticksLeft = max(EpisodeClockTicks - table.clockTicks, 0)
  number "tick", int32(min(int64(table.tick), int64(high(int32))))
  number "phase", int32(ord(table.phase))
  number "ballnumber", table.ballNumber
  number "score", int32(clamp(table.score, 0'i64, int64(high(int32))))
  number "clockseconds", int32(ticksLeft div TicksPerSecond)
  number "ballcount", int32(min(table.balls.len, MaxBallsInPlay))
  number "piececount", table.shownPieceCount
  number "leftangle", table.flippers[flipperLeft].angle
  number "rightangle", table.flippers[flipperRight].angle
  number "leftpressed", flag(table.flippers[flipperLeft].pressed)
  number "rightpressed", flag(table.flippers[flipperRight].pressed)
  number "plungerpull", table.plunger.pull
  number "tiltwarnings", table.tiltWarnings
  number "tilted", flag(table.tilted)
  if seat == seatArena:
    number "budgetleft", table.settings.buildBudget - table.budgetUsed
    number "fsmcount", int32(table.fsms.len)
    number "rejectcount", int32(min(table.rejectedEdits.len, int(high(int32))))
    number "lastreject",
      (if table.rejectedEdits.len > 0: int32(ord(table.rejectedEdits[^1].reason)) else: 0'i32)

proc fillView*(script: Script, table: Table) =
  ## Entries of `balls` and `pieces` past the counts keep whatever they held.
  for (name, value) in viewNumbers(table, script.seat):
    script.runtime.setData(name, value)

  for index in 0'i32 ..< int32(min(table.balls.len, MaxBallsInPlay)):
    let ball = table.balls[index]
    script.runtime.setArray("balls.id", index, ball.id)
    script.runtime.setArray("balls.x", index, ball.pos.x)
    script.runtime.setArray("balls.y", index, ball.pos.y)
    script.runtime.setArray("balls.vx", index, ball.vel.x)
    script.runtime.setArray("balls.vy", index, ball.vel.y)
    script.runtime.setArray("balls.level", index, ball.level)
    script.runtime.setArray("balls.state", index, int32(ord(ball.state)))

  var index = 0'i32
  for piece in table.components:
    if not piece.isShown or index >= ViewPieces:
      continue
    script.runtime.setArray("pieces.id", index, piece.id)
    script.runtime.setArray("pieces.kind", index, int32(ord(piece.kind)))
    script.runtime.setArray("pieces.x", index, piece.pos.x)
    script.runtime.setArray("pieces.y", index, piece.pos.y)
    script.runtime.setArray("pieces.rotation", index, piece.rotation)
    script.runtime.setArray("pieces.size", index, piece.sizePercent)
    script.runtime.setArray("pieces.level", index, piece.level)
    script.runtime.setArray("pieces.group", index, piece.group)
    script.runtime.setArray("pieces.phase", index, int32(ord(piece.phase)))
    script.runtime.setArray("pieces.lamp", index, toInt(piece.settings[setLamp]))
    script.runtime.setArray("pieces.down", index, flag(piece.isDown))
    script.runtime.setArray("pieces.face", index, piece.face)
    inc index
