import test from 'node:test'
import assert from 'node:assert/strict'

import { AideError } from '../js/aide-client.js'
import { createCogentSession, requestWording } from '../js/cogent-session.js'

// Contract files, at https://softmax.com/docs/aide: protocol.md, asyncapi.json, examples.json.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
// The game's scope: asyncapi.json `Scope`, the Coworld form. The ids are the test's own.
const SCOPE = { scope: 'coworld', coworld: 'coworld-test', league: 'league-test' }
const OTHER_SCOPE = { scope: 'coworld', coworld: 'coworld-test', league: 'another-league' }

const RUNNING_ID = '55555555-5555-4555-8555-555555555555'
const RESUMED_ID = '66666666-6666-4666-8666-666666666666'
const FINISHED_ID = '77777777-7777-4777-8777-777777777777'
const HELD_ID = '88888888-8888-4888-8888-888888888888'

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

/** A `ChatRequest` record with every required field (asyncapi.json `ChatRequest`). */
function requestRecord(requestId, status, extra = {}) {
  return {
    request_id: requestId,
    session_id: 'session-1',
    scope: SCOPE,
    origin: 'user',
    status,
    created_at: '2026-11-05T14:01:00Z',
    updated_at: '2026-11-05T14:01:02Z',
    revision: 1,
    attempt: 0,
    in_history: true,
    error: null,
    waiting: null,
    ...extra,
  }
}

/** A `Session` record (asyncapi.json `Session`); `requests` and `revision` are optional there. */
function sessionRecord(requests = [], extra = {}) {
  const terminal = ['completed', 'cancelled', 'failed', 'interrupted']
  return {
    id: 'session-1',
    parent_session_id: null,
    title: 'Pinball',
    started_at: '2026-11-05T14:00:00Z',
    ended_at: null,
    active_request_ids: requests
      .filter((request) => !terminal.includes(request.status))
      .map((request) => request.request_id),
    pending: [],
    scope: SCOPE,
    revision: 1,
    requests,
    ...extra,
  }
}

/** A `state.changed` notification that replaces the session (asyncapi.json `StateChanged`). */
function sessionChanged(item) {
  return {
    resource: 'sessions',
    epoch: 'workspace-1',
    previous_revision: item.revision - 1,
    revision: item.revision,
    change: 'upsert',
    item,
  }
}

function textEvent(seq, attempt = 0) {
  // asyncapi.json `ChatEvent`, kind `text.delta`.
  return { attempt, seq, at: '2026-11-05T14:10:01Z', kind: 'text.delta', completion_id: 'run-1:0', delta: 'x' }
}

function notFound() {
  return new AideError('not_found', 'No such record.')
}

/**
 * A stand-in for the AIDE client with the same surface the session uses:
 * request, onBound, onClosed, onNotification and handle.
 * `session` is the record the pretend workspace holds; `replies` can be overridden per method.
 */
function fakeClient() {
  const boundListeners = []
  const closedListeners = []
  const notificationListeners = {}
  const handlers = {}

  const client = {
    calls: [],
    session: sessionRecord(),

    // Result shapes: asyncapi.json `<method>Result` for each method.
    replies: {
      'session.open': () => ({ session: client.session }),
      'state.get': (params) => {
        if (params.resource === 'sessions') {
          if (params.id !== client.session.id) throw notFound()
          return { resource: 'sessions', epoch: 'workspace-1', revision: client.session.revision ?? 1, item: client.session }
        }
        const item = (client.session.requests ?? []).find((request) => request.request_id === params.id)
        if (!item) throw notFound()
        return { resource: 'requests', epoch: 'workspace-1', revision: item.revision, item }
      },
      'chat.history': () => ({ items: [], next_cursor: null }),
      'chat.events': (params) => ({
        session_id: params.session_id,
        request_id: params.request_id,
        events: [],
        next: params.after,
        done: false,
      }),
      'chat.send': (params, id) => ({ accepted: true, session_id: params.session_id, request_id: id }),
      'chat.cancel': () => ({ requested: true }),
      'input.respond': () => ({ applied: true }),
      'clarification.response': () => ({ applied: true }),
      'surface.event': () => ({ data: {} }),
    },

    request(method, params, id) {
      client.calls.push({ method, params: structuredClone(params), id })
      try {
        return Promise.resolve(client.replies[method](params, id))
      } catch (error) {
        return Promise.reject(error)
      }
    },
    onBound: (listener) => void boundListeners.push(listener),
    onClosed: (listener) => void closedListeners.push(listener),
    onNotification(method, listener) {
      notificationListeners[method] ??= []
      notificationListeners[method].push(listener)
    },
    handle: (method, handler) => void (handlers[method] = handler),

    // What the test drives.
    bind() {
      for (const listener of boundListeners) {
        listener({ frontendId: '11111111-1111-4111-8111-111111111111', maxMessageBytes: 1048576 })
      }
    },
    close() {
      for (const listener of closedListeners) listener()
    },
    notify(method, params) {
      for (const listener of notificationListeners[method] ?? []) listener(params)
    },
    /** A request from the agent. Like the real client, no handler means `unsupported`. */
    callAgent(method, params, id = '99999999-9999-4999-8999-999999999999') {
      if (!handlers[method]) throw new AideError('unsupported', `${method} is not supported.`)
      return handlers[method](params, id)
    },
    sent: (method) => client.calls.filter((call) => call.method === method),
    forget: () => void (client.calls.length = 0),
  }
  return client
}

