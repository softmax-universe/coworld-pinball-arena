## The game driver: one Episode after another on one table.
##
## The simulation in `sim/` only knows a table, commands and ticks. This
## module is everything around it that is still part of the game and not of
## the screen: which programs play the two seats, when a new table program
## takes effect, the replay recording, and the Episode summary. The view
## (window, drawing, sound, keyboard) and the web page sit on top of it and
## talk to it through the few procs below. `receiveMessage` and
## `takeMessages` are also what the page's game API is made of: load a
## program for a seat, run a few lines of BASIC now, read the table.
##
## The Arena seat is two fields of `Game`. `playing` is the program that
## holds the seat. `waiting` is the newest program that compiled and has not
## taken the seat yet. Every Episode starts by seating the waiting program
## (a restart makes the playing program wait again), and during an Episode a
## waiting program is seated when its `@effect` directive says.
##
## The Flipper seat is simpler. A person plays it unless a Flipper program
## was loaded, and a Flipper program takes the seat at once.
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
  DemoName = "demo"
  HouseSource = staticRead("../../players/house.bas")
  DemoFlipperSource = staticRead("../../players/demo_flipper.bas")
  ProgramRestartTicks = 5 * TicksPerSecond
    ## When a program plays the flippers, the score of a finished Episode
    ## stays up this long before the next Episode starts by itself.

type
  GameOptions* = object
    settings*: TableSettings   ## The editing limits and build-phase length of the table.

  Effect = enum
    ## When a program takes the Arena seat. The values are the words of the
    ## `@effect` directive.
    effectNextEpisode = "next-episode"
    effectNextBall = "next-ball"
    effectNow = "now"

  Program = ref object
    ## A program that compiled. `effect` and `startsFromHouse` are for a
    ## table program only.
    seat: Seat
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
    flipperProgram: Program    ## Plays the flippers, or nil when a person does.
    flipper: Script            ## The running copy of `flipperProgram`, new for each Episode.

    commands: seq[Command]     ## The recording of the current Episode.
    hashes: seq[uint64]
    idleTicks: int             ## Ticks since the Episode ended.

# --- Programs ------------------------------------------------------------------

proc newProgram(seat: Seat, name: string, version: int, source: string): Program =
  ## Reads the directives: comment lines at the top of the source, such as
  ## `' @effect now` and `' @table house`.
  result = Program(seat: seat, name: name, version: version, source: source)
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

proc seatWord(seat: Seat): string =
  if seat == seatFlipper: "flipper" else: "arena"

proc send(game: Game, message: JsonNode) =
  game.outbox.add $message

proc sendProgramError(game: Game, program: Program, script: Script) =
  let message = %*{"type": "programError", "seat": seatWord(program.seat),
                   "name": program.name, "version": program.version}
  for key, value in scriptErrorJson(script):
    message[key] = value
  game.send message

proc seatFlipperProgram(game: Game, program: Program)

