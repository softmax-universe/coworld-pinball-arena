## The game driver: one Episode after another on one table.
##
## The simulation in `sim/` only knows a table, commands and ticks. This
## module is everything around it that is still part of the game and not of
## the screen: which programs play the two seats, when a new table program
## takes effect, the replay recording, and the Episode summary. The view
## (window, drawing, sound, keyboard) and the web page sit on top of it and
## talk to it through the few procs below.
##
## The Arena seat is two fields of `Game`. `playing` is the program that
## holds the seat. `waiting` is the newest program that compiled and has not
## taken the seat yet. Every Episode starts by seating the waiting program
## (a restart makes the playing program wait again), and during an Episode a
## waiting program is seated when its `@effect` directive says.
##
## `replay.nim` has the recording and its check, and `summary.nim` the JSON
## of the Episode summary.

import std/[json, strutils]
import sim/simulation
import script/hosts
import replay, summary

export simulation, replay

const
  HouseName = "house"
  HouseSource = staticRead("../../players/house.bas")
  DemoFlipperSource = staticRead("../../players/demo_flipper.bas")
  DemoRestartTicks = 5 * TicksPerSecond
    ## In demo mode the score of a finished Episode stays up this long.

type
  FlipperMode* = enum
    flipperHuman   ## A person plays the flippers through `humanInput`.
    flipperDemo    ## The bundled demo Flipper program plays (attract mode).

  GameOptions* = object
    settings*: TableSettings   ## The editing limits and build-phase length of the table.
    flipperMode*: FlipperMode
    flipperSource*: string
      ## A BASIC program to play the flippers in demo mode in place of the
      ## bundled one. Empty for the bundled one.

  Effect = enum
    ## When a program takes the Arena seat. The values are the words of the
    ## `@effect` directive.
    effectNextEpisode = "next-episode"
    effectNextBall = "next-ball"
    effectNow = "now"

  Program = ref object
    ## A table program that compiled.
    name: string
    version: int
    source: string
    effect: Effect
    startsFromHouse: bool
      ## The bundled house program lays out its table first (`@table house`).
    arrivalTick: uint32        ## The tick of the Episode in which the page sent it.

  Game* = ref object
    table*: Table              ## The table of the current Episode.
    options: GameOptions
    outbox: seq[string]

    playing: Program           ## Holds the Arena seat. Nil before the first tick of a game.
    arena: Script              ## The running copy of `playing`, new for each Episode.
    waiting: Program           ## Takes the seat next, or nil.
    flipper: Script            ## The demo Flipper program, new for each Episode.

    commands: seq[Command]     ## The recording of the current Episode.
    hashes: seq[uint64]
    idleTicks: int             ## Ticks since the Episode ended.

# --- Programs ------------------------------------------------------------------

proc newProgram(name: string, version: int, source: string): Program =
  ## Reads the directives: comment lines at the top of the source, such as
  ## `' @effect now` and `' @table house`.
  result = Program(name: name, version: version, source: source)
  for line in source.splitLines():
    let text = line.strip()
    if text.len == 0:
      continue
    if not text.startsWith("'"):
      break
    let words = text[1 .. ^1].toLowerAscii.splitWhitespace()
    if words.len != 2:
      continue
    case words[0]
    of "@effect": result.effect = parseEnum(words[1], effectNextEpisode)
    of "@table": result.startsFromHouse = words[1] == HouseName
    else: discard

proc send(game: Game, message: JsonNode) =
  game.outbox.add $message

proc sendProgramError(game: Game, program: Program, script: Script) =
  let message = %*{"type": "programError", "name": program.name, "version": program.version}
  for key, value in scriptErrorJson(script):
    message[key] = value
  game.send message

proc receiveProgram(game: Game, message: JsonNode) =
  let
    name = message{"name"}.getStr
    source = message{"source"}
  var program: Program
  if source == nil and name == HouseName:
    program = newProgram(HouseName, 0, HouseSource)
  elif source != nil and source.kind == JString and name.len > 0:
    program = newProgram(name, message{"version"}.getInt, source.getStr)
  else:
    return

  # Compiled here only to find errors. The program is compiled again each
  # time it takes the seat, because a compiled program keeps its variables.
  let compiled = loadScript(seatArena, program.source)
  if compiled.status == scriptCompileError:
    game.sendProgramError(program, compiled)
    return
  program.arrivalTick = game.table.tick
  game.waiting = program
  game.send %*{"type": "programLoaded", "name": program.name,
               "version": program.version, "effect": $program.effect}

# --- Commands from outside the programs -----------------------------------------

proc give(game: Game, command: Command) =
  ## A command from the person or from the driver itself: applied now and
  ## recorded. After the Episode has ended the table takes no commands, and
  ## the recording has ended too.
  if game.table.phase == episodeOver:
    return
  var command = command
  command.tick = game.table.tick
  discard game.table.apply(command)
  game.commands.add command

proc setFlipperMode(game: Game, mode: FlipperMode) =
  ## Whoever had the flippers may have been holding one up. The new player
  ## starts with nothing held.
  if mode == game.options.flipperMode:
    return
  game.options.flipperMode = mode
  for side in FlipperSide:
    game.give Command(seat: seatFlipper, kind: cmdFlipper, side: side, pressed: false)
  game.give Command(seat: seatFlipper, kind: cmdPlunger, pressed: false)

# --- Episodes --------------------------------------------------------------------

