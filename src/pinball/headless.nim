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
##
## The exit code is 1 when a program does not compile or a replay does not
## match.

import std/[json, os]
import game
import script/hosts

const Usage = "usage: headless [--arena PATH] [--flipper PATH] [--record PATH] [--replay PATH]"

type
  Options = object
    arenaPath, flipperPath, recordPath, replayPath: string

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

proc main() =
  let options = readOptions()
  if options.replayPath.len > 0:
    checkReplay(loadReplay(options.replayPath))
    return

  var gameOptions = GameOptions(settings: DefaultSettings, flipperMode: flipperDemo)
  if options.flipperPath.len > 0:
    gameOptions.flipperSource = readFile(options.flipperPath)
    # The game lets a broken Flipper program hang limp without a word.
    let flipper = loadScript(seatFlipper, gameOptions.flipperSource)
    if flipper.status == scriptCompileError:
      quit(options.flipperPath & ": " & flipper.error, 1)

  let game = newGame(gameOptions)
  if options.arenaPath.len > 0:
    # It arrives before the first tick, so it plays this Episode.
    game.receiveMessage $(%*{
      "type": "program",
      "name": options.arenaPath.splitFile.name,
      "version": 1,
      "source": readFile(options.arenaPath)})
    if game.loadedNoProgram():
      quit(1)

  while game.table.phase != episodeOver:
    game.tick()
    game.printMessages()

  let recording = game.replay()
  if options.recordPath.len > 0:
    recording.saveReplay(options.recordPath)
  checkReplay(recording)

main()