/** The game API: records what the session asks of it, and lets the test speak for the game. */
function fakeApi() {
  const listeners = []
  const api = {
    calls: [],
    create(name, source) {
      api.calls.push(['create', name, source])
      return { name, version: 1 }
    },
    update(name, source) {
      api.calls.push(['update', name, source])
      return { name, version: 2 }
    },
    policies: () => [{ name: 'catcher', version: 2 }],
    handle(request) {
      api.calls.push(['handle', request])
      if (request.method === 'teleport') return Promise.resolve({ error: { code: 'unknown_method', message: 'There is no method teleport.' } })
      return Promise.resolve({ result: { score: 100 } })
    },
    onMessage: (listener) => void listeners.push(listener),
    unsubscribe: () => void api.calls.push(['unsubscribe']),
    says(message) {
      for (const listener of listeners) listener(message)
    },
  }
  return api
}

function refusal(code) {
  return () => {
    throw Object.assign(new Error(`refused: ${code}`), { code })
  }
}

/** Lets every promise the session is waiting on finish. */
async function settle() {
  for (let turn = 0; turn < 10; turn += 1) {
    await new Promise((resolve) => setImmediate(resolve))
  }
}

function start(options = {}) {
  const client = options.client ?? fakeClient()
  const storage = options.storage ?? fakeStorage()
  const api = fakeApi()
  const session = createCogentSession({ client, storage, api, scope: SCOPE })
  return { client, storage, session, api }
}

async function startBound(options = {}) {
  const started = start(options)
  started.client.bind()
  await settle()
  return started
}

function requestState(session, id) {
  return session.state.requests.find((request) => request.id === id)
}

// ---------------------------------------------------------------------------------------------
// Opening, reloading and reconnecting
// ---------------------------------------------------------------------------------------------

test('the first connection opens a session as the pinball-arena client, then reads history', async () => {
  const { client, session } = await startBound()

  assert.deepEqual(
    client.calls.map((call) => call.method),
    ['session.open', 'chat.history'],
  )
  // asyncapi.json `session_openParams`, `Scope` (all three keys, the nulls included) and `Client`.
  assert.deepEqual(client.calls[0].params, {
    scope: SCOPE,
    client: { id: 'pinball-arena', kind: 'web', guide: 'pinball-arena' },
  })
  // asyncapi.json `chat_historyParams`: `session_id` and `scope` are required.
  assert.equal(client.calls[1].params.session_id, 'session-1')
  assert.deepEqual(client.calls[1].params.scope, SCOPE)
  assert.equal(session.state.sessionId, 'session-1')
  assert.equal(session.state.cogent, 'ready')
})

test('after a reload the page reads the session, then history, then events for each open request', async () => {
  const storage = fakeStorage()
  await startBound({ storage })

  // The page reloads: a new session object and a new connection over the same storage.
  const client = fakeClient()
  client.session = sessionRecord([
    requestRecord(RUNNING_ID, 'running'),
    requestRecord(RESUMED_ID, 'running', { attempt: 2 }),
    requestRecord(FINISHED_ID, 'completed'),
  ])
  const { session } = await startBound({ storage, client })

  // protocol.md "Reads are authoritative": session, then chat.history, then chat.events per open request.
  assert.deepEqual(
    client.calls.map((call) => call.method),
    ['state.get', 'chat.history', 'chat.events', 'chat.events'],
  )
  // asyncapi.json `state_getParams`; examples.json "Reload → read requests → show failure → retry".
  assert.deepEqual(client.calls[0].params, { resource: 'sessions', id: 'session-1', scope: SCOPE })
  assert.equal(client.calls[1].params.session_id, 'session-1')
  assert.deepEqual(client.calls[1].params.scope, SCOPE)
  // asyncapi.json `chat_eventsParams`; `{attempt:n, seq:0}` is the start of attempt n (protocol.md "Chat events").
  assert.deepEqual(client.calls[2].params, {
    session_id: 'session-1',
    request_id: RUNNING_ID,
    after: { attempt: 0, seq: 0 },
    scope: SCOPE,
  })
  assert.deepEqual(client.calls[3].params, {
    session_id: 'session-1',
    request_id: RESUMED_ID,
    after: { attempt: 2, seq: 0 },
    scope: SCOPE,
  })

  assert.equal(requestState(session, RUNNING_ID).status, 'running')
  assert.equal(requestState(session, FINISHED_ID).status, 'completed')
  assert.equal(session.state.cogent, 'busy')
})

