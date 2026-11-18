## The bridge between the game and the web page around it. Both directions
## carry JSON strings.
##
## Game to page: the game calls `Module.pinballMessage(json)` if the page
## defined it. The page draws all text, so besides the game's own messages
## the bridge sends `hud`, the numbers and messages of the side panel, each
## time its content changed.
##
## Page to game: the page pushes strings onto the array `Module.pinballInbox`
## and the game takes them all once per frame. The game pulls, the page does
## not call into the game, because the game's main loop is asleep (suspended
## by Asyncify) most of the time and must not be entered from outside.
##
## The native build has no page: it prints the game's messages and has no inbox.

import
  std/json,
  ../sim/types,
  ../game

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

type Bridge* = object
  lastHud: string

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

proc publish*(bridge: var Bridge, game: Game) =
  ## Call once per frame. The native build has no page to tell.
  when defined(emscripten):
    let hud = hudMessage(game.table)
    if hud != bridge.lastHud:
      bridge.lastHud = hud
      sendToPage(hud)
