/**
 * The stored programs: BASIC sources for either seat, kept in the browser's localStorage so they
 * survive a reload, plus the two programs built into the game and the choice of which program is
 * active for each seat.
 *
 * `game-api.js` calls `add`, `update`, `remove` and `activate` for the cogent (a program arrives
 * as an AIDE policy), and the page calls `activate` when the person picks a program.
 *
 * A refusal is thrown as an Error whose `code` says why: `conflict`, `not_found`, `too_large`,
 * `forbidden` or `invalid`.
 */

const STORAGE_KEY = 'pinball-arena.programs.v2'
const MAX_SOURCE_BYTES = 256 * 1024
const MAX_NAME_LENGTH = 64
const SEATS = ['arena', 'flipper']
/** The game has the source of these. They cannot be changed or removed. */
const BUILT_IN = [
  { name: 'house', seat: 'arena', version: 0, builtIn: true },
  { name: 'demo', seat: 'flipper', version: 0, builtIn: true },
]
/** With no Flipper program active (null) a person plays the flippers. The table always has a program. */
const DEFAULT_ACTIVE = { arena: 'house', flipper: null }

const EFFECTS = ['next-episode', 'next-ball', 'now']

/**
 * The directives of a program: comments of exactly two words, such as `' @effect next-ball`, among
 * the comment lines at the top of the source, upper or lower case. The last one of a kind counts.
 *
 * This reads the source the way the game does (`newProgram` in src/pinball/game.nim), so keep the
 * two in step.
 */
function directives(source) {
  const found = {}
  for (const line of source.split(/\r\n|\n|\r/)) {
    const text = line.trim()
    if (text === '') continue
    if (!text.startsWith("'")) break
    const words = text.slice(1).toLowerCase().split(/\s+/).filter((word) => word !== '')
    if (words.length === 2) found[words[0]] = words[1]
  }
  return found
}

/** When a table program wants to take effect: `next-episode` (also for anything unknown), `next-ball` or `now`. */
export function effectOf(source) {
  const effect = directives(source)['@effect']
  return EFFECTS.includes(effect) ? effect : 'next-episode'
}

/** The seat a program is written for: `flipper` with the directive `' @seat flipper`, else `arena`. */
export function seatOf(source) {
  return directives(source)['@seat'] === 'flipper' ? 'flipper' : 'arena'
}

function refuse(code, message) {
  throw Object.assign(new Error(message), { code })
}

/** `storage` is `window.localStorage` or anything with its `getItem` and `setItem`. */
export function createProgramStore(storage) {
  /** `programs` holds `{ name, seat, version, source }` in the order they were added. */
  let { programs, active } = JSON.parse(storage.getItem(STORAGE_KEY)) ?? { programs: [], active: DEFAULT_ACTIVE }

  const find = (name) => programs.find((program) => program.name === name)
  const findBuiltIn = (name) => BUILT_IN.find((program) => program.name === name)

  /** Saves first and only then replaces what is in memory, so a full browser storage changes nothing. */
  function commit(nextPrograms, nextActive) {
    storage.setItem(STORAGE_KEY, JSON.stringify({ programs: nextPrograms, active: nextActive }))
    programs = nextPrograms
    active = nextActive
  }

  function checkSource(source) {
    if (typeof source !== 'string') refuse('invalid', 'The source of a program is a string.')
    if (new TextEncoder().encode(source).length > MAX_SOURCE_BYTES) {
      refuse('too_large', 'A program can be at most 256 KiB.')
    }
  }

  function stored(name) {
    if (findBuiltIn(name)) refuse('forbidden', `The built-in program ${name} cannot be changed.`)
    return find(name) ?? refuse('not_found', `No program named ${name} is stored.`)
  }

  /** `{ name, seat, version }` of the new program. It is not active until `activate`. */
  function add(name, seat, source) {
    if (typeof name !== 'string' || name === '' || name.length > MAX_NAME_LENGTH) {
      refuse('invalid', `A program name is 1 to ${MAX_NAME_LENGTH} characters.`)
    }
    if (!SEATS.includes(seat)) refuse('invalid', 'The seat of a program is "arena" or "flipper".')
    if (find(name) || findBuiltIn(name)) refuse('conflict', `A program named ${name} is already stored.`)
    checkSource(source)
    commit([...programs, { name, seat, version: 1, source }], active)
    return { name, seat, version: 1 }
  }

  /** Replaces the source of a stored program. Its version goes up by one. */
  function update(name, source) {
    const old = stored(name)
    checkSource(source)
    const program = { ...old, version: old.version + 1, source }
    commit(programs.map((each) => (each === old ? program : each)), active)
    return { name, seat: program.seat, version: program.version }
  }

  /** Removes a stored program. If it was active, its seat goes back to the default. */
  function remove(name) {
    const { seat } = stored(name)
    commit(
      programs.filter((each) => each.name !== name),
      active[seat] === name ? { ...active, [seat]: DEFAULT_ACTIVE[seat] } : active,
    )
  }

  /** Makes a program the active one of its seat. `activate('flipper', null)` gives the flippers to the person. */
  function activate(seat, name) {
    if (!SEATS.includes(seat)) refuse('invalid', 'The seat is "arena" or "flipper".')
    if (name === null) {
      if (seat === 'arena') refuse('invalid', 'The table always has a program. Activate "house" for the built-in one.')
    } else {
      const program = find(name) ?? findBuiltIn(name) ?? refuse('not_found', `No program named ${name} is stored.`)
      if (program.seat !== seat) refuse('invalid', `${name} is a program for the ${program.seat} seat.`)
    }
    commit(programs, { ...active, [seat]: name })
  }

  return {
    add,
    update,
    remove,
    activate,
    /** The name of the active program of a seat. Null for the flippers when a person plays. */
    active: (seat) => active[seat],
    /** The text of a stored program. Null for a built-in program and for an unknown name. */
    source: (name) => find(name)?.source ?? null,
    /** `{ name, seat, version, builtIn, active }` of every program: newest first, the built-in ones last. */
    list() {
      return [...programs].reverse().concat(BUILT_IN).map(({ name, seat, version, builtIn = false }) => ({
        name,
        seat,
        version,
        builtIn,
        active: active[seat] === name,
      }))
    },
  }
}