test('a stored session the workspace no longer has is replaced by a new one', async () => {
  const storage = fakeStorage()
  await startBound({ storage })

  const client = fakeClient()
  client.session = sessionRecord([], { id: 'session-2' })
  const { session } = await startBound({ storage, client })

  assert.deepEqual(
    client.calls.map((call) => call.method),
    ['state.get', 'session.open', 'chat.history'],
  )
  assert.equal(client.calls[2].params.session_id, 'session-2')
  assert.equal(session.state.sessionId, 'session-2')
})

test('a stored session that was opened in another scope is replaced by a new one', async () => {
  const storage = fakeStorage()
  await startBound({ storage })

  // protocol.md "Session scope": a session keeps its scope, and a read with another scope is `forbidden`.
  const client = fakeClient()
  const readSession = client.replies['state.get']
  client.replies['state.get'] = (params) => {
    if (params.resource === 'sessions') throw new AideError('forbidden', 'The scope does not match.')
    return readSession(params)
  }
  client.session = sessionRecord([], { id: 'session-2' })
  const { session } = await startBound({ storage, client })

  assert.deepEqual(
    client.calls.map((call) => call.method),
    ['state.get', 'session.open', 'chat.history'],
  )
  assert.equal(session.state.sessionId, 'session-2')
})

test('after a reconnect events are read from the last cursor the page applied', async () => {
  const { client, session } = await startBound()
  const id = session.send('more ramps')
  await settle()
  // asyncapi.json `chat_eventParams`: {session_id, request_id, event}.
  client.notify('chat.event', { session_id: 'session-1', request_id: id, event: textEvent(1) })
  client.notify('chat.event', { session_id: 'session-1', request_id: id, event: textEvent(2) })

  client.close()
  client.session = sessionRecord([requestRecord(id, 'running')])
  client.forget()
  client.bind()
  await settle()

  assert.deepEqual(
    client.calls.map((call) => call.method),
    ['state.get', 'chat.history', 'chat.events'],
  )
  assert.deepEqual(client.calls[2].params, {
    session_id: 'session-1',
    request_id: id,
    after: { attempt: 0, seq: 2 },
    scope: SCOPE,
  })
})

test('a session record without the optional request list still gets its open requests read', async () => {
  const client = fakeClient()
  // protocol.md "Chat requests": `Session.requests` and revisions are optional; earlier producers omit them.
  const { requests, revision, ...olderRecord } = sessionRecord()
  client.session = { ...olderRecord, active_request_ids: [RUNNING_ID] }
  await startBound({ client })

  assert.deepEqual(
    client.sent('chat.events').map((call) => call.params),
    [{ session_id: 'session-1', request_id: RUNNING_ID, after: { attempt: 0, seq: 0 }, scope: SCOPE }],
  )
})

test('an event that arrives out of order makes the page read the missed ones', async () => {
  const { client, session } = await startBound()
  const id = session.send('more ramps')
  await settle()
  client.replies['chat.events'] = (params) => ({
    session_id: params.session_id,
    request_id: params.request_id,
    events: params.after.seq === 1 ? [textEvent(2), textEvent(3)] : [],
    next: params.after.seq === 1 ? { attempt: 0, seq: 3 } : params.after,
    done: false,
  })

  client.notify('chat.event', { session_id: 'session-1', request_id: id, event: textEvent(1) })
  await settle()
  assert.equal(client.sent('chat.events').length, 0)

  // protocol.md "Chat events": any cursor other than the next one means missed events.
  client.notify('chat.event', { session_id: 'session-1', request_id: id, event: textEvent(3) })
  await settle()
  assert.deepEqual(client.sent('chat.events')[0].params, {
    session_id: 'session-1',
    request_id: id,
    after: { attempt: 0, seq: 1 },
    scope: SCOPE,
  })

  const readsAfterTheGap = client.sent('chat.events').length
  client.notify('chat.event', { session_id: 'session-1', request_id: id, event: textEvent(4) })
  await settle()
  assert.equal(client.sent('chat.events').length, readsAfterTheGap, 'seq 4 follows seq 3: no read')
})

test('an idle connection sends no keepalive reads', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] })
  const { client } = await startBound()
  client.forget()

  // protocol.md "Reads are authoritative": "There are no keepalive reads."
  t.mock.timers.tick(10 * 60 * 1000)
  await settle()
  assert.deepEqual(client.calls, [])
})

