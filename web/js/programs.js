/**
 * The stored table programs: the BASIC sources the cogent has sent, kept in the browser's
 * localStorage so they survive a reload, plus the built-in `house` program and the choice of which
 * program plays next.
 *
 * `cogent-session.js` calls `create` and `update` when the cogent sends a program (the AIDE
 * `policy.create` and `policy.update` requests, which arrive through `aide-client.js`). The page
 * reads `list`, `source` and `selected` to show the "table programs" list and to load a table.
 *
 * A refusal is thrown as an Error whose `code` is the AIDE error code that describes it:
 * `conflict`, `not_found`, `too_large` or `forbidden`.
 */

const STORAGE_KEY = 'pinball-arena.programs'
const HOUSE = 'house'
const MAX_SOURCE_BYTES = 256 * 1024
/** Counts `house`, so the cogent's programs get 15 places. */
const MAX_PROGRAMS = 16

const EFFECTS = ['next-episode', 'next-ball', 'now']
const EFFECT_DIRECTIVE = /^'\s*@effect\s+(\S+)\s*$/

/**
 * When a program wants to take effect: `next-episode`, `next-ball` or `now`. The program says so
 * in a comment on its first line, `' @effect next-ball`, because the message that delivers a
 * program carries only a name and the text. Anything else means the next Episode.
 */
export function effectOf(source) {
  const firstLine = source.split(/\r?\n/, 1)[0]
  const effect = EFFECT_DIRECTIVE.exec(firstLine)?.[1]
  return EFFECTS.includes(effect) ? effect : 'next-episode'
}

function refuse(code, message) {
  throw Object.assign(new Error(message), { code })
}

/** `storage` is `window.localStorage` or anything with its `getItem` and `setItem`. */
export function createProgramStore(storage, houseSource) {
  // `storedAt` and `usedAt` are readings of `clock`, a counter that goes up by one per change.
  // They only order the programs, and a counter cannot go backwards the way a wall clock can.
  let { programs, selected, clock } = JSON.parse(storage.getItem(STORAGE_KEY)) ?? {
    programs: [],
    selected: HOUSE,
    clock: 0,
  }

  const find = (name) => programs.find((program) => program.name === name)

  /** Saves first and only then replaces what is in memory, so a full browser storage changes nothing. */
  function commit(nextPrograms, nextSelected) {
    const next = { programs: nextPrograms, selected: nextSelected, clock: clock + 1 }
    storage.setItem(STORAGE_KEY, JSON.stringify(next))
    ;({ programs, selected, clock } = next)
  }

  function checkSize(source) {
    if (new TextEncoder().encode(source).length > MAX_SOURCE_BYTES) {
      refuse('too_large', 'A table program can be at most 256 KiB.')
    }
  }

  /** Drops the least recently used programs until `house` and the rest fit the limit. */
  function withinLimit(kept) {
    const byLastUse = [...kept].sort((a, b) => b.usedAt - a.usedAt)
    return byLastUse.slice(0, MAX_PROGRAMS - 1)
  }

  function create(name, source) {
    if (name === HOUSE || find(name)) refuse('conflict', `A program named ${name} is already stored.`)
    checkSize(source)
    const program = { name, version: 1, source, storedAt: clock + 1, usedAt: clock + 1 }
    commit(withinLimit([...programs, program]), selected)
    return { name, version: 1 }
  }

  function update(name, source) {
    if (name === HOUSE) refuse('forbidden', 'The house program cannot be replaced.')
    const stored = find(name)
    if (!stored) refuse('not_found', `No program named ${name} is stored.`)
    checkSize(source)
    const program = { name, version: stored.version + 1, source, storedAt: clock + 1, usedAt: clock + 1 }
    commit(programs.map((each) => (each === stored ? program : each)), selected)
    return { name, version: program.version }
  }

  /** Chooses the program that plays next. Choosing a program counts as using it. */
  function select(name) {
    if (name !== HOUSE && !find(name)) refuse('not_found', `No program named ${name} is stored.`)
    commit(programs.map((each) => (each.name === name ? { ...each, usedAt: clock + 1 } : each)), name)
  }

  return {
    create,
    update,
    select,
    /** The name of the program that plays next. `house` again if the chosen one has been dropped. */
    selected: () => (find(selected) ? selected : HOUSE),
    /** The text of a program, or null when no program has that name. */
    source: (name) => (name === HOUSE ? houseSource : (find(name)?.source ?? null)),
    /** `{ name, version }` of every program, most recently stored first, `house` last. */
    list() {
      const newestFirst = [...programs].sort((a, b) => b.storedAt - a.storedAt)
      return [...newestFirst.map(({ name, version }) => ({ name, version })), { name: HOUSE, version: 1 }]
    },
  }
}