proc startEpisode(game: Game) =
  ## An empty table at tick 0. The newest program that compiled will build
  ## it: the one that waits, or else the one that played the last Episode.
  game.table = initTable(game.options.settings)
  game.commands.setLen 0
  game.hashes.setLen 0
  game.idleTicks = 0
  if game.waiting == nil:
    game.waiting = game.playing
  game.flipper = loadScript(seatFlipper,
    if game.options.flipperSource.len > 0: game.options.flipperSource else: DemoFlipperSource)

proc waitingIsDue(game: Game): bool =
  ## A program takes the seat on a tick on which the Arena program decides,
  ## so its first decision follows at once and the rules it builds there
  ## hear `evProgramLoaded`.
  if game.waiting == nil or game.table.tick mod ArenaDecisionTicks != 0:
    return false
  if game.table.tick == 0:
    return true   # A new Episode: whatever waits takes the seat.
  case game.waiting.effect
  of effectNextEpisode: false
  of effectNextBall:
    # A new ball number has been served since the program arrived.
    game.table.ballStartTick >= game.waiting.arrivalTick
  of effectNow: true

proc seatWaiting(game: Game) =
  ## The waiting program becomes the Arena player. The table is cleared for
  ## it first, which also raises `evProgramLoaded`. During an Episode the
  ## score, the balls and the clock go on.
  game.give Command(seat: seatArena, kind: cmdClearArena)
  game.playing = game.waiting
  game.waiting = nil
  game.arena = loadScript(seatArena, game.playing.source)
  if game.playing.startsFromHouse:
    let house = loadScript(seatArena, HouseSource)
    house.decide(game.table)
    game.commands.add house.issued

proc decideArena(game: Game) =
  let wasRunning = game.arena.status == scriptRunning
  game.arena.decide(game.table)
  game.commands.add game.arena.issued
  if wasRunning and game.arena.status != scriptRunning:
    # From now on `decide` does nothing: the table stays as it is, and its
    # rules keep running.
    game.sendProgramError(game.playing, game.arena)

proc decideFlipper(game: Game) =
  game.flipper.decide(game.table)
  game.commands.add game.flipper.issued

proc waitAfterEpisode(game: Game) =
  ## A person asks for the next Episode with a restart. Attract mode goes on
  ## by itself.
  if game.options.flipperMode == flipperDemo:
    inc game.idleTicks
    if game.idleTicks >= DemoRestartTicks:
      game.startEpisode()

# --- For the view and the page -----------------------------------------------------

proc newGame*(options = GameOptions(settings: DefaultSettings)): Game =
  ## A game at the start of its first Episode, playing the bundled house
  ## program. A table program that arrives before the first tick plays that
  ## first Episode instead.
  result = Game(options: options, waiting: newProgram(HouseName, 0, HouseSource))
  result.startEpisode()

proc humanInput*(game: Game, command: Command) =
  ## A flipper, plunger or nudge command from the keyboard or a gamepad.
  ## Ignored in demo mode.
  if game.options.flipperMode == flipperDemo:
    return
  var command = command
  command.seat = seatFlipper
  game.give command

proc tick*(game: Game) =
  ## Advance the game by one simulation tick (1/120 s): the programs decide
  ## when their turn comes, the table steps, and the hash is recorded. Does
  ## nothing after the Episode has ended, until a restart.
  if game.table.phase == episodeOver:
    game.waitAfterEpisode()
    return
  if game.waitingIsDue:
    game.seatWaiting()

  if game.table.tick mod ArenaDecisionTicks == 0:
    game.decideArena()
  if game.options.flipperMode == flipperDemo and game.table.tick mod FlipperDecisionTicks == 0:
    game.decideFlipper()
  game.table.step()
  game.hashes.add game.table.stateHash

  if game.table.phase == episodeOver:
    game.send %*{"type": "episode", "summary": episodeSummary(
      game.table, game.playing.name, game.playing.version, game.arena)}

proc takeMessages*(game: Game): seq[string] =
  ## The JSON messages for the page that the game produced since the last
  ## call: `programLoaded`, `programError` (once per failure) and `episode`
  ## (the summary, once, when the Episode ends).
  result = move game.outbox
  game.outbox = @[]

proc receiveMessage*(game: Game, json: string) =
  ## A JSON message from the page. Unknown and malformed messages are ignored.
  ##
  ## - `{"type":"program","name":...,"version":...,"source":...}` loads a table
  ##   program. Directives in the comment lines at its top say when it takes
  ##   effect, `' @effect next-episode` (the default), `' @effect next-ball`
  ##   or `' @effect now`, and which table it starts from, `' @table blank`
  ##   (the default) or `' @table house`. Without a source, `"name":"house"`
  ##   selects the bundled house program.
  ## - `{"type":"restart"}` starts a new Episode now, on the newest program
  ##   that compiled.
  ## - `{"type":"flipper","mode":"human"|"demo"}` changes who plays the flippers.
  var message: JsonNode
  try:
    message = parseJson(json)
  except JsonParsingError:
    return
  if message.kind != JObject:
    return
  case message{"type"}.getStr
  of "program": game.receiveProgram(message)
  of "restart": game.startEpisode()
  of "flipper":
    case message{"mode"}.getStr
    of "human": game.setFlipperMode(flipperHuman)
    of "demo": game.setFlipperMode(flipperDemo)
    else: discard
  else: discard

proc replay*(game: Game): Replay =
  ## The recording of the current Episode, or of the one that just ended.
  Replay(settings: game.table.settings, commands: game.commands, hashes: game.hashes)
