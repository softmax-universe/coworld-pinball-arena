import test from 'node:test'
import assert from 'node:assert/strict'

import { AideError, createAideClient } from '../js/aide-client.js'

// Contract files, at https://softmax.com/docs/aide: protocol.md, asyncapi.json, examples.json.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const WORKSPACE_SCOPE = { scope: 'workspace', coworld: null, league: null }

// protocol.md "WebSocket binding": the first server frame.
const BINDING = {
  binding: {
    frontend_id: '11111111-1111-4111-8111-111111111111',
    version: '1.0.0',
    max_message_bytes: 1048576,
  },
}

// The six requests the agent may send to the page (protocol.md "Public surface").
const AGENT_REQUESTS = [
  'policy.create',
  'policy.update',
  'surface.act',
  'browser.snapshot',
  'browser.act',
  'clarification.request',
]

/** A stand-in for a browser WebSocket. It serves both `onmessage`-style and `addEventListener`. */
class FakeSocket {
  sent = []
  closed = false
  readyState = 0
  listeners = {}

  addEventListener(type, listener) {
    this.listeners[type] ??= []
    this.listeners[type].push(listener)
  }

  send(text) {
    assert.equal(typeof text, 'string', 'frames are text, never binary')
    this.sent.push(text)
  }

  close() {
    if (this.closed) return
    this.closed = true
    this.readyState = 3
    this.emit('close', { code: 1000 })
  }

  emit(type, event) {
    this[`on${type}`]?.(event)
    for (const listener of this.listeners[type] ?? []) listener(event)
  }

  open() {
    this.readyState = 1
    this.emit('open', {})
  }

  receive(message) {
    this.emit('message', { data: JSON.stringify(message) })
  }

  drop() {
    this.closed = true
    this.readyState = 3
    this.emit('close', { code: 1006 })
  }

  frames() {
    return this.sent.map((text) => JSON.parse(text))
  }
}

/** A client whose socket is open and bound, plus every socket it has opened. */
function boundClient() {
  const sockets = []
  const protocols = []
  const client = createAideClient((protocol) => {
    protocols.push(protocol)
    sockets.push(new FakeSocket())
    return sockets.at(-1)
  })
  client.connect()
  sockets[0].open()
  sockets[0].receive(BINDING)
  return { client, sockets, protocols, socket: sockets[0] }
}

test('connect opens the socket with the subprotocol aide.1.0.0', () => {
  // protocol.md "WebSocket binding": "subprotocol `aide.1.0.0`".
  const { protocols } = boundClient()
  assert.deepEqual(protocols, ['aide.1.0.0'])
})

test('the first frame gives the connection id and the message size limit', () => {
  const socket = new FakeSocket()
  const client = createAideClient(() => socket)
  const bindings = []
  client.onBound((binding) => bindings.push(binding))

  client.connect()
  socket.open()
  assert.deepEqual(bindings, [])
  socket.receive(BINDING)

  // asyncapi.json `frontendBinding`.
  assert.deepEqual(bindings, [
    { frontendId: '11111111-1111-4111-8111-111111111111', maxMessageBytes: 1048576 },
  ])
  assert.deepEqual(socket.sent, [], 'the binding frame is not a request and gets no reply')
})

test('a request is one JSON-RPC 2.0 object with a UUID id, and its result resolves the promise', async () => {
  const { client, socket } = boundClient()
  // examples.json "Open a session as a named client".
  const params = { scope: WORKSPACE_SCOPE, client: { id: 'softmax-play', kind: 'web', guide: 'client-play' } }
  const opened = client.request('session.open', params)
  const history = client.request('chat.history', { session_id: 'session-1', scope: WORKSPACE_SCOPE })

  // protocol.md "Envelopes and validation": one object per delivery, never a batch.
  assert.equal(socket.sent.length, 2)
  const [openFrame, historyFrame] = socket.frames()
  assert.match(openFrame.id, UUID)
  assert.match(historyFrame.id, UUID)
  assert.notEqual(openFrame.id, historyFrame.id)
  assert.deepEqual(openFrame, { jsonrpc: '2.0', id: openFrame.id, method: 'session.open', params })

  // Replies are matched by id, whatever order they come back in.
  socket.receive({ jsonrpc: '2.0', id: historyFrame.id, result: { items: [], next_cursor: null } })
  socket.receive({ jsonrpc: '2.0', id: openFrame.id, result: { session: { id: 'session-1' } } })
  assert.deepEqual(await history, { items: [], next_cursor: null })
  assert.deepEqual(await opened, { session: { id: 'session-1' } })
})