test('on aide.presence the page rereads each open request, but not one held until later', async () => {
  const client = fakeClient()
  client.session = sessionRecord([
    requestRecord(RUNNING_ID, 'running'),
    requestRecord(HELD_ID, 'waiting', { waiting: { reason: 'rate_limited', until: '2999-01-01T00:00:00Z' } }),
  ])
  await startBound({ client })
  client.forget()

  // asyncapi.json `aide_presenceParams`.
  client.notify('aide.presence', { present: true })
  await settle()

  // protocol.md: "On any `aide.presence`, read every open request's record and its events from the last applied cursor."
  assert.deepEqual(
    client.sent('state.get').map((call) => call.params),
    [{ resource: 'requests', id: RUNNING_ID, scope: SCOPE }],
  )
  assert.deepEqual(
    client.sent('chat.events').map((call) => call.params),
    [{ session_id: 'session-1', request_id: RUNNING_ID, after: { attempt: 0, seq: 0 }, scope: SCOPE }],
  )
  // protocol.md: "A frontend must not read a `waiting` request before its `waiting.until`".
  assert.ok(!JSON.stringify(client.calls).includes(HELD_ID))
})

// ---------------------------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------------------------

test('a chat message goes out with chat.send and carries only what the person wrote', async () => {
  const { client, session } = await startBound()
  const id = session.send('more ramps')
  await settle()

  const [sent] = client.sent('chat.send')
  assert.match(id, UUID)
  assert.equal(sent.id, id)
  // asyncapi.json `chat_sendParams`. `instructions` is optional, and the game puts nothing in the chat.
  assert.deepEqual(sent.params, {
    session_id: 'session-1',
    messages: [{ role: 'user', content: 'more ramps' }],
    scope: SCOPE,
  })
  assert.equal(requestState(session, id).status, 'queued')
  assert.equal(session.state.cogent, 'busy')
})

test('a request moves through queued, running, waiting and completed as the workspace reports it', async () => {
  const { client, session } = await startBound()
  let changes = 0
  session.onChange(() => (changes += 1))
  const id = session.send('more ramps')
  await settle()
  assert.equal(requestState(session, id).status, 'queued')
  assert.ok(changes > 0)

  // protocol.md "Chat requests": a request change arrives as a `state.changed` upsert of its session.
  client.notify(
    'state.changed',
    sessionChanged(sessionRecord([requestRecord(id, 'running', { revision: 4 })], { revision: 4 })),
  )
  assert.equal(requestState(session, id).status, 'running')

  const held = requestRecord(id, 'waiting', {
    revision: 5,
    waiting: { reason: 'rate_limited', until: '2026-11-05T15:00:00Z' },
  })
  client.notify('state.changed', sessionChanged(sessionRecord([held], { revision: 5 })))
  assert.equal(requestState(session, id).status, 'waiting')
  assert.match(requestState(session, id).wording, /^Provider busy, retrying after /)
  assert.equal(session.state.cogent, 'busy')

  // asyncapi.json `chat_finishedParams`.
  client.notify('chat.finished', {
    session_id: 'session-1',
    request_id: id,
    status: 'completed',
    cursor: { attempt: 1, seq: 6 },
    revision: 7,
  })
  assert.equal(requestState(session, id).status, 'completed')
  assert.equal(session.state.cogent, 'ready')

  // protocol.md: "Install a pushed record only when its `revision` is newer than the installed one."
  client.notify(
    'state.changed',
    sessionChanged(sessionRecord([requestRecord(id, 'running', { revision: 6 })], { revision: 6 })),
  )
  assert.equal(requestState(session, id).status, 'completed')
})

test('failed and interrupted requests are shown as such', async () => {
  const { client, session } = await startBound()
  const failedId = session.send('more ramps')
  const interruptedId = session.send('and a magnet')
  await settle()

  // asyncapi.json `chat_finishedParams` (failed and interrupted carry `error`) and `RequestError` (`class` is optional).
  client.notify('chat.finished', {
    session_id: 'session-1',
    request_id: failedId,
    status: 'failed',
    error: { class: 'misconfigured', code: 'misconfigured', message: 'No model is configured for this workspace.' },
  })
  client.notify('chat.finished', {
    session_id: 'session-1',
    request_id: interruptedId,
    status: 'interrupted',
    error: { code: 'interrupted', message: 'The workspace restarted.' },
  })

  assert.equal(requestState(session, failedId).status, 'failed')
  assert.equal(requestState(session, failedId).wording, 'Workspace model setup is broken')
  assert.equal(requestState(session, interruptedId).status, 'interrupted')
  assert.equal(session.state.cogent, 'ready')
})

