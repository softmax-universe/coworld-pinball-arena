/**
 * The conversation with the person's cogent: chat, the cogent's questions and approvals, the table
 * programs it sends, and the reports the game sends back.
 *
 * It sits between the other two modules. `aide-client.js` carries the messages; this module decides
 * which to send and when, following the AIDE 1.0.0 contract (the design document's Appendix D lists
 * the rules). Programs the cogent sends go into the store from `programs.js`.
 *
 * No DOM and no timers. The chat panel reads `session.state` and redraws on `onChange`. Nothing
 * here retries on a clock: what could not be sent goes out again when the connection or the
 * workspace comes back, or when the page calls `retry()`.
 */

import { AideError } from './aide-client.js'

const SESSION_KEY = 'pinball-arena.session'
const SCOPE = { scope: 'workspace', coworld: null, league: null }
const CLIENT = { id: 'pinball-arena', kind: 'web', guide: 'pinball-arena' }
const MAX_GUIDE_CHARACTERS = 64000

const OPEN_STATUSES = ['queued', 'running', 'waiting']
const FINISHED_STATUSES = ['completed', 'cancelled', 'failed', 'interrupted']

/** Replies that say the request did not get through for now. The same request is sent again later. */
const SEND_AGAIN_CODES = ['unavailable', 'starting', 'paused']
/** Refusals of a table program that the store names with the contract's own error codes. */
const PROGRAM_REFUSALS = ['conflict', 'not_found', 'too_large', 'forbidden']

// The contract's wording for a held request, split so the time can be left out when it is unknown.
const HOLD_WORDING = {
  budget_exhausted: ['Out of model budget', 'until'],
  rate_limited: ['Provider busy, retrying', 'after'],
  provider_unavailable: ['Provider down, retrying', 'after'],
}
const FAILURE_WORDING = {
  too_large: 'Conversation too long; start a new one',
  misconfigured: 'Workspace model setup is broken',
}
// The contract gives no words for these.
const STATUS_WORDING = {
  sending: 'Sending',
  queued: 'Queued',
  running: 'Working',
  completed: '',
  cancelled: 'Cancelled',
  failed: 'The cogent could not finish this',
  interrupted: 'Interrupted: the workspace restarted',
}

function holdWording(reason, until) {
  const [words, joiner] = HOLD_WORDING[reason] ?? ['On hold', 'until']
  if (!until) return words
  const time = new Date(until).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' })
  return `${words} ${joiner} ${time}`
}

/** The line the chat panel shows beside a request, from its `ChatRequest` record. */
export function requestWording(request) {
  if (request.status === 'waiting') return holdWording(request.waiting?.reason, request.waiting?.until)
  if (request.status === 'failed') return FAILURE_WORDING[request.error?.class] ?? STATUS_WORDING.failed
  return STATUS_WORDING[request.status] ?? ''
}

/**
 * `client` is an AIDE client, `programs` a program store, `storage` is localStorage (it remembers
 * the session id across reloads) and `guide` is the Arena BASIC guide sent with every chat message.
 * The caller connects the client; the session starts work each time the client reports a connection.
 */
