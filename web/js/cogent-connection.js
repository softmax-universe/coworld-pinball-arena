/**
 * Finds the signed-in person's cogent workspace and keeps a connection to it.
 *
 * `cogent-session.js` has no timers of its own, so the clock lives here: connecting again after
 * the connection closes, and asking the session to continue once a held request's time has come.
 */

import { createAideClient } from './aide-client.js'
import { cogentSocketUrl } from './cogent-auth.js'
import { createCogentSession } from './cogent-session.js'

/** The Softmax API routes that this site's server part passes on (server/README.md). */
const API = '/softmax-cogent/api'
const FIRST_RECONNECT_MS = 1000
const LONGEST_RECONNECT_MS = 30000
/** After this many failed connections in a row the page says it cannot reach the cogent. */
const UNREACHABLE_AFTER = 3
/** The longest delay a browser timer takes; a longer one would fire at once. */
const LONGEST_TIMER_MS = 2 ** 31 - 1

/** How long to wait before reconnecting after `failures` failed connections in a row: 1 s, 2 s, 4 s, up to 30 s. */
export function reconnectDelay(failures) {
  return Math.min(FIRST_RECONNECT_MS * 2 ** failures, LONGEST_RECONNECT_MS)
}

/**
 * The time (in milliseconds, like `Date.now()`) at which the session should be asked to continue:
 * the earliest `until` still ahead among the held requests, or null when there is none. A held
 * request must not be read before its `until`; one read after it lets the workspace resume it.
 */
export function nextResumeTime(requests, now) {
  const times = requests
    .filter((request) => request.status === 'waiting' && request.until)
    .map((request) => Date.parse(request.until))
    .filter((time) => time > now)
  return times.length > 0 ? Math.min(...times) : null
}

/** A workspace in one of these states runs again when the page asks for it. */
const ASLEEP = ['stopped', 'stopping', 'suspended']
const READY_POLL_MS = 3000
/** A new workspace is usually ready within a minute or two. */
const READY_WAIT_MS = 5 * 60 * 1000

/** One call of the Softmax API through this site's server part. Resolves with the JSON body; rejects with words for the person. */
function softmax(path, method = 'GET', body) {
  const init = { method, credentials: 'same-origin' }
  if (body !== undefined) Object.assign(init, { headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
  return fetch(API + path, init).then((response) => {
    if (!response.ok) throw new Error(`Softmax answered ${response.status} to ${method} ${path}.`)
    return response.json()
  })
}

/** The person's workspace, or null when they have none: Softmax answers that with `null` or with 404. */
function currentWorkspace() {
  return fetch(`${API}/v2/hermes`, { credentials: 'same-origin' }).then((response) => {
    if (response.status === 404) return null
    if (!response.ok) throw new Error(`Softmax answered ${response.status} to GET /v2/hermes.`)
    return response.json()
  })
}

/** Creates a workspace for an account that has none, on its default player. */
function createWorkspace() {
  return softmax('/players').then((players) => {
    const active = players.filter((player) => !player.disabled_at)
    const player = active.find((candidate) => candidate.is_default) ?? active[0]
    if (!player) throw new Error('Your Softmax account has no active player, so a cogent cannot be started for it.')
    const cogent = `/v2/cogents/${encodeURIComponent(player.id)}/hermes`
    return softmax('/v2/cogents', 'POST', { player_id: player.id }).then(() => softmax(cogent, 'PUT', {}))
  })
}

/** Resolves with the workspace once it is ready, reading it again every few seconds until then. */
function whenReady(workspace, pollMs, deadline) {
  if (workspace.status === 'ready') return workspace
  if (workspace.status === 'failed') throw new Error(`Your cogent workspace failed to start: ${workspace.detail ?? 'no reason given'}.`)
  if (Date.now() > deadline) throw new Error('Your cogent workspace is still starting. Reload in a few minutes.')
  return new Promise((resolve) => setTimeout(resolve, pollMs))
    .then(currentWorkspace)
    .then((next) => whenReady(next ?? workspace, pollMs, deadline))
}

/**
 * Resolves with the id of the person's workspace, running and ready. An account with no workspace
 * gets one, and a paused or sleeping workspace is started again: signing in on this site is the
 * person asking for their cogent. `onProgress(text)` says what is being waited for. Rejects with
 * an `Error` whose message is for the person.
 */
export function startWorkspace(onProgress, pollMs = READY_POLL_MS) {
  return currentWorkspace()
    .then((workspace) => {
      if (!workspace) {
        onProgress('Starting a cogent for you. This takes a minute or two…')
        return createWorkspace()
      }
      if (!ASLEEP.includes(workspace.status)) return workspace
      onProgress('Waking your cogent…')
      const lifecycle = `/v2/cogents/${encodeURIComponent(workspace.player_id)}/hermes/lifecycle`
      return softmax(lifecycle, 'PUT', { desired_state: 'running' })
    })
    .then((workspace) => whenReady(workspace, pollMs, Date.now() + READY_WAIT_MS))
    .then((workspace) => workspace.provisioning_id)
}

/**
 * Opens the connection and returns `{ session, tryAgain }`. `onUnreachable(flag)` tells the page
 * when repeated connections have failed, and when one works again.
 */
export function connectCogent({ workspaceId, api, scope, storage, onUnreachable }) {
  const client = createAideClient((subprotocol) => new WebSocket(cogentSocketUrl(workspaceId), subprotocol))
  const session = createCogentSession({ client, storage, api, scope })

  let failures = 0
  let reconnectTimer = null
  let resumeTimer = null
  let wakeTimer = null

  client.onBound(() => {
    failures = 0
    onUnreachable(false)
  })

  client.onClosed(() => {
    reconnectTimer = setTimeout(reconnect, reconnectDelay(failures))
    failures += 1
    if (failures >= UNREACHABLE_AFTER) onUnreachable(true)
  })

  function reconnect() {
    reconnectTimer = null
    client.connect()
  }

  // A line in the browser console for every change of the cogent's state, with how long the last
  // one lasted. This is how the time a wake takes is measured.
  let lastState = session.state.cogent
  let lastStateAt = Date.now()
  session.onChange((state) => {
    if (state.cogent !== lastState) {
      const seconds = ((Date.now() - lastStateAt) / 1000).toFixed(1)
      console.info(`[cogent] ${lastState} -> ${state.cogent} after ${seconds} s`)
      lastState = state.cogent
      lastStateAt = Date.now()
    }
  })

  session.onChange((state) => {
    clearTimeout(resumeTimer)
    const resumeAt = nextResumeTime(state.requests, Date.now())
    if (resumeAt !== null) resumeTimer = setTimeout(session.retry, Math.min(resumeAt - Date.now(), LONGEST_TIMER_MS))
    // A waking workspace is tried again when the relay said to, in case its return is not announced.
    clearTimeout(wakeTimer)
    if (state.cogent === 'waking' && state.retryAfterMs) wakeTimer = setTimeout(session.retry, state.retryAfterMs)
  })

  client.connect()

  return {
    session,
    /** For the person's "try again": reconnects at once if the page is waiting to, and continues what was held. */
    tryAgain() {
      if (reconnectTimer !== null) {
        clearTimeout(reconnectTimer)
        reconnect()
      }
      session.retry()
    },
  }
}