test('a request can be sent under an id the caller chose, so a retry can reuse it', async () => {
  const { client, socket } = boundClient()
  const id = '22222222-2222-4222-8222-222222222222'
  const params = { kind: 'episode.summary', score: 100 }

  const firstTry = client.request('surface.event', params, id)
  // protocol.md "Requests and refusal": after dispatch a transport failure is `unavailable`, outcome unknown.
  socket.receive({
    jsonrpc: '2.0',
    id,
    error: { code: -32000, message: 'The workspace went away.', data: { code: 'unavailable', outcome: 'unknown' } },
  })
  await assert.rejects(firstTry, { code: 'unavailable' })

  const secondTry = client.request('surface.event', params, id)
  socket.receive({ jsonrpc: '2.0', id, result: {} })
  assert.deepEqual(await secondTry, {})

  // protocol.md "Identity, acceptance, and cancellation": an identical retry keeps the request id.
  assert.deepEqual(socket.frames(), [
    { jsonrpc: '2.0', id, method: 'surface.event', params },
    { jsonrpc: '2.0', id, method: 'surface.event', params },
  ])
})

test('an error reply rejects the promise with the contract error code and its data', async () => {
  const { client, socket } = boundClient()
  const sent = client.request('chat.send', {
    session_id: 'session-1',
    messages: [{ role: 'user', content: 'Inspect the page.' }],
    scope: WORKSPACE_SCOPE,
  })
  // examples.json "Inference unavailable at send"; asyncapi.json `Error`.
  socket.receive({
    jsonrpc: '2.0',
    id: socket.frames()[0].id,
    error: {
      code: -32000,
      message: "The workspace's model allowance is exhausted.",
      data: { code: 'inference_unavailable', reason: 'budget_exhausted', until: '2026-11-06T00:00:00Z' },
    },
  })

  await assert.rejects(sent, (error) => {
    assert.ok(error instanceof AideError)
    assert.equal(error.code, 'inference_unavailable')
    assert.equal(error.rpcCode, -32000)
    assert.equal(error.message, "The workspace's model allowance is exhausted.")
    assert.deepEqual(error.data, {
      code: 'inference_unavailable',
      reason: 'budget_exhausted',
      until: '2026-11-06T00:00:00Z',
    })
    return true
  })
})

test('a protocol error, which has no data, still rejects cleanly', async () => {
  const { client, socket } = boundClient()
  const sent = client.request('chat.cancel', { session_id: 'session-1' })
  // asyncapi.json `Error`: codes -32700..-32603 carry only `code` and `message`.
  socket.receive({
    jsonrpc: '2.0',
    id: socket.frames()[0].id,
    error: { code: -32602, message: 'Invalid params.' },
  })

  await assert.rejects(sent, (error) => {
    assert.ok(error instanceof AideError)
    assert.equal(error.rpcCode, -32602)
    assert.equal(error.code, null)
    assert.equal(error.message, 'Invalid params.')
    return true
  })
})

test('notifications reach their listeners, and unknown ones are ignored', () => {
  const { client, socket } = boundClient()
  const presence = []
  const finished = []
  client.onNotification('aide.presence', (params) => presence.push(params))
  client.onNotification('chat.finished', (params) => finished.push(params))

  // asyncapi.json `aide_presenceParams` and `chat_finishedParams` (cursor and revision are optional).
  socket.receive({ jsonrpc: '2.0', method: 'aide.presence', params: { present: false } })
  socket.receive({
    jsonrpc: '2.0',
    method: 'chat.finished',
    params: { session_id: 'session-1', request_id: '22222222-2222-4222-8222-222222222222', status: 'completed' },
  })
  // protocol.md "Version and discovery": frontends must ignore unknown notifications.
  socket.receive({ jsonrpc: '2.0', method: 'weather.changed', params: { sky: 'grey' } })
  // A notification nobody listens for is also fine.
  socket.receive({ jsonrpc: '2.0', method: 'chat.chunk', params: { session_id: 'session-1' } })

  assert.deepEqual(presence, [{ present: false }])
  assert.deepEqual(finished, [
    { session_id: 'session-1', request_id: '22222222-2222-4222-8222-222222222222', status: 'completed' },
  ])
  assert.deepEqual(socket.sent, [], 'notifications are never answered')
})