export function createCogentSession({ client, programs, storage, guide }) {
  if (guide.length > MAX_GUIDE_CHARACTERS) {
    throw new Error(`The guide is ${guide.length} characters; chat.send allows ${MAX_GUIDE_CHARACTERS}.`)
  }

  const state = {
    /** `connecting`, `ready`, `busy`, `asleep` or `disconnected`. */
    cogent: 'connecting',
    sessionId: storage.getItem(SESSION_KEY),
    /** The contract's `MessageRecord`s, oldest first. Only the newest page of history is read. */
    messages: [],
    /**
     * `{ id, status, wording, until, text }`. `status` is the contract's request status, or
     * `sending` before the workspace has accepted the message. `until` is when a `waiting` request
     * may resume. `text` is there for the messages this page sent.
     */
    requests: [],
    /** The contract's `PendingInput` records of kind `approval`. */
    approvals: [],
    /** `{ id, prompt }` for each question the cogent asked and the person has not answered. */
    questions: [],
  }

  let connected = false
  let hasConnected = false
  /** True once the session has been read on this connection; nothing else is sent before that. */
  let sessionRead = false
  let readingSession = false
  /** False from the moment the relay says the workspace is away until something gets through. */
  let workspaceAwake = true
  let sessionRevision
  /** Requests that have not got through yet: `{ id, method, buildParams, onResult, onRefused }`. */
  const outbox = []
  const answeredApprovals = new Set()
  // Per chat request: the revision of the installed record, the last event applied, and whether a
  // read of its events is under way.
  const revisions = new Map()
  const cursors = new Map()
  const readingEvents = new Set()
  const changeListeners = []
  const programListeners = []

  function changed() {
    state.cogent = cogentState()
    for (const listener of changeListeners) listener(state)
  }

  function cogentState() {
    if (!connected) return hasConnected ? 'disconnected' : 'connecting'
    if (!workspaceAwake) return 'asleep'
    if (!sessionRead) return 'connecting'
    return state.requests.some((request) => OPEN_STATUSES.includes(request.status)) ? 'busy' : 'ready'
  }

  const findRequest = (id) => state.requests.find((request) => request.id === id)

  /** A pushed record can arrive late. One older than what is installed is ignored. */
  const isOlder = (revision, installed) => revision !== undefined && installed !== undefined && revision < installed

  // -------------------------------------------------------------------------------------------
  // Sending
  // -------------------------------------------------------------------------------------------

  /**
   * Sends a request that must not be lost. If it cannot go now, or the reply says it did not get
   * through, it waits in the outbox and goes again under the same id, which the workspace uses to
   * avoid doing the work twice. Any other refusal is final: `unsupported` is never sent again.
   */
  function deliver(item) {
    if (!sessionRead) {
      outbox.push(item)
      return
    }
    client.request(item.method, item.buildParams(), item.id).then(
      (result) => {
        workspaceAwake = true
        item.onResult?.(result)
        changed()
      },
      (error) => {
        if (SEND_AGAIN_CODES.includes(error.code)) {
          noteWorkspaceAway(error)
          outbox.push(item)
        } else {
          item.onRefused?.(error)
        }
        changed()
      },
    )
  }

  function post(method, buildParams, reactions = {}) {
    deliver({ id: crypto.randomUUID(), method, buildParams, ...reactions })
  }

  function sendOutbox() {
    for (const item of outbox.splice(0)) deliver(item)
  }

  function noteWorkspaceAway(error) {
    if (error.code === 'starting' || error.code === 'paused') workspaceAwake = false
  }

  // -------------------------------------------------------------------------------------------
  // Reading: the workspace's records are the truth, and notifications only bring them sooner
  // -------------------------------------------------------------------------------------------

  /**
   * After every connect: read the session, then history, then the events of each open request.
   * A stored session the workspace no longer has is replaced by a new one.
   */
  function readSession() {
    if (readingSession) return
    readingSession = true

    const openNew = () => client.request('session.open', { scope: SCOPE, client: CLIENT }).then((result) => result.session)
    const session = state.sessionId
      ? client.request('state.get', { resource: 'sessions', id: state.sessionId, scope: SCOPE }).then(
          (result) => result.item,
          (error) => {
            if (error.code === 'not_found') return openNew()
            throw error
          },
        )
      : openNew()

    session
      .then((record) => {
        installSession(record)
        return client.request('chat.history', { session_id: record.id, scope: SCOPE })
      })
      .then((history) => {
        history.items.forEach(addMessage)
        sessionRead = true
        workspaceAwake = true
        readableRequests().forEach(readEvents)
        sendOutbox()
      })
      .catch(noteWorkspaceAway)
      .finally(() => {
        readingSession = false
        changed()
      })
  }

  function installSession(record) {
    if (record.id !== state.sessionId) {
      // A different session: nothing shown from the old one belongs to it.
      state.messages = []
      state.requests = state.requests.filter((request) => request.status === 'sending')
      sessionRevision = undefined
      state.sessionId = record.id
      storage.setItem(SESSION_KEY, record.id)
    }
    if (isOlder(record.revision, sessionRevision)) return
    sessionRevision = record.revision

    state.approvals = record.pending.filter(
      (input) => input.kind === 'approval' && !answeredApprovals.has(input.request_id),
    )
    for (const request of record.requests ?? []) installRequest(request)
    // An earlier producer sends no request records. Its open requests are then known only by id,
    // and `running` is the closest status for work that has not ended.
    for (const id of record.active_request_ids) {
      if (!findRequest(id)) installRequest({ request_id: id, status: 'running' })
    }
  }

  function installRequest(record) {
    const id = record.request_id
    let request = findRequest(id)
    if (!request) {
      request = { id }
      state.requests.push(request)
      cursors.set(id, { attempt: record.attempt ?? 0, seq: 0 })
    }
    if (isOlder(record.revision, revisions.get(id))) return
    // A notification with no revision cannot be compared, but a finished request never reopens.
    if (FINISHED_STATUSES.includes(request.status) && !FINISHED_STATUSES.includes(record.status)) return
    if (record.revision !== undefined) revisions.set(id, record.revision)

    request.status = record.status
    request.wording = requestWording(record)
    request.until = record.waiting?.until ?? null
  }

  function addMessage(record) {
    // These two kinds are the workspace's own prompts and notices, not conversation.
    if (record.kind === 'continuation' || record.kind === 'failed_turn') return
    if (state.messages.some((message) => message.sequence === record.sequence)) return
    state.messages.push(record)
    state.messages.sort((a, b) => a.sequence - b.sequence)
  }

  /**
   * The open requests that may be read now. The contract forbids reading a held request before
   * its `until`, because a read wakes the workspace.
   */
  function readableRequests() {
    return state.requests.filter(
      (request) => OPEN_STATUSES.includes(request.status) && !(request.until && Date.parse(request.until) > Date.now()),
    )
  }

  function rereadOpenRequests() {
    for (const request of readableRequests()) {
      client.request('state.get', { resource: 'requests', id: request.id, scope: SCOPE }).then((result) => {
        installRequest(result.item)
        changed()
      }, noteWorkspaceAway)
      readEvents(request)
    }
  }

  /**
   * Reads a request's events after the last one applied. The page shows no live progress, so the
   * events matter for two things: the cursor, which is how a missed notification is noticed, and
   * the `finished` event, which gives the outcome.
   */
  function readEvents({ id }) {
    if (readingEvents.has(id)) return
    readingEvents.add(id)
    const after = cursors.get(id)
    client.request('chat.events', { session_id: state.sessionId, request_id: id, after, scope: SCOPE }).then(
      (page) => {
        readingEvents.delete(id)
        cursors.set(id, page.next)
        page.events.forEach((event) => applyEvent(id, event))
        changed()
        if (page.events.length > 0 && !page.done) readEvents({ id })
      },
      (error) => {
        readingEvents.delete(id)
        noteWorkspaceAway(error)
      },
    )
  }

  function applyEvent(id, event) {
    if (event.kind === 'finished') installRequest({ request_id: id, status: event.status, error: event.error })
  }

  /** Brings everything up to date after the workspace or the connection may have been away. */
  function catchUp() {
    if (!connected) return
    if (!sessionRead) {
      readSession()
    } else {
      rereadOpenRequests()
      sendOutbox()
    }
  }

  // -------------------------------------------------------------------------------------------
  // What the client reports
  // -------------------------------------------------------------------------------------------

  client.onBound(() => {
    connected = true
    hasConnected = true
    workspaceAwake = true
    changed()
    readSession()
  })

  client.onClosed(() => {
    connected = false
    sessionRead = false
    changed()
  })

  client.onNotification('aide.presence', ({ present }) => {
    workspaceAwake = present
    // The contract asks for a reread of the open requests on every presence change. What is
    // waiting to be sent goes only when the workspace is back.
    if (present) catchUp()
    else if (sessionRead) rereadOpenRequests()
    changed()
  })

  client.onNotification('state.changed', (update) => {
    // A change to a chat request arrives as a new copy of its session.
    if (update.resource !== 'sessions' || update.change !== 'upsert' || update.item.id !== state.sessionId) return
    installSession(update.item)
    changed()
  })

  client.onNotification('chat.finished', ({ request_id, status, error, revision }) => {
    installRequest({ request_id, status, error, revision })
    changed()
  })

  client.onNotification('chat.message', (record) => {
    addMessage(record)
    changed()
  })

  client.onNotification('chat.event', ({ request_id: id, event }) => {
    if (readingEvents.has(id)) return
    const last = cursors.get(id) ?? { attempt: 0, seq: 0 }
    cursors.set(id, last)
    const follows =
      (event.attempt === last.attempt && event.seq === last.seq + 1) ||
      // The first event after a held request resumed.
      (event.attempt === last.attempt + 1 && event.seq === 1)
    if (!follows) {
      readEvents({ id })
      return
    }
    cursors.set(id, { attempt: event.attempt, seq: event.seq })
    applyEvent(id, event)
    changed()
  })

  // A question holds no work on the cogent's side. It is taken at once and answered whenever the
  // person gets to it.
  client.handle('clarification.request', ({ prompt }, id) => {
    state.questions.push({ id, prompt })
    changed()
    return { accepted: true }
  })

  /** Stores a program from the cogent and makes it the one that plays next. The person is not asked. */
  function storeProgram(storeIt) {
    return ({ name, blob }) => {
      if (blob.kind !== 'text') throw new AideError('unsupported', 'This page stores only text programs.')
      let stored
      try {
        stored = storeIt(name, blob.text)
      } catch (error) {
        // Anything the store did not refuse by name, such as full browser storage, means the page cannot deploy.
        throw new AideError(PROGRAM_REFUSALS.includes(error.code) ? error.code : 'unsupported', error.message)
      }
      programs.select(name)
      for (const listener of programListeners) listener(stored)
      return stored
    }
  }
  client.handle('policy.create', storeProgram((name, source) => programs.create(name, source)))
  client.handle('policy.update', storeProgram((name, source) => programs.update(name, source)))

  // surface.act, browser.snapshot and browser.act get no handler, so the client answers `unsupported`.

  // -------------------------------------------------------------------------------------------
  // What the page can do
  // -------------------------------------------------------------------------------------------

  /** Sends a chat message and returns the id of its request, which appears in `state.requests`. */
  function send(text) {
    const id = crypto.randomUUID()
    const request = { id, status: 'sending', wording: STATUS_WORDING.sending, until: null, text }
    state.requests.push(request)
    deliver({
      id,
      method: 'chat.send',
      buildParams: () => ({
        session_id: state.sessionId,
        messages: [{ role: 'user', content: text }],
        scope: SCOPE,
        instructions: guide,
      }),
      onResult() {
        // A notification may already have reported a later status.
        if (request.status === 'sending') installRequest({ request_id: id, status: 'queued' })
      },
      onRefused(error) {
        request.status = 'failed'
        // No model work can start: the refusal says why with the same reasons a held request has.
        request.wording =
          error.code === 'inference_unavailable' && error.data.reason
            ? holdWording(error.data.reason, error.data.until)
            : error.message
      },
    })
    changed()
    return id
  }

  function cancel(requestId) {
    post('chat.cancel', () => ({ session_id: state.sessionId, request_id: requestId, scope: SCOPE }))
  }

  function answerQuestion(questionId, answer) {
    state.questions = state.questions.filter((question) => question.id !== questionId)
    post('clarification.response', () => ({ request_id: questionId, answer }))
    changed()
  }

  /** `choice` is `once` or `deny`. */
  function answerApproval(inputId, choice) {
    answeredApprovals.add(inputId)
    state.approvals = state.approvals.filter((input) => input.request_id !== inputId)
    post('input.respond', () => ({
      session_id: state.sessionId,
      request_id: inputId,
      response: { kind: 'approval', choice },
      scope: SCOPE,
    }))
    changed()
  }

  return {
    state,
    /** `listener(state)` runs after every change to `state`. */
    onChange: (listener) => void changeListeners.push(listener),
    /** `listener({ name, version })` runs when the cogent's program has been stored and selected. */
    onProgram: (listener) => void programListeners.push(listener),
    send,
    cancel,
    answerQuestion,
    answerApproval,
    /** One report per Episode, never one per table event: the relay allows few requests at a time. */
    reportEpisode: (summary) => post('surface.event', () => ({ kind: 'episode.summary', ...summary })),
    reportProgramFailure: (failure) => post('surface.event', () => ({ kind: 'program.failed', ...failure })),
    /**
     * Sends again what is waiting and rereads the open requests. For the page to call when there is
     * a reason: the person asks, or the `until` of a held request has passed (one read then lets
     * the workspace resume it). Not for polling: the contract forbids keepalive reads.
     */
    retry: catchUp,
  }
}
