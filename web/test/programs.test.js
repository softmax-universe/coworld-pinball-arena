import test from 'node:test'
import assert from 'node:assert/strict'

import { createProgramStore, effectOf } from '../js/programs.js'

const HOUSE_SOURCE = "' The house table.\nPRINT \"HOUSE\"\n"

/** A stand-in for window.localStorage. */
function fakeStorage() {
  const items = new Map()
  return {
    getItem: (key) => (items.has(key) ? items.get(key) : null),
    setItem: (key, value) => void items.set(key, String(value)),
    removeItem: (key) => void items.delete(key),
    clear: () => items.clear(),
    key: (index) => [...items.keys()][index] ?? null,
    get length() {
      return items.size
    },
  }
}

function newStore(storage = fakeStorage()) {
  return createProgramStore(storage, HOUSE_SOURCE)
}

function cogentPrograms(store) {
  return store.list().filter((program) => program.name !== 'house')
}

test('create stores a program under a new name at version 1', () => {
  const store = newStore()
  assert.deepEqual(store.create('ramps', 'PRINT "RAMPS"'), { name: 'ramps', version: 1 })
  assert.equal(store.source('ramps'), 'PRINT "RAMPS"')
  assert.equal(store.source('never-stored'), null)
})

test('create refuses a name that is already stored', () => {
  const store = newStore()
  store.create('ramps', 'PRINT "FIRST"')
  assert.throws(() => store.create('ramps', 'PRINT "SECOND"'), { code: 'conflict' })
  assert.equal(store.source('ramps'), 'PRINT "FIRST"')
  assert.deepEqual(cogentPrograms(store), [{ name: 'ramps', version: 1 }])
})

test('update replaces a stored program and gives the next version', () => {
  const store = newStore()
  store.create('ramps', 'PRINT 1')
  assert.deepEqual(store.update('ramps', 'PRINT 2'), { name: 'ramps', version: 2 })
  assert.deepEqual(store.update('ramps', 'PRINT 3'), { name: 'ramps', version: 3 })
  assert.equal(store.source('ramps'), 'PRINT 3')
})

test('update refuses a name that is not stored', () => {
  const store = newStore()
  assert.throws(() => store.update('ramps', 'PRINT 1'), { code: 'not_found' })
  assert.equal(store.source('ramps'), null)
})

test('source over 256 KiB is refused and what was stored stays', () => {
  const store = newStore()
  const largestAllowed = 'x'.repeat(262144)
  const oneTooMany = 'x'.repeat(262145)

  assert.deepEqual(store.create('full', largestAllowed), { name: 'full', version: 1 })
  assert.throws(() => store.create('huge', oneTooMany), { code: 'too_large' })
  assert.equal(store.source('huge'), null)

  store.create('ramps', 'PRINT 1')
  assert.throws(() => store.update('ramps', oneTooMany), { code: 'too_large' })
  assert.equal(store.source('ramps'), 'PRINT 1')
  assert.deepEqual(store.update('ramps', 'PRINT 2'), { name: 'ramps', version: 2 })
})

test('the house program always exists and the cogent cannot replace it', () => {
  const store = newStore()
  assert.equal(store.source('house'), HOUSE_SOURCE)
  assert.ok(store.list().some((program) => program.name === 'house'))

  assert.throws(() => store.create('house', 'PRINT "MINE"'), { code: 'conflict' })
  assert.throws(() => store.update('house', 'PRINT "MINE"'), { code: 'forbidden' })
  assert.equal(store.source('house'), HOUSE_SOURCE)
})

test('the list gives name and version, most recently stored first', () => {
  const store = newStore()
  store.create('first', 'PRINT 1')
  store.create('second', 'PRINT 2')
  store.create('third', 'PRINT 3')
  store.update('first', 'PRINT 4')

  assert.deepEqual(cogentPrograms(store), [
    { name: 'first', version: 2 },
    { name: 'third', version: 1 },
    { name: 'second', version: 1 },
  ])
})

test('at most 16 programs are kept: the least recently used one goes, never house', () => {
  const store = newStore()
  for (let number = 1; number <= 15; number += 1) {
    store.create(`p${number}`, `PRINT ${number}`)
  }
  assert.equal(store.list().length, 16)

  // Choosing p1 to play is a use, so p2 is now the least recently used.
  store.select('p1')
  store.create('p16', 'PRINT 16')

  assert.equal(store.list().length, 16)
  assert.equal(store.source('p2'), null)
  assert.equal(store.source('p1'), 'PRINT 1')
  assert.equal(store.source('p16'), 'PRINT 16')
  assert.equal(store.source('house'), HOUSE_SOURCE)

  store.create('p17', 'PRINT 17')
  assert.equal(store.list().length, 16)
  assert.equal(store.source('p3'), null)
  assert.equal(store.source('house'), HOUSE_SOURCE)
})

test('house plays next until another stored program is selected', () => {
  const store = newStore()
  assert.equal(store.selected(), 'house')

  store.create('ramps', 'PRINT 1')
  store.select('ramps')
  assert.equal(store.selected(), 'ramps')

  assert.throws(() => store.select('never-stored'), { code: 'not_found' })
  assert.equal(store.selected(), 'ramps')

  store.select('house')
  assert.equal(store.selected(), 'house')
})

test('programs, versions and the selection survive a reload', () => {
  const storage = fakeStorage()
  const before = newStore(storage)
  before.create('ramps', 'PRINT 1')
  before.update('ramps', 'PRINT 2')
  before.create('magnets', 'PRINT 3')
  before.select('ramps')

  const after = newStore(storage)
  assert.deepEqual(after.list(), before.list())
  assert.equal(after.source('ramps'), 'PRINT 2')
  assert.equal(after.source('magnets'), 'PRINT 3')
  assert.equal(after.selected(), 'ramps')
  // A policy.create sent again after a reload must still find the name taken.
  assert.throws(() => after.create('ramps', 'PRINT 4'), { code: 'conflict' })
  assert.deepEqual(after.update('ramps', 'PRINT 5'), { name: 'ramps', version: 3 })
})

test('the first-line directive says when a program takes effect', () => {
  assert.equal(effectOf("' @effect next-episode\nPRINT 1"), 'next-episode')
  assert.equal(effectOf("' @effect next-ball\nPRINT 1"), 'next-ball')
  assert.equal(effectOf("' @effect now\nPRINT 1"), 'now')
  assert.equal(effectOf("' @effect now\r\nPRINT 1"), 'now')
})

test('a missing, unknown or misplaced directive means the next Episode', () => {
  assert.equal(effectOf('PRINT 1'), 'next-episode')
  assert.equal(effectOf("' @effect tomorrow\nPRINT 1"), 'next-episode')
  assert.equal(effectOf("' A plain comment.\n' @effect now\nPRINT 1"), 'next-episode')
})