test('a handler answers a request from the agent with its result under the same id', () => {
  const { client, socket } = boundClient()
  const received = []
  client.handle('policy.create', (params, id) => {
    received.push({ params, id })
    return { name: params.name, version: 1 }
  })

  // examples.json "Deploy a policy → update it"; asyncapi.json `Policy`, `PolicyVersion`.
  const id = '99999999-9999-4999-8999-999999999999'
  const params = {
    name: 'greedy-collector',
    blob: { kind: 'text', text: "def act(observation):\n    return 'collect'\n" },
  }
  socket.receive({ jsonrpc: '2.0', id, method: 'policy.create', params })

  assert.deepEqual(received, [{ params, id }])
  assert.deepEqual(socket.frames(), [
    { jsonrpc: '2.0', id, result: { name: 'greedy-collector', version: 1 } },
  ])
})

test('a handler that throws an AideError answers with that contract error', () => {
  const { client, socket } = boundClient()
  client.handle('policy.create', () => {
    throw new AideError('conflict', 'A program named greedy-collector is already stored.')
  })

  const id = '99999999-9999-4999-8999-999999999999'
  socket.receive({
    jsonrpc: '2.0',
    id,
    method: 'policy.create',
    params: { name: 'greedy-collector', blob: { kind: 'text', text: 'PRINT 1' } },
  })

  // asyncapi.json `Error`: application errors are -32000 with the code in `data.code`, and no extra fields.
  assert.deepEqual(socket.frames(), [
    {
      jsonrpc: '2.0',
      id,
      error: {
        code: -32000,
        message: 'A program named greedy-collector is already stored.',
        data: { code: 'conflict' },
      },
    },
  ])
})

test('a handler may answer later with a promise, and its failure is a reply too', async () => {
  const { client, socket } = boundClient()
  let finish
  client.handle('surface.act', ({ data }) =>
    data.method === 'state' ? new Promise((resolve) => (finish = resolve)) : Promise.reject(new AideError('unsupported', 'Not understood.')),
  )
  const id = '99999999-9999-4999-8999-999999999999'
  const otherId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  socket.receive({ jsonrpc: '2.0', id, method: 'surface.act', params: { data: { method: 'state' } } })
  socket.receive({ jsonrpc: '2.0', id: otherId, method: 'surface.act', params: { data: { method: 'teleport' } } })
  assert.deepEqual(socket.frames(), [])

  finish({ data: { result: { score: 100 } } })
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(socket.frames(), [
    { jsonrpc: '2.0', id: otherId, error: { code: -32000, message: 'Not understood.', data: { code: 'unsupported' } } },
    { jsonrpc: '2.0', id, result: { data: { result: { score: 100 } } } },
  ])
})

test('a handler that fails some other way still sends a reply', () => {
  const { client, socket } = boundClient()
  client.handle('policy.update', () => {
    throw new TypeError('a bug in the page')
  })

  const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  assert.doesNotThrow(() =>
    socket.receive({
      jsonrpc: '2.0',
      id,
      method: 'policy.update',
      params: { name: 'greedy-collector', blob: { kind: 'text', text: 'PRINT 1' } },
    }),
  )

  // protocol.md "Requests and refusal": "internal errors use ... `-32603`", which carries no `data`.
  const [reply] = socket.frames()
  assert.equal(socket.sent.length, 1)
  assert.equal(reply.id, id)
  assert.equal(reply.error.code, -32603)
  assert.equal(typeof reply.error.message, 'string')
  assert.deepEqual(Object.keys(reply.error).sort(), ['code', 'message'])
})

