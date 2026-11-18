/**
 * The game API: what the cogent can do to the game beyond chat. `cogent-session.js` brings its
 * requests here from the AIDE connection and sends the game's messages back.
 * `docs/cogent/game-api.md` describes all of it for the cogent.
 *
 * A program arrives as an AIDE policy (`policy.create`, `policy.update`): `create` and `update`
 * below store it and make it active.
 *
 * Everything else arrives as a `surface.act` whose data is a request, `{ method, params }`, for
 * `handle`. The answer is `{ result }` or `{ error: { code, message } }`. After `subscribe`, the
 * listeners of `onMessage` also get the game's own messages, which go out as `surface.event`s.
 *
 * Methods:
 *   programs.list                              the stored programs of both seats
 *   programs.get      { name }                 one program with its source
 *   programs.remove   { name }
 *   programs.activate { seat, name }           the program that plays a seat; name null: a person flips
 *   run               { seat, source }         run lines of BASIC once, now, with the calls of a seat
 *   state                                      the table as it is now
 *   restart                                    start a new Episode
 *   subscribe, unsubscribe                     turn the game's messages on and off
 */

import { seatOf } from './programs.js'

const SEATS = ['arena', 'flipper']
/**
 * The messages of the game that a subscriber gets. `ran` and `state` are answers. The cogent is
 * always told of `episode` and `programError`, subscribed or not (see `main.js`).
 */
const SUBSCRIBED_TYPES = ['hud', 'events', 'programLoaded']

function refuse(code, message) {
  throw Object.assign(new Error(message), { code })
}

/**
 * `programs` is the program store and `game` the game bridge. `onProgramsChanged(program)` runs
 * after a request changed the stored programs or which one is active; `program` is the one that
 * was made active or replaced while it was active, and otherwise undefined.
 */
export function createGameApi({ programs, game, onProgramsChanged = () => {} }) {
  /** The game answers `run` and `state` a frame later. The request waits here under its own id. */
  const waiting = new Map()
  let lastAskId = 0
  let subscribed = false
  const messageListeners = []

  function askGame(message) {
    lastAskId += 1
    game.send({ ...message, id: lastAskId })
    return new Promise((resolve) => waiting.set(lastAskId, resolve))
  }

  function answerFromGame(message) {
    waiting.get(message.id)?.(message)
    waiting.delete(message.id)
  }
  game.on('ran', answerFromGame)
  game.on('state', answerFromGame)

  for (const type of SUBSCRIBED_TYPES) {
    game.on(type, (message) => {
      if (subscribed) for (const listener of messageListeners) listener(message)
    })
  }

  /** Tells the game which program plays a seat. The game has the source of the built-in programs. */
  function loadActive(seat) {
    const program = programs.list().find((each) => each.seat === seat && each.active)
    if (!program) return game.send({ type: 'program', seat })
    const { name, version } = program
    game.send({ type: 'program', seat, name, version, ...(program.builtIn ? {} : { source: programs.source(name) }) })
    return program
  }

  /** Makes a program active and loads it. Also for the page, when the person picks a program. */
  function activate(seat, name) {
    programs.activate(seat, name)
    return loadActive(seat)
  }

  const methods = {
    'programs.list': () => ({ programs: programs.list() }),

    'programs.get'({ name }) {
      const program = programs.list().find((each) => each.name === name) ?? refuse('not_found', `No program named ${name} is stored.`)
      return { ...program, source: programs.source(name) }
    },

    'programs.remove'({ name }) {
      const { seat, active } = programs.list().find((each) => each.name === name) ?? {}
      programs.remove(name)
      if (active) loadActive(seat)
      onProgramsChanged()
      return {}
    },

    'programs.activate'({ seat, name = null }) {
      onProgramsChanged(activate(seat, name))
      return { seat, name }
    },

    run({ seat, source }) {
      if (!SEATS.includes(seat)) refuse('invalid', 'The seat is "arena" or "flipper".')
      if (typeof source !== 'string') refuse('invalid', 'The source is a string of BASIC.')
      return askGame({ type: 'run', seat, source }).then(({ output, error }) => ({ output, error }))
    },

    state: () => askGame({ type: 'state' }).then(({ state }) => state),

    restart() {
      game.send({ type: 'restart' })
      return {}
    },

    subscribe() {
      subscribed = true
      return {}
    },

    unsubscribe() {
      subscribed = false
      return {}
    },
  }

  /** The program a policy brought is stored, and it plays its seat. Throws the store's refusals. */
  function deploy({ name, seat, version }) {
    onProgramsChanged(activate(seat, name))
    return { name, version }
  }

  return {
    activate,
    loadActive,

    /** `policy.create`: a new program. Its seat is in its source: `' @seat flipper`, else the Arena seat. */
    create: (name, source) => deploy(programs.add(name, seatOf(source), source)),
    /** `policy.update`: a new source for a stored program. It keeps its seat. */
    update: (name, source) => deploy(programs.update(name, source)),

    /**
     * Resolves with the answer to one request. It never rejects. `run` and `state` are answered a
     * frame later, when the game has answered; the rest at once.
     */
    async handle({ method, params } = {}) {
      try {
        if (!Object.hasOwn(methods, method)) refuse('unknown_method', `There is no method ${method}.`)
        return { result: await methods[method](params ?? {}) }
      } catch (error) {
        return { error: { code: error.code ?? 'failed', message: error.message } }
      }
    },

    /** `listener(message)` runs for each message of the game while the cogent is subscribed. */
    onMessage: (listener) => void messageListeners.push(listener),

    /** The connection to the cogent has gone, and its subscription with it. */
    unsubscribe: () => void (subscribed = false),
  }
}