test('the wording for a held or failed request is the wording the contract gives', () => {
  // protocol.md "Chat requests", the table of `ErrorClass` values and frontend wording.
  const held = (reason, until = '2026-11-05T15:00:00Z') => requestRecord(RUNNING_ID, 'waiting', { waiting: { reason, until } })
  const failed = (errorClass) =>
    requestRecord(RUNNING_ID, 'failed', { error: { class: errorClass, code: errorClass, message: 'Detail.' } })

  assert.match(requestWording(held('budget_exhausted')), /^Out of model budget until \S/)
  assert.match(requestWording(held('rate_limited')), /^Provider busy, retrying after \S/)
  assert.match(requestWording(held('provider_unavailable')), /^Provider down, retrying after \S/)
  assert.equal(requestWording(failed('too_large')), 'Conversation too long; start a new one')
  assert.equal(requestWording(failed('misconfigured')), 'Workspace model setup is broken')

  // `waiting.until` may be null (asyncapi.json `RequestWaiting`).
  const openEnded = requestWording(held('budget_exhausted', null))
  assert.match(openEnded, /^Out of model budget/)
  assert.doesNotMatch(openEnded, /null|undefined|Invalid/)

  // "Frontends word the documented values and treat others as a generic failure."
  const generic = requestWording(failed('solar_flare'))
  assert.ok(generic.length > 0)
  assert.notEqual(generic, requestWording(failed('too_large')))
  assert.notEqual(generic, requestWording(failed('misconfigured')))
  assert.equal(requestWording(failed('some_other_new_class')), generic)
})

test('a chat message refused for lack of model budget is shown as failed, with the reason', async () => {
  const { client, session } = await startBound()
  // examples.json "Inference unavailable at send".
  client.replies['chat.send'] = () => {
    throw new AideError('inference_unavailable', "The workspace's model allowance is exhausted.", {
      reason: 'budget_exhausted',
      until: '2026-11-06T00:00:00Z',
    })
  }
  const id = session.send('more ramps')
  await settle()

  assert.equal(requestState(session, id).status, 'failed')
  assert.match(requestState(session, id).wording, /^Out of model budget until \S/)
})

test('cancel asks the workspace to stop one request', async () => {
  const { client, session } = await startBound()
  const id = session.send('more ramps')
  await settle()
  session.cancel(id)
  await settle()

  // asyncapi.json `chat_cancelParams`.
  assert.deepEqual(
    client.sent('chat.cancel').map((call) => call.params),
    [{ session_id: 'session-1', request_id: id, scope: SCOPE }],
  )
})

test('messages come from history and from chat.message, in order and without duplicates', async () => {
  const client = fakeClient()
  // asyncapi.json `MessageRecord`: `request_id`, `kind`, `reasoning` and `created_at` are optional.
  const record = (sequence, role, content, extra = {}) => ({
    id: `message-${sequence}`,
    session_id: 'session-1',
    sequence,
    message: { role, content },
    ...extra,
  })
  // protocol.md "Chat": history pages backwards from the newest record.
  client.replies['chat.history'] = () => ({
    items: [record(2, 'assistant', 'Two ramps coming up.', { kind: 'message' }), record(1, 'user', 'more ramps')],
    next_cursor: null,
  })
  const { session } = await startBound({ client })

  client.notify('chat.message', record(3, 'assistant', 'Done. Try the left orbit.'))
  client.notify('chat.message', record(3, 'assistant', 'Done. Try the left orbit.'))
  // protocol.md "Chat": "Frontends normally hide `continuation` and `failed_turn`."
  client.notify('chat.message', record(4, 'user', 'Continue the earlier work.', { kind: 'continuation' }))

  assert.deepEqual(
    session.state.messages.map((item) => [item.sequence, item.message.content]),
    [
      [1, 'more ramps'],
      [2, 'Two ramps coming up.'],
      [3, 'Done. Try the left orbit.'],
    ],
  )
})

// ---------------------------------------------------------------------------------------------
// Asleep, busy, disconnected; retries
// ---------------------------------------------------------------------------------------------

test('a lost connection is reported, and a message written meanwhile goes out when it returns', async () => {
  const { client, session } = start()
  assert.equal(session.state.cogent, 'connecting')
  client.bind()
  await settle()

  let changes = 0
  session.onChange(() => (changes += 1))
  client.close()
  assert.equal(session.state.cogent, 'disconnected')
  assert.ok(changes > 0)

  const id = session.send('more ramps')
  await settle()
  assert.match(id, UUID)
  assert.equal(client.sent('chat.send').length, 0)
  assert.equal(requestState(session, id).status, 'sending')

  client.bind()
  await settle()
  assert.equal(client.sent('chat.send').length, 1)
  assert.equal(client.sent('chat.send')[0].id, id)
  assert.equal(requestState(session, id).status, 'queued')
})

