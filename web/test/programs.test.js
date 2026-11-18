import test from 'node:test'
import assert from 'node:assert/strict'

import { createProgramStore, effectOf, seatOf } from '../js/programs.js'

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

const SOURCE = 'PRINT 1'

test('add stores a program for a seat at version 1, and does not make it active', () => {
  const store = createProgramStore(fakeStorage())
  assert.deepEqual(store.add('ramps', 'arena', SOURCE), { name: 'ramps', seat: 'arena', version: 1 })
  assert.equal(store.source('ramps'), SOURCE)
  assert.equal(store.active('arena'), 'house')
})

test('the list has every program, newest first, the built-in ones last, with the active ones marked', () => {
  const store = createProgramStore(fakeStorage())
  store.add('ramps', 'arena', SOURCE)
  store.add('catcher', 'flipper', SOURCE)
  store.activate('flipper', 'catcher')
  assert.deepEqual(store.list(), [
    { name: 'catcher', seat: 'flipper', version: 1, builtIn: false, active: true },
    { name: 'ramps', seat: 'arena', version: 1, builtIn: false, active: false },
    { name: 'house', seat: 'arena', version: 0, builtIn: true, active: true },
    { name: 'demo', seat: 'flipper', version: 0, builtIn: true, active: false },
  ])
})

test('add refuses a taken name, a bad name, a bad seat and a source over 256 KiB', () => {
  const store = createProgramStore(fakeStorage())
  store.add('ramps', 'arena', SOURCE)
  assert.throws(() => store.add('ramps', 'flipper', SOURCE), { code: 'conflict' })
  assert.throws(() => store.add('house', 'arena', SOURCE), { code: 'conflict' })
  assert.throws(() => store.add('', 'arena', SOURCE), { code: 'invalid' })
  assert.throws(() => store.add('x'.repeat(65), 'arena', SOURCE), { code: 'invalid' })
  assert.throws(() => store.add('lanes', 'table', SOURCE), { code: 'invalid' })
  assert.throws(() => store.add('lanes', 'arena', 7), { code: 'invalid' })
  assert.throws(() => store.add('lanes', 'arena', 'x'.repeat(256 * 1024 + 1)), { code: 'too_large' })
  assert.equal(store.list().length, 3)
})

test('update replaces the source and gives the next version', () => {
  const store = createProgramStore(fakeStorage())
  store.add('ramps', 'arena', SOURCE)
  assert.deepEqual(store.update('ramps', 'PRINT 2'), { name: 'ramps', seat: 'arena', version: 2 })
  assert.equal(store.source('ramps'), 'PRINT 2')
  assert.throws(() => store.update('lanes', SOURCE), { code: 'not_found' })
})

test('the built-in programs cannot be changed or removed', () => {
  const store = createProgramStore(fakeStorage())
  assert.throws(() => store.update('house', SOURCE), { code: 'forbidden' })
  assert.throws(() => store.remove('demo'), { code: 'forbidden' })
  assert.equal(store.source('house'), null)
})

test('a person plays the flippers until a Flipper program is made active, and again after', () => {
  const store = createProgramStore(fakeStorage())
  assert.equal(store.active('flipper'), null)
  store.activate('flipper', 'demo')
  assert.equal(store.active('flipper'), 'demo')
  store.activate('flipper', null)
  assert.equal(store.active('flipper'), null)
})

test('activate refuses an unknown program, one of the other seat, and a table with no program', () => {
  const store = createProgramStore(fakeStorage())
  store.add('ramps', 'arena', SOURCE)
  assert.throws(() => store.activate('arena', 'lanes'), { code: 'not_found' })
  assert.throws(() => store.activate('flipper', 'ramps'), { code: 'invalid' })
  assert.throws(() => store.activate('arena', null), { code: 'invalid' })
  assert.equal(store.active('arena'), 'house')
})

test('removing the active program gives its seat back to the default', () => {
  const store = createProgramStore(fakeStorage())
  store.add('ramps', 'arena', SOURCE)
  store.add('catcher', 'flipper', SOURCE)
  store.activate('arena', 'ramps')
  store.activate('flipper', 'catcher')
  store.remove('ramps')
  store.remove('catcher')
  assert.equal(store.active('arena'), 'house')
  assert.equal(store.active('flipper'), null)
  assert.throws(() => store.remove('ramps'), { code: 'not_found' })
})

test('programs, versions and the active programs survive a reload', () => {
  const storage = fakeStorage()
  const before = createProgramStore(storage)
  before.add('ramps', 'arena', SOURCE)
  before.update('ramps', 'PRINT 2')
  before.activate('arena', 'ramps')

  const after = createProgramStore(storage)
  assert.equal(after.active('arena'), 'ramps')
  assert.equal(after.source('ramps'), 'PRINT 2')
  assert.deepEqual(after.update('ramps', 'PRINT 3'), { name: 'ramps', seat: 'arena', version: 3 })
})

test('when the browser storage is full, nothing changes', () => {
  const storage = fakeStorage()
  const store = createProgramStore(storage)
  store.add('ramps', 'arena', SOURCE)
  storage.setItem = () => {
    throw new Error('QuotaExceededError')
  }
  assert.throws(() => store.add('lanes', 'arena', SOURCE))
  assert.throws(() => store.activate('arena', 'ramps'))
  assert.equal(store.list().length, 3)
  assert.equal(store.active('arena'), 'house')
})

test('a directive in the comment lines at the top says when a program takes effect', () => {
  assert.equal(effectOf("' @effect next-episode\nPRINT 1"), 'next-episode')
  assert.equal(effectOf("' @effect next-ball\nPRINT 1"), 'next-ball')
  assert.equal(effectOf("' @effect now\nPRINT 1"), 'now')
  assert.equal(effectOf("' @effect now\r\nPRINT 1"), 'now')
  // As the game reads it: on any comment line at the top, after `@table`, in any case.
  assert.equal(effectOf("' A plain comment.\n' @effect now\nPRINT 1"), 'now')
  assert.equal(effectOf("' @table house\n\n' @effect next-ball\nPRINT 1"), 'next-ball')
  assert.equal(effectOf("  ' @EFFECT Now\nPRINT 1"), 'now')
})

test('a missing, unknown or misplaced directive means the next Episode', () => {
  assert.equal(effectOf('PRINT 1'), 'next-episode')
  assert.equal(effectOf("' @effect tomorrow\nPRINT 1"), 'next-episode')
  assert.equal(effectOf("' @effect now please\nPRINT 1"), 'next-episode')
  assert.equal(effectOf("PRINT 1\n' @effect now"), 'next-episode')
})

test('a program is for the Arena seat unless a directive says flipper', () => {
  assert.equal(seatOf('PRINT 1'), 'arena')
  assert.equal(seatOf("' @seat arena\nPRINT 1"), 'arena')
  assert.equal(seatOf("' Catches the ball.\n' @seat flipper\nflip(left, 1)"), 'flipper')
  assert.equal(seatOf("flip(left, 1)\n' @seat flipper"), 'arena')
})