proc receiveProgram(game: Game, message: JsonNode) =
  let
    seat = if message{"seat"}.getStr == "flipper": seatFlipper else: seatArena
    name = message{"name"}.getStr
    source = message{"source"}
  var program: Program
  if source != nil and source.kind == JString and name.len > 0:
    program = newProgram(seat, name, message{"version"}.getInt, source.getStr)
  elif seat == seatArena and name == HouseName:
    program = newProgram(seat, HouseName, 0, HouseSource)
  elif seat == seatFlipper and name == DemoName:
    program = newProgram(seat, DemoName, 0, DemoFlipperSource)
  elif seat == seatFlipper and name.len == 0:
    game.seatFlipperProgram(nil)   # A person plays.
    return
  else:
    return

  # Compiled here only to find errors. A program is compiled again each
  # time it takes its seat, because a compiled program keeps its variables.
  let compiled = loadScript(seat, program.source)
  if compiled.status == scriptCompileError:
    game.sendProgramError(program, compiled)
    return
  program.arrivalTick = game.table.tick
  if seat == seatFlipper:
    program.effect = effectNow
    game.seatFlipperProgram(program)
  else:
    game.waiting = program
  game.send %*{"type": "programLoaded", "seat": seatWord(seat), "name": program.name,
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

proc seatFlipperProgram(game: Game, program: Program) =
  ## A program takes the flippers, or with nil a person does. Whoever had
  ## them may have been holding one up. The new player starts with nothing
  ## held.
  game.flipperProgram = program
  game.flipper = if program == nil: nil else: loadScript(seatFlipper, program.source)
  for side in FlipperSide:
    game.give Command(seat: seatFlipper, kind: cmdFlipper, side: side, pressed: false)
  game.give Command(seat: seatFlipper, kind: cmdPlunger, pressed: false)

proc runSource(game: Game, message: JsonNode) =
  ## Direct control: run a few lines of BASIC once, now, with the calls of a
  ## seat. Whatever the lines do is done by the same commands a program
  ## gives, so it is in the recording. The lines start with fresh variables
  ## every time, and what they print goes back to the page.
  let
    seat = if message{"seat"}.getStr == "flipper": seatFlipper else: seatArena
    script = loadScript(seat, message{"source"}.getStr)
  script.decide(game.table)
  if game.table.phase != episodeOver:
    game.commands.add script.issued
  let error =
    if script.status == scriptRunning: newJNull()
    else: %*{"stage": scriptErrorJson(script)["stage"], "message": script.error}
  game.send %*{"type": "ran", "id": message{"id"}, "output": script.output, "error": error}

proc programsJson(game: Game): JsonNode =
  ## Which program holds each seat. `flipper` is null when a person plays.
  proc named(program: Program): JsonNode =
    if program == nil: newJNull() else: %*{"name": program.name, "version": program.version}
  %*{"arena": named(game.playing), "flipper": named(game.flipperProgram)}

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
  if game.flipperProgram != nil:
    game.flipper = loadScript(seatFlipper, game.flipperProgram.source)

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
    # The house said its own table is ready. The program that builds on it
    # says when the whole table is.
    game.give Command(seat: seatArena, kind: cmdReady, pressed: false)

proc decideArena(game: Game) =
  let wasRunning = game.arena.status == scriptRunning
  game.arena.decide(game.table)
  game.commands.add game.arena.issued
  if wasRunning and game.arena.status != scriptRunning:
    # From now on `decide` does nothing: the table stays as it is, and its
    # rules keep running.
    game.sendProgramError(game.playing, game.arena)

proc decideFlipper(game: Game) =
  let wasRunning = game.flipper.status == scriptRunning
  game.flipper.decide(game.table)
  game.commands.add game.flipper.issued
  if wasRunning and game.flipper.status != scriptRunning:
    game.sendProgramError(game.flipperProgram, game.flipper)   # The flippers have gone limp.

proc waitAfterEpisode(game: Game) =
  ## A person asks for the next Episode with a restart. A program at the
  ## flippers plays on by itself.
  if game.flipper != nil:
    inc game.idleTicks
    if game.idleTicks >= ProgramRestartTicks:
      game.startEpisode()

# --- For the view and the page -----------------------------------------------------

proc newGame*(options = GameOptions(settings: DefaultSettings)): Game =
  ## A game at the start of its first Episode, playing the bundled house
  ## program. A table program that arrives before the first tick plays that
  ## first Episode instead.
  result = Game(options: options, waiting: newProgram(seatArena, HouseName, 0, HouseSource))
  result.startEpisode()

proc humanInput*(game: Game, command: Command) =
  ## A flipper, plunger or nudge command from the keyboard or a gamepad.
  ## Ignored while a program plays the flippers.
  if game.flipper != nil:
    return
  var command = command
  command.seat = seatFlipper
  game.give command

proc tick*(game: Game): bool {.discardable.} =
  ## Advance the game by one simulation tick (1/120 s): the programs decide
  ## when their turn comes, the table steps, and the hash is recorded. Does
  ## nothing after the Episode has ended, until a restart. Returns true only
  ## when the table stepped and its events and cues are fresh.
  if game.table.phase == episodeOver:
    game.waitAfterEpisode()
    return
  if game.waitingIsDue:
    game.seatWaiting()

  if game.table.tick mod ArenaDecisionTicks == 0:
    game.decideArena()
  if game.flipper != nil and game.table.tick mod FlipperDecisionTicks == 0:
    game.decideFlipper()
  game.table.step()
  result = true
  game.hashes.add game.table.stateHash

  if game.table.events.len > 0:
    game.send %*{"type": "events", "tick": game.table.tick, "events": eventsJson(game.table)}
  if game.table.phase == episodeOver:
    let summary = episodeSummary(game.table, game.playing.name, game.playing.version, game.arena)
    summary["flipper"] = game.programsJson["flipper"]
    if game.flipper != nil:
      summary["flipper"]["scriptError"] = scriptErrorJson(game.flipper)
    game.send %*{"type": "episode", "summary": summary}

proc takeMessages*(game: Game): seq[string] =
  ## The JSON messages for the page that the game produced since the last
  ## call: `programLoaded`, `programError` (once per failure), `events` (the
  ## table events of a tick), `episode` (the summary, once, when the Episode
  ## ends), and the answers `ran` and `state`.
  result = move game.outbox
  game.outbox = @[]

proc receiveMessage*(game: Game, json: string) =
  ## A JSON message from the page. Unknown and malformed messages are ignored.
  ##
  ## - `{"type":"program","seat":...,"name":...,"version":...,"source":...}`
  ##   loads a program for a seat, `"arena"` (the default) or `"flipper"`.
  ##   - A table program says in the comment lines at its top when it takes
  ##     effect, `' @effect next-episode` (the default), `' @effect next-ball`
  ##     or `' @effect now`, and which table it starts from, `' @table blank`
  ##     (the default) or `' @table house`. Without a source, `"name":"house"`
  ##     selects the bundled house program.
  ##   - A Flipper program takes the flippers at once. Without a source,
  ##     `"name":"demo"` selects the bundled demo program, and no name at all
  ##     gives the flippers back to the person.
  ## - `{"type":"run","id":...,"seat":...,"source":...}` runs lines of BASIC
  ##   once, now, with the calls of that seat. The answer is
  ##   `{"type":"ran","id":...,"output":[...],"error":null}`: what the lines
  ##   printed, and `{"stage","message"}` when they failed.
  ## - `{"type":"state","id":...}` asks for the table. The answer is
  ##   `{"type":"state","id":...,"state":{...}}`.
  ## - `{"type":"restart"}` starts a new Episode now, on the newest table
  ##   program that compiled.
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
  of "run": game.runSource(message)
  of "state":
    let state = tableState(game.table)
    state["programs"] = game.programsJson
    game.send %*{"type": "state", "id": message{"id"}, "state": state}
  else: discard

proc replay*(game: Game): Replay =
  ## The recording of the current Episode, or of the one that just ended.
  Replay(settings: game.table.settings, commands: game.commands, hashes: game.hashes)
