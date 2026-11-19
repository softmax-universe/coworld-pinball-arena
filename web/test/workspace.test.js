import test from 'node:test'
import assert from 'node:assert/strict'

import { startWorkspace } from '../js/cogent-connection.js'

/**
 * Replaces `fetch` with one that answers from `routes`: `"METHOD path"` to a body, to `inTurn`
 * bodies (one for each call, the last one repeating), or to a number for a failed status.
 * Returns the calls made, as `"METHOD path"` plus the JSON body when there was one.
 */
const inTurn = (...bodies) => ({ inTurn: bodies })

function fakeSoftmax(t, routes) {
  const calls = []
  const realFetch = globalThis.fetch
  t.after(() => (globalThis.fetch = realFetch))
  globalThis.fetch = (url, init) => {
    const key = `${init.method} ${url.replace('/softmax-cogent/api', '')}`
    calls.push(init.body ? `${key} ${init.body}` : key)
    const route = routes[key]
    const turns = route?.inTurn
    const answer = turns ? (turns.length > 1 ? turns.shift() : turns[0]) : route
    if (typeof answer === 'number') return Promise.resolve({ ok: false, status: answer })
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(answer) })
  }
  return calls
}

const workspace = (status, detail) => ({ provisioning_id: 'ws-1', player_id: 'ply-1', status, detail })

test('a ready workspace is used as it is', async (t) => {
  const calls = fakeSoftmax(t, { 'GET /v2/hermes': workspace('ready') })
  const progress = []
  assert.equal(await startWorkspace((text) => progress.push(text), 0), 'ws-1')
  assert.deepEqual(calls, ['GET /v2/hermes'])
  assert.deepEqual(progress, [])
})

test('an account with no workspace gets one on its default player, and the page waits until it is ready', async (t) => {
  const calls = fakeSoftmax(t, {
    'GET /v2/hermes': inTurn(null, workspace('provisioning'), workspace('ready')),
    'GET /players': [
      { id: 'ply-0', is_default: true, disabled_at: '2026-01-01' },
      { id: 'ply-2', is_default: false },
      { id: 'ply-1', is_default: true },
    ],
    'POST /v2/cogents': {},
    'PUT /v2/cogents/ply-1/hermes': workspace('provisioning'),
  })
  const progress = []
  assert.equal(await startWorkspace((text) => progress.push(text), 0), 'ws-1')
  assert.deepEqual(calls, [
    'GET /v2/hermes',
    'GET /players',
    'POST /v2/cogents {"player_id":"ply-1"}',
    'PUT /v2/cogents/ply-1/hermes {}',
    'GET /v2/hermes',
    'GET /v2/hermes',
  ])
  assert.equal(progress.length, 1)
})

test('a paused or sleeping workspace is started again', async (t) => {
  const calls = fakeSoftmax(t, {
    'GET /v2/hermes': inTurn(workspace('suspended'), workspace('ready')),
    'PUT /v2/cogents/ply-1/hermes/lifecycle': workspace('provisioning'),
  })
  assert.equal(await startWorkspace(() => {}, 0), 'ws-1')
  assert.equal(calls[1], 'PUT /v2/cogents/ply-1/hermes/lifecycle {"desired_state":"running"}')
})

test('a refused request, a failed workspace and an account with no player are each told to the person', async (t) => {
  fakeSoftmax(t, { 'GET /v2/hermes': 403 })
  await assert.rejects(startWorkspace(() => {}, 0), /Softmax answered 403 to GET \/v2\/hermes/)

  fakeSoftmax(t, { 'GET /v2/hermes': workspace('failed', 'out of capacity') })
  await assert.rejects(startWorkspace(() => {}, 0), /failed to start: out of capacity/)

  fakeSoftmax(t, { 'GET /v2/hermes': null, 'GET /players': [] })
  await assert.rejects(startWorkspace(() => {}, 0), /no active player/)
})
