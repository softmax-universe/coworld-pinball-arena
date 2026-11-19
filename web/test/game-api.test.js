import test from 'node:test'
import assert from 'node:assert/strict'

import { createGameApi } from '../js/game-api.js'
import { createProgramStore } from '../js/programs.js'

function fakeStorage() {
  const items = new Map()
  return {
    getItem: (key) => (items.has(key) ? items.get(key) : null),
    setItem: (key, value) => void items.set(key, String(value)),
  }
}

/** The game bridge: records what the page sends the game, and lets the test speak for the game. */
function fakeGame() {
  const listeners = {}
  const game = {
    sent: [],
    send: (message) => void game.sent.push(message),
    on: (type, listener) => void (listeners[type] ??= []).push(listener),
    says(message) {
      for (const listener of listeners[message.type] ?? []) listener(message)
    },
  }
  return game
}

function start() {
  const game = fakeGame()
  const programs = createProgramStore(fakeStorage())
  const changes = []
  const api = createGameApi({ programs, game, onProgramsChanged: (program) => changes.push(program?.name) })
  const call = (method, params) => api.handle({ method, params })
  return { game, programs, api, changes, call }
}

const SOURCE = "' @effect now\nready()"

test('a created program is stored for the seat its source names, made active and sent to the game', () => {
  const { game, api, programs, changes } = start()
  assert.deepEqual(api.create('ramps', SOURCE), { name: 'ramps', version: 1 })
  assert.deepEqual(game.sent, [{ type: 'program', seat: 'arena', name: 'ramps', version: 1, source: SOURCE }])

  const flipperSource = "' @seat flipper\nflip(left, 1)"
  assert.deepEqual(api.create('catcher', flipperSource), { name: 'catcher', version: 1 })
  assert.deepEqual(game.sent.at(-1), { type: 'program', seat: 'flipper', name: 'catcher', version: 1, source: flipperSource })
  assert.equal(programs.active('arena'), 'ramps')
  assert.equal(programs.active('flipper'), 'catcher')
  assert.deepEqual(changes, ['ramps', 'catcher'])
})

test('an updated program keeps its seat, is made active again and sent to the game', () => {
  const { game, api, programs } = start()
  api.create('catcher', "' @seat flipper\nflip(left, 1)")
  programs.activate('flipper', null)
  assert.deepEqual(api.update('catcher', 'flip(right, 1)'), { name: 'catcher', version: 2 })
  assert.deepEqual(game.sent.at(-1), { type: 'program', seat: 'flipper', name: 'catcher', version: 2, source: 'flip(right, 1)' })
  assert.throws(() => api.update('nothing', SOURCE), { code: 'not_found' })
  assert.throws(() => api.create('catcher', SOURCE), { code: 'conflict' })
})

test('the policies are the deployed programs of both seats, without the built-in ones', () => {
  const { api } = start()
  assert.deepEqual(api.policies(), [])
  api.create('ramps', SOURCE)
  api.create('catcher', "' @seat flipper\nflip(left, 1)")
  api.update('ramps', SOURCE)
  // Every version is 1 or more, as the contract's `PolicyVersion` requires.
  assert.deepEqual(api.policies(), [
    { name: 'catcher', version: 1 },
    { name: 'ramps', version: 2 },
  ])
})

test('a request can list, read, activate and remove the stored programs', async () => {
  const { game, api, call } = start()
  api.create('ramps', SOURCE)
  await call('programs.activate', { seat: 'flipper', name: 'demo' })
  assert.deepEqual(game.sent.at(-1), { type: 'program', seat: 'flipper', name: 'demo', version: 0 })

  const { programs } = (await call('programs.list')).result
  assert.deepEqual(
    programs.map(({ name, active }) => [name, active]),
    [['ramps', true], ['house', false], ['demo', true]],
  )
  assert.equal((await call('programs.get', { name: 'ramps' })).result.source, SOURCE)
  assert.equal((await call('programs.get', { name: 'house' })).result.source, null)

  // Removing the active program gives the table back to the house, and no name gives the flippers to the person.
  await call('programs.remove', { name: 'ramps' })
  assert.deepEqual(game.sent.at(-1), { type: 'program', seat: 'arena', name: 'house', version: 0 })
  await call('programs.activate', { seat: 'flipper', name: null })
  assert.deepEqual(game.sent.at(-1), { type: 'program', seat: 'flipper' })
})

test('a refusal comes back as an error with the reason', async () => {
  const { call } = start()
  assert.equal((await call('programs.remove', { name: 'house' })).error.code, 'forbidden')
  assert.equal((await call('programs.get', { name: 'nothing' })).error.code, 'not_found')
  assert.equal((await call('run', { seat: 'referee', source: 'x = 1' })).error.code, 'invalid')
  assert.equal((await call('teleport')).error.code, 'unknown_method')
  assert.equal((await call('__proto__')).error.code, 'unknown_method')
})

test('run and state are answered when the game answers, each request with its own answer', async () => {
  const { game, call } = start()
  const ran = call('run', { seat: 'flipper', source: 'flip(left, 1)' })
  const state = call('state')
  assert.deepEqual(game.sent, [
    { type: 'run', seat: 'flipper', source: 'flip(left, 1)', id: 1 },
    { type: 'state', id: 2 },
  ])

  game.says({ type: 'state', id: 2, state: { phase: 'play', score: 100 } })
  game.says({ type: 'ran', id: 1, output: [' 1'], error: null })
  assert.deepEqual(await state, { result: { phase: 'play', score: 100 } })
  assert.deepEqual(await ran, { result: { output: [' 1'], error: null } })
})

test('restart starts a new Episode', async () => {
  const { game, call } = start()
  await call('restart')
  assert.deepEqual(game.sent, [{ type: 'restart' }])
})

test('the messages of the game are passed on only while the cogent is subscribed', async () => {
  const { game, api, call } = start()
  const messages = []
  api.onMessage((message) => messages.push(message))

  game.says({ type: 'hud', score: 10 })
  await call('subscribe')
  game.says({ type: 'hud', score: 20 })
  game.says({ type: 'events', tick: 5, events: [{ kind: 'hit', value: 0 }] })
  // The answers to run and state are not passed on, and the cogent is told of an Episode's end in any case.
  game.says({ type: 'state', id: 99, state: {} })
  game.says({ type: 'episode', summary: {} })
  await call('unsubscribe')
  game.says({ type: 'hud', score: 30 })

  assert.deepEqual(messages, [
    { type: 'hud', score: 20 },
    { type: 'events', tick: 5, events: [{ kind: 'hit', value: 0 }] },
  ])
})