test('a chat message whose outcome is uncertain is sent again under the same id', async () => {
  const { client, session } = await startBound()
  const accept = client.replies['chat.send']
  // The connection dropped after the frame went out: the client rejects with outcome unknown.
  client.replies['chat.send'] = () => {
    throw new AideError('unavailable', 'The connection was lost.', { outcome: 'unknown' })
  }
  const id = session.send('more ramps')
  await settle()
  client.close()
  assert.equal(requestState(session, id).status, 'sending')

  client.replies['chat.send'] = accept
  client.bind()
  await settle()

  // protocol.md: "Retry the identical state-changing request ID to recover an uncertain acceptance."
  const sends = client.sent('chat.send')
  assert.equal(sends.length, 2)
  assert.equal(sends[1].id, id)
  assert.deepEqual(sends[1].params, sends[0].params)
  assert.equal(requestState(session, id).status, 'queued')
})

test('a sleeping cogent is reported, and the message goes out under the same id once it is back', async () => {
  const { client, session } = await startBound()

  client.notify('aide.presence', { present: false })
  assert.equal(session.state.cogent, 'asleep')
  client.notify('aide.presence', { present: true })
  await settle()
  assert.equal(session.state.cogent, 'ready')

  const accept = client.replies['chat.send']
  // protocol.md "Requests and refusal": the relay reports `starting` with `retry_after_ms` while the workspace wakes.
  client.replies['chat.send'] = () => {
    throw new AideError('starting', 'The workspace is starting.', { outcome: 'not_delivered', retry_after_ms: 60000 })
  }
  const id = session.send('more ramps')
  await settle()
  assert.equal(session.state.cogent, 'asleep')
  assert.equal(requestState(session, id).status, 'sending')

  client.replies['chat.send'] = accept
  client.notify('aide.presence', { present: true })
  await settle()

  const sends = client.sent('chat.send')
  assert.equal(sends.length, 2)
  assert.equal(sends[1].id, id)
  assert.deepEqual(sends[1].params, sends[0].params)
  assert.equal(requestState(session, id).status, 'queued')
  assert.equal(session.state.cogent, 'busy')
})

test('an unsupported request is never sent again unchanged', async () => {
  const { client, session } = await startBound()
  client.replies['chat.send'] = () => {
    throw new AideError('unsupported', 'Chat is not supported.')
  }
  client.replies['surface.event'] = () => {
    throw new AideError('unsupported', 'Surface events are not supported.')
  }
  const id = session.send('more ramps')
  session.reportEpisode({ episode: 1, score: 100 })
  await settle()
  assert.equal(requestState(session, id).status, 'failed')

  client.close()
  client.bind()
  await settle()
  client.notify('aide.presence', { present: true })
  await settle()

  // protocol.md "Requests and refusal": callers "must not automatically retry unchanged unsupported requests".
  assert.equal(client.sent('chat.send').length, 1)
  assert.equal(client.sent('surface.event').length, 1)
})

// ---------------------------------------------------------------------------------------------
// Questions and approvals
// ---------------------------------------------------------------------------------------------

test('a question from the cogent is taken at once and answered later with clarification.response', async () => {
  const { client, session } = await startBound()
  const questionId = '77777777-7777-4777-8777-777777777777'

  // examples.json "Non-blocking clarification → later answer"; `session_id` is optional and left out here.
  const reply = client.callAgent('clarification.request', { prompt: 'Which side should the ramp go on?', scope: SCOPE }, questionId)
  assert.deepEqual(reply, { accepted: true })
  assert.deepEqual(session.state.questions, [{ id: questionId, prompt: 'Which side should the ramp go on?', scope: SCOPE }])
  assert.equal(client.sent('clarification.response').length, 0)

  session.answerQuestion(questionId, 'The left side.')
  await settle()

  // asyncapi.json `clarification_responseParams`: `request_id`, `answer`, and the scope of the question repeated.
  assert.deepEqual(
    client.sent('clarification.response').map((call) => call.params),
    [{ request_id: questionId, answer: 'The left side.', scope: SCOPE }],
  )
  assert.deepEqual(session.state.questions, [])
})

test('after a reconnect an open question can still be answered and an answered one is not sent again', async () => {
  const { client, session } = await startBound()
  const answeredId = '77777777-7777-4777-8777-777777777777'
  const openId = '88888888-8888-4888-8888-888888888888'
  client.callAgent('clarification.request', { prompt: 'Left or right?', session_id: 'session-1', scope: SCOPE }, answeredId)
  client.callAgent('clarification.request', { prompt: 'How many bumpers?', session_id: 'session-1', scope: SCOPE }, openId)
  session.answerQuestion(answeredId, 'Left.')
  await settle()

  client.close()
  client.forget()
  client.bind()
  await settle()

  // After a reconnect the page only reads: nothing tied to the old connection goes out again.
  assert.deepEqual(
    client.calls.map((call) => call.method),
    ['state.get', 'chat.history'],
  )
  // protocol.md "Non-blocking clarifications": a question still held after a reconnect may be answered.
  assert.deepEqual(session.state.questions, [{ id: openId, prompt: 'How many bumpers?', scope: SCOPE }])
  session.answerQuestion(openId, 'Three.')
  await settle()
  assert.deepEqual(
    client.sent('clarification.response').map((call) => call.params),
    [{ request_id: openId, answer: 'Three.', scope: SCOPE }],
  )
})

