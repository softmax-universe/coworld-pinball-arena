/**
 * The join between the page and the game, a WebAssembly bundle in `game/` built with Emscripten.
 *
 * The game finds a global `Module` when its script runs. It draws the table into `Module.canvas`,
 * tells the page things by calling `Module.pinballMessage(jsonString)`, and once per frame empties
 * `Module.pinballInbox`, the array the page pushes its own JSON strings onto. The inbox exists
 * before the script loads, so what the page sends early (the program to play) is there for the
 * game's first frame.
 *
 * Game to page, by `type`: `hud`, `floating`, `episode`, `programLoaded`, `programError`.
 * Page to game: `program`, `restart`, `flipper`.
 */

const GAME_FOLDER = 'game'

/** `scriptUrl` is the game's loader script; the `.wasm` and `.data` beside it are found by name. */
export function createGameBridge(canvas, scriptUrl = `${GAME_FOLDER}/pinball.js`) {
  const listeners = {}
  const inbox = []

  window.Module = {
    canvas,
    locateFile: (file) => `${GAME_FOLDER}/${file}`,
    pinballInbox: inbox,
    pinballMessage(json) {
      const message = JSON.parse(json)
      for (const listener of listeners[message.type] ?? []) listener(message)
    },
  }

  // The game reads the canvas size when the window resizes. The canvas also changes size when the
  // chat panel opens or closes, which resizes no window.
  let sizeKnown = false
  new ResizeObserver(() => {
    if (sizeKnown) window.dispatchEvent(new Event('resize'))
    sizeKnown = true
  }).observe(canvas)

  return {
    /** `listener(message)` runs for each message of that type from the game. */
    on(type, listener) {
      listeners[type] ??= []
      listeners[type].push(listener)
    },
    send: (message) => void inbox.push(JSON.stringify(message)),
    /** Starts the game. `onMissing()` runs if the bundle is not on the server. */
    load(onMissing) {
      const script = document.createElement('script')
      script.src = scriptUrl
      script.addEventListener('error', onMissing)
      document.head.append(script)
    },
  }
}

/**
 * The game takes its keys from the canvas, so it plays only while the canvas has the focus.
 * A click anywhere in `playArea` gives the canvas the focus, including a click on a button there:
 * a focused button would keep Space, the plunger key, for itself. Keys typed in `typingArea` (the
 * chat) stop there, in case the game ever listens on the window as well.
 */
export function giveKeysToGame(canvas, playArea, typingArea) {
  canvas.focus()
  playArea.addEventListener('click', () => canvas.focus())
  for (const type of ['keydown', 'keyup', 'keypress']) {
    typingArea.addEventListener(type, (event) => event.stopPropagation())
  }
}
