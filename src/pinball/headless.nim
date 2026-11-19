## Plays one Episode with no window: a BASIC program in each seat, as fast as
## the machine goes. Prints the Episode summary as JSON and checks that the
## replay of the Episode matches. This is the way to try a table program
## without a browser.
##
##   nim r src/pinball/headless.nim [options]
##
##   --arena PATH     the Arena program (default: the bundled house program)
##   --flipper PATH   the Flipper program (default: the bundled demo program)
##   --record PATH    save the replay of the Episode
##   --replay PATH    check a saved replay instead of playing
##   --frames PATH   save a small JSON picture of the Episode for a viewer:
##                    the pieces, and the balls, flippers and score ten times
##                    a second (the Coworld game server uses it as its replay)
##
## The exit code is 1 when a program does not compile or a replay does not
## match.

import std/[json, math, os, strutils]
import game
import sim/catalogue

const
  Usage = "usage: headless [--arena PATH] [--flipper PATH] [--record PATH] [--replay PATH] [--frames PATH]"
  FrameTicks = TicksPerSecond div 10

type
  Options = object
    arenaPath, flipperPath, recordPath, replayPath, framesPath: string

proc readOptions(): Options =
  ## Every option takes one value, so the arguments come in pairs.
  let arguments = commandLineParams()
  if arguments.len mod 2 != 0:
    quit(Usage, 1)
  for index in countup(0, arguments.high, 2):
    let value = arguments[index + 1]
    case arguments[index]
    of "--arena": result.arenaPath = value
    of "--flipper": result.flipperPath = value
    of "--record": result.recordPath = value
    of "--replay": result.replayPath = value
    of "--frames": result.framesPath = value
    else: quit(Usage, 1)

proc checkReplay(recording: Replay) =
  if not recording.verify():
    quit("the replay does NOT match: the table differs from the recording", 1)
  stderr.writeLine "the replay matches (" & $recording.hashes.len & " ticks, " &
    $recording.commands.len & " commands)"

proc printMessages(game: Game) =
  ## The summary goes to standard output, and program errors to standard error.
  for message in game.takeMessages():
    let node = parseJson(message)
    case node["type"].getStr
    of "episode": echo node["summary"].pretty
    of "programError": stderr.writeLine node.pretty
    else: discard

proc loadedNoProgram(game: Game): bool =
  ## True when the program that was just sent did not compile. Prints why.
  for message in game.takeMessages():
    let node = parseJson(message)
    if node["type"].getStr == "programError":
      stderr.writeLine node.pretty
      result = true

proc rounded(value: Fixed): float =
  round(float(toFloat32(value)), 1)

proc tablePieces(table: Table): JsonNode =
  ## Where the pieces stand, for a viewer that draws them as plain shapes.
  ## `r` is the footprint radius, and `length` is there for a wall.
  result = newJArray()
  for piece in table.components:
    let node = %*{
      "kind": ($piece.kind)[2 .. ^1].toLowerAscii, "x": rounded(piece.pos.x), "y": rounded(piece.pos.y),
      "rotation": rounded(piece.rotation), "level": piece.level,
      "r": rounded(scaled(KindInfos[piece.kind].radius, piece.sizePercent))}
    if KindInfos[piece.kind].isLong:
      node["length"] = %rounded(scaled(piece.settings[setLength], piece.sizePercent))
    result.add node

proc tableFrame(table: Table): JsonNode =
  ## `[tick, score, ball number, left flipper angle, right flipper angle, [x, y, x, y, ...]]`
  var balls = newJArray()
  for ball in table.balls:
    balls.add %rounded(ball.pos.x)
    balls.add %rounded(ball.pos.y)
  %*[table.tick, table.score, table.ballNumber, rounded(table.flippers[flipperLeft].angle),
     rounded(table.flippers[flipperRight].angle), balls]

proc main() =
  let options = readOptions()
  if options.replayPath.len > 0:
    checkReplay(loadReplay(options.replayPath))
    return

  # Programs that arrive before the first tick play this Episode.
  let game = newGame(GameOptions(settings: DefaultSettings))
  if options.flipperPath.len > 0:
    game.receiveMessage $(%*{
      "type": "program",
      "seat": "flipper",
      "name": options.flipperPath.splitFile.name,
      "version": 1,
      "source": readFile(options.flipperPath)})
  else:
    game.receiveMessage $(%*{"type": "program", "seat": "flipper", "name": "demo"})
  if game.loadedNoProgram():
    quit(1)
  if options.arenaPath.len > 0:
    game.receiveMessage $(%*{
      "type": "program",
      "name": options.arenaPath.splitFile.name,
      "version": 1,
      "source": readFile(options.arenaPath)})
    if game.loadedNoProgram():
      quit(1)

  var pieces = newJArray()
  var frames = newJArray()
  while game.table.phase != episodeOver:
    game.tick()
    game.printMessages()
    if options.framesPath.len > 0 and game.table.phase == episodePlay:
      # The pieces as they stand when the first ball is served, which for a
      # table that does not change during play is how they stay.
      if pieces.len == 0:
        pieces = tablePieces(game.table)
      if game.table.tick mod FrameTicks == 0:
        frames.add tableFrame(game.table)
  if options.framesPath.len > 0:
    writeFile(options.framesPath, $(%*{
      "framesPerSecond": TicksPerSecond div FrameTicks, "pieces": pieces, "frames": frames}))

  let recording = game.replay()
  if options.recordPath.len > 0:
    recording.saveReplay(options.recordPath)
  checkReplay(recording)

main()