test('a pending approval is shown and answered with input.respond', async () => {
  const { client, session } = await startBound()
  // examples.json "Approval: allow once"; asyncapi.json `PendingInput` (`description` and `command` are optional).
  const detailed = {
    request_id: '44444444-4444-4444-8444-444444444444',
    kind: 'approval',
    prompt: 'Delete the build directory',
    description: 'Removes generated build output before rebuilding.',
    command: 'rm -rf build',
    choices: ['once', 'deny'],
  }
  const bare = {
    request_id: '33333333-3333-4333-8333-333333333333',
    kind: 'approval',
    prompt: 'Read the score table',
    choices: ['once', 'deny'],
  }
  client.notify('state.changed', sessionChanged(sessionRecord([], { revision: 4, pending: [detailed, bare] })))
  assert.deepEqual(session.state.approvals, [detailed, bare])

  session.answerApproval(detailed.request_id, 'once')
  session.answerApproval(bare.request_id, 'deny')
  await settle()

  // asyncapi.json `input_respondParams` and `InputResponse`.
  assert.deepEqual(
    client.sent('input.respond').map((call) => call.params),
    [
      {
        session_id: 'session-1',
        request_id: detailed.request_id,
        response: { kind: 'approval', choice: 'once' },
        scope: SCOPE,
      },
      {
        session_id: 'session-1',
        request_id: bare.request_id,
        response: { kind: 'approval', choice: 'deny' },
        scope: SCOPE,
      },
    ],
  )
})

// ---------------------------------------------------------------------------------------------
// Programs and game API requests from the cogent, and what the game tells it
// ---------------------------------------------------------------------------------------------

test('policy.create and policy.update deploy the program and reply with name and version', async () => {
  const { client, api } = await startBound()
  // examples.json "Deploy a policy → update it".
  const source = "' @seat flipper\nflip(left, 1)"
  assert.deepEqual(client.callAgent('policy.create', { name: 'catcher', scope: SCOPE, blob: { kind: 'text', text: source } }), {
    name: 'catcher',
    version: 1,
  })
  assert.deepEqual(client.callAgent('policy.update', { name: 'catcher', scope: SCOPE, blob: { kind: 'text', text: 'PRINT 2' } }), {
    name: 'catcher',
    version: 2,
  })
  assert.deepEqual(api.calls, [['create', 'catcher', source], ['update', 'catcher', 'PRINT 2']])
})

test('policy.list answers with the name and version of every deployed program', async () => {
  const { client, api } = await startBound()
  // asyncapi.json `policy_listParams` and `policy_listResult`: only `scope` in, `{items}` out.
  assert.deepEqual(client.callAgent('policy.list', { scope: SCOPE }), { items: [{ name: 'catcher', version: 2 }] })
  // The page holds no policy that plays in another scope, and none at all is an empty list, not `unsupported`.
  assert.deepEqual(client.callAgent('policy.list', { scope: OTHER_SCOPE }), { items: [] })
  assert.deepEqual(client.callAgent('policy.list', { scope: { scope: 'workspace', coworld: null, league: null } }), { items: [] })
  api.policies = () => []
  assert.deepEqual(client.callAgent('policy.list', { scope: SCOPE }), { items: [] })
})

test('a policy the store refuses is answered with the contract error code', async () => {
  const { client, api } = await startBound()
  const policy = { name: 'ramps', scope: SCOPE, blob: { kind: 'text', text: 'PRINT 1' } }
  // protocol.md "Policies": conflict, not_found, too_large and forbidden. Anything else is unsupported.
  for (const code of ['conflict', 'too_large']) {
    api.create = refusal(code)
    assert.throws(() => client.callAgent('policy.create', policy), (error) => error instanceof AideError && error.code === code)
  }
  for (const code of ['not_found', 'too_large', 'forbidden']) {
    api.update = refusal(code)
    assert.throws(() => client.callAgent('policy.update', policy), { code })
  }
  api.create = refusal('invalid')
  assert.throws(() => client.callAgent('policy.create', policy), { code: 'unsupported' })
  api.create = () => {
    throw new Error('QuotaExceededError')
  }
  assert.throws(() => client.callAgent('policy.create', policy), { code: 'unsupported' })
  // "Larger or binary content needs a new blob `kind`".
  const archive = { name: 'ramps', scope: SCOPE, blob: { kind: 'archive', url: 'https://example.invalid/ramps.zip' } }
  assert.throws(() => client.callAgent('policy.create', archive), { code: 'unsupported' })
})

