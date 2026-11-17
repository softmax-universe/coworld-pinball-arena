## The game driver: one Episode after another on one table.
##
## The simulation in `sim/` only knows a table, commands and ticks. This
## module is everything around it that is still part of the game and not of
## the screen: which programs play the two seats, when a new table program
## takes effect, the replay recording, and the Episode summary. The view
## (window, drawing, sound, keyboard) and the web page sit on top of it and
## talk to it through the few procs below.

import sim/simulation

type
  Game* = ref object
    table*: Table
    outbox: seq[string]

proc newGame*(): Game =
  Game(table: initTable())

proc humanInput*(game: Game, command: Command) =
  ## A flipper, plunger or nudge command from the keyboard or a gamepad.
  var command = command
  command.seat = seatFlipper
  command.tick = game.table.tick
  discard game.table.apply(command)

proc tick*(game: Game) =
  ## Advance the game by one simulation tick (1/120 s).
  game.table.step()

proc takeMessages*(game: Game): seq[string] =
  ## The JSON messages for the page that the game produced since the last
  ## call: the Episode summary, program notices and program errors.
  result = move game.outbox
  game.outbox = @[]

proc receiveMessage*(game: Game, json: string) =
  ## A JSON message from the page: a table program to load, or a request to
  ## restart the Episode.
  discard
