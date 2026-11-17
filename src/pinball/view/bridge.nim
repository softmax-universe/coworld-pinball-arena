## The bridge between the game and the web page around it. Both directions
## carry JSON strings.
##
## Game to page: the game calls `Module.pinballMessage(json)` if the page
## defined it. The page draws all text, so besides the game's own messages
## the bridge sends two of its own, each only when its content changed:
##
## - `hud`: the numbers and messages of the side panel.
## - `floating`: every piece of text that hovers over the table, with the
##   place of each on the canvas as fractions 0 .. 1 of its width and height.
##
## Page to game: the page pushes strings onto the array `Module.pinballInbox`
## and the game takes them all once per frame. The game pulls, the page does
## not call into the game, because the game's main loop is asleep (suspended
## by Asyncify) most of the time and must not be entered from outside.
##
## The native build has no page: it prints the game's messages and has no inbox.

import
  std/[json, math, strutils],
  vmath,
  ../sim/types,
  ../game,
  tableview

const
  ScorePopupSeconds = 1.2'f32
  ColourNames: array[LampColour, string] = ["yellow", "red", "green", "blue", "white"]

when defined(emscripten):
  {.emit: """
  #include <emscripten.h>
  #include <stdlib.h>
  EM_JS(void, pinballSendMessage, (const char* json), {
    if (Module.pinballMessage) Module.pinballMessage(UTF8ToString(json));
  });
  // The oldest waiting message as a new C string, or 0 when there is none.
  EM_JS(char*, pinballTakeMessage, (), {
    var inbox = Module.pinballInbox;
    if (!inbox || inbox.length === 0) return 0;
    return stringToNewUTF8(String(inbox.shift()));
  });
  """.}
  proc pinballSendMessage(json: cstring) {.importc, nodecl.}
  proc pinballTakeMessage(): cstring {.importc, nodecl.}
  proc free(memory: pointer) {.importc, header: "<stdlib.h>".}

type
  ScorePopup = object
    text: string
    at: Vec3
    secondsLeft: float32

  Bridge* = object
    lastHud, lastFloating: string
    popups: seq[ScorePopup]

proc sendToPage*(json: string) =
  when defined(emscripten):
    pinballSendMessage(json.cstring)
  else:
    echo json

proc deliverInbox*(game: Game) =
  ## Hand every message the page has sent since the last frame to the game.
  when defined(emscripten):
    while true:
      let message = pinballTakeMessage()
      if message == nil:
        break
      game.receiveMessage($message)
      free(message)

proc signedAmount(amount: int32): string =
  ## 5000 -> "+5,000".
  (if amount < 0: "-" else: "+") & insertSep($abs(amount), ',')

proc noteTick*(bridge: var Bridge, table: Table) =
  ## Call after every tick: each score change of the tick becomes a
  ## short-lived text at the component that caused it.
  for change in table.scoreChanges:
    bridge.popups.add ScorePopup(text: signedAmount(change.amount),
      at: pieceAnchor(table, change.componentId), secondsLeft: ScorePopupSeconds)

proc hudMessage(table: Table): string =
  const PhaseNames: array[EpisodePhase, string] = ["build", "play", "over"]
  $(%*{
    "type": "hud",
    "phase": PhaseNames[table.phase],
    "ballNumber": table.ballNumber,
    "ballsPerEpisode": BallsPerEpisode,
    "score": table.score,
    "quest": table.questText,
    "award": table.awardText,
    "clockSeconds": max(EpisodeClockTicks - int(table.tick), 0) div TicksPerSecond,
    "tiltWarnings": table.tiltWarnings,
    "tilted": table.tilted,
    "ballSaveActive": table.ballSaveTicks > 0
  })

proc floatingItem(view: TableView, at: Vec3, text, colour, kind: string): JsonNode =
  let place = view.project(at)
  %*{"x": round(place.x.float64 * 1000) / 1000, "y": round(place.y.float64 * 1000) / 1000,
     "text": text, "colour": colour, "kind": kind}

proc floatingMessage(bridge: Bridge, table: Table, view: TableView): string =
  var items = newJArray()
  for piece in table.components:
    if piece.kind == ckFloatingText and piece.phase == phaseSolid and piece.text.len > 0:
      let colour = LampColour(clamp(toInt(piece.settings[setColour]), 0, ord(high(LampColour))))
      items.add view.floatingItem(pieceAnchor(table, piece.id), piece.text,
        ColourNames[colour], "text")
  for message in table.floatingMessages:
    items.add view.floatingItem(pieceAnchor(table, message.componentId), message.text,
      "white", "message")
  for popup in bridge.popups:
    items.add view.floatingItem(popup.at, popup.text, "yellow", "score")
  $(%*{"type": "floating", "items": items})

proc publish*(bridge: var Bridge, game: Game, view: TableView, seconds: float32) =
  ## Call once per frame, after drawing: the view's camera is then the one
  ## the frame was drawn with. The native build has no page to tell.
  var index = 0
  while index < bridge.popups.len:
    bridge.popups[index].secondsLeft -= seconds
    if bridge.popups[index].secondsLeft <= 0:
      bridge.popups.delete index
    else:
      inc index
  when defined(emscripten):
    let hud = hudMessage(game.table)
    if hud != bridge.lastHud:
      bridge.lastHud = hud
      sendToPage(hud)
    let floating = bridge.floatingMessage(game.table, view)
    if floating != bridge.lastFloating:
      bridge.lastFloating = floating
      sendToPage(floating)