test('a surface.act carries one game API request, and the reply carries its answer', async () => {
  const { client, api } = await startBound()
  // asyncapi.json `surface_actParams` and `surface_actResult`: the object travels in `data`.
  const reply = await client.callAgent('surface.act', { scope: SCOPE, data: { method: 'state' } })
  assert.deepEqual(reply, { data: { result: { score: 100 } } })
  assert.deepEqual(api.calls, [['handle', { method: 'state' }]])

  // "A recipient that does not understand an object returns `unsupported`."
  await assert.rejects(client.callAgent('surface.act', { scope: SCOPE, data: { method: 'teleport' } }), { code: 'unsupported' })
})

test('a policy or a game request for another scope is refused with forbidden and does nothing', async () => {
  const { client, api } = await startBound()
  // protocol.md "Session scope": "The recipient checks the value".
  const policy = { name: 'ramps', scope: OTHER_SCOPE, blob: { kind: 'text', text: 'PRINT 1' } }
  assert.throws(() => client.callAgent('policy.create', policy), { code: 'forbidden' })
  assert.throws(() => client.callAgent('policy.update', policy), { code: 'forbidden' })
  assert.throws(() => client.callAgent('surface.act', { scope: OTHER_SCOPE, data: { method: 'restart' } }), { code: 'forbidden' })
  assert.throws(() => client.callAgent('surface.act', { data: { method: 'restart' } }), { code: 'forbidden' })
  assert.deepEqual(api.calls, [])
})

test('browser.snapshot and browser.act are answered with unsupported', async () => {
  const { client } = await startBound()
  assert.throws(() => client.callAgent('browser.snapshot', {}), { code: 'unsupported' })
  assert.throws(() => client.callAgent('browser.act', { action: 'click' }), { code: 'unsupported' })
})

test('the messages of the game go out one surface.event at a time, the rest together in the next', async () => {
  const { client, api } = await startBound()
  let answer
  client.replies['surface.event'] = () => new Promise((resolve) => (answer = resolve))

  api.says({ type: 'hud', score: 10 })
  api.says({ type: 'hud', score: 20 })
  api.says({ type: 'events', tick: 5, events: [{ kind: 'hit', value: 0 }] })
  await settle()
  assert.equal(client.sent('surface.event').length, 1)

  answer({ data: {} })
  await settle()
  assert.deepEqual(
    client.sent('surface.event').map((call) => call.params),
    [
      { scope: SCOPE, data: { kind: 'game.messages', messages: [{ type: 'hud', score: 10 }] } },
      {
        scope: SCOPE,
        data: {
          kind: 'game.messages',
          messages: [
            { type: 'hud', score: 20 },
            { type: 'events', tick: 5, events: [{ kind: 'hit', value: 0 }] },
          ],
        },
      },
    ],
  )
})

test('when the connection closes, the subscription ends and waiting messages are dropped', async () => {
  const { client, api } = await startBound()
  client.replies['surface.event'] = () => new Promise(() => {})
  api.says({ type: 'hud', score: 10 })
  api.says({ type: 'hud', score: 20 })
  client.close()
  assert.deepEqual(api.calls, [['unsubscribe']])
  assert.equal(client.sent('surface.event').length, 1)
})

test('each Episode summary is one surface.event', async () => {
  const { client, session } = await startBound()
  const summary = {
    episode: 3,
    program: 'ramps',
    version: 2,
    score: 41200,
    ball_seconds: [41, 12, 77],
    hits: { bumper: 14, ramp: 3 },
    rules_fired: { 'jackpot-quest': 2 },
    rejected_edits: [{ reason: 'over budget', count: 1 }],
    error: null,
  }
  session.reportEpisode(summary)
  await settle()

  // asyncapi.json `surface_eventParams`: the page's object travels in `data`, beside the scope.
  const sent = client.sent('surface.event')
  assert.equal(sent.length, 1)
  assert.match(sent[0].id, UUID)
  assert.deepEqual(sent[0].params, { scope: SCOPE, data: { kind: 'episode.summary', ...summary } })
})

test('a program failure is one surface.event', async () => {
  const { client, session } = await startBound()
  const failure = {
    program: 'ramps',
    version: 2,
    error: 'Line 40: unknown piece SPINER',
    last_output: ['BUILDING RAMPS', 'PLACING SPINNER'],
  }
  session.reportProgramFailure(failure)
  await settle()

  assert.deepEqual(
    client.sent('surface.event').map((call) => call.params),
    [{ scope: SCOPE, data: { kind: 'program.failed', ...failure } }],
  )
})