test('a request from the agent that has no handler is answered with unsupported', () => {
  const { socket } = boundClient()
  AGENT_REQUESTS.forEach((method, index) => {
    const id = `5555555${index}-5555-4555-8555-555555555555`
    // browser.snapshot has empty params (asyncapi.json); the others carry an object.
    socket.receive({ jsonrpc: '2.0', id, method, params: {} })

    // protocol.md "Requests and refusal": the canonical `unsupported` reply.
    const reply = socket.frames()[index]
    assert.equal(reply.jsonrpc, '2.0')
    assert.equal(reply.id, id)
    assert.equal(reply.error.code, -32000)
    assert.equal(typeof reply.error.message, 'string')
    assert.deepEqual(reply.error.data, { code: 'unsupported' })
    assert.deepEqual(Object.keys(reply).sort(), ['error', 'id', 'jsonrpc'])
  })
  assert.equal(socket.sent.length, AGENT_REQUESTS.length)
})

test('a frame larger than the size limit is refused and not sent', async () => {
  const { client, socket } = boundClient()
  // 600,000 two-byte characters: under the limit counted in characters, over it in UTF-8 bytes.
  const text = 'é'.repeat(600000)
  const sent = client.request('chat.send', {
    session_id: 'session-1',
    messages: [{ role: 'user', content: text }],
    scope: WORKSPACE_SCOPE,
  })

  // protocol.md "WebSocket binding": senders check the size and report it instead of sending.
  await assert.rejects(sent, { code: 'too_large' })
  assert.deepEqual(socket.sent, [])

  // The connection is still usable for a frame that fits.
  client.request('surface.event', { kind: 'episode.summary' }).catch(() => {})
  assert.equal(socket.sent.length, 1)
})

test('losing the connection rejects waiting requests as uncertain and tells the page', async () => {
  const { client, socket } = boundClient()
  let closedCount = 0
  client.onClosed(() => (closedCount += 1))
  const waiting = client.request('surface.event', { kind: 'episode.summary' })

  socket.drop()

  // protocol.md "Identity, acceptance, and cancellation": "A disconnect after dispatch means unknown outcome".
  await assert.rejects(waiting, (error) => {
    assert.equal(error.code, 'unavailable')
    assert.equal(error.data.outcome, 'unknown')
    return true
  })
  assert.equal(closedCount, 1)
})

test('a request made while there is no bound connection rejects and sends nothing', async () => {
  const socket = new FakeSocket()
  const client = createAideClient(() => socket)

  const beforeConnect = client.request('surface.event', { kind: 'episode.summary' })
  client.connect()
  socket.open()
  const beforeBinding = client.request('surface.event', { kind: 'episode.summary' })
  socket.receive(BINDING)
  socket.drop()
  const afterClose = client.request('surface.event', { kind: 'episode.summary' })

  for (const request of [beforeConnect, beforeBinding, afterClose]) {
    await assert.rejects(request, (error) => {
      assert.equal(error.code, 'unavailable')
      assert.equal(error.data.outcome, 'not_delivered')
      return true
    })
  }
  assert.deepEqual(socket.sent, [])
})

test('connecting again opens a new socket and binds again', async () => {
  const { client, sockets, protocols } = boundClient()
  const bindings = []
  client.onBound((binding) => bindings.push(binding))
  sockets[0].drop()

  client.connect()
  assert.equal(sockets.length, 2)
  assert.deepEqual(protocols, ['aide.1.0.0', 'aide.1.0.0'])
  sockets[1].open()
  sockets[1].receive({
    binding: { ...BINDING.binding, frontend_id: '33333333-3333-4333-8333-333333333333' },
  })
  assert.deepEqual(bindings, [
    { frontendId: '33333333-3333-4333-8333-333333333333', maxMessageBytes: 1048576 },
  ])

  const cancelled = client.request('chat.cancel', {
    session_id: 'session-1',
    request_id: '22222222-2222-4222-8222-222222222222',
    scope: WORKSPACE_SCOPE,
  })
  assert.equal(sockets[0].sent.length, 0)
  assert.equal(sockets[1].sent.length, 1)
  // asyncapi.json `chat_cancelResult`.
  sockets[1].receive({ jsonrpc: '2.0', id: sockets[1].frames()[0].id, result: { requested: true } })
  assert.deepEqual(await cancelled, { requested: true })
})
