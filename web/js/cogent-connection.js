/**
 * Finds the signed-in person's cogent workspace and keeps a connection to it.
 *
 * `cogent-session.js` has no timers of its own, so the clock lives here: connecting again after
 * the connection closes, and asking the session to continue once a held request's time has come.
 */

import { createAideClient } from './aide-client.js'
import { cogentSocketUrl } from './cogent-auth.js'
import { createCogentSession } from './cogent-session.js'

const WORKSPACE_URL = '/softmax-cogent/api/v2/hermes'
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

/** Resolves with the id of the person's workspace, or null when they have none or it cannot be found. */
export function findWorkspaceId() {
  return fetch(WORKSPACE_URL, { credentials: 'same-origin' })
    .then((response) => (response.ok ? response.json() : null))
    .then((workspace) => workspace?.provisioning_id ?? null)
    .catch(() => null)
}

/**
 * Opens the connection and returns `{ session, tryAgain }`. `onUnreachable(flag)` tells the page
 * when repeated connections have failed, and when one works again.
 */
export function connectCogent({ workspaceId, guide, api, storage, onUnreachable }) {
  const client = createAideClient((subprotocol) => new WebSocket(cogentSocketUrl(workspaceId), subprotocol))
  const session = createCogentSession({ client, storage, guide, api })

  let failures = 0
  let reconnectTimer = null
  let resumeTimer = null

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

  session.onChange((state) => {
    clearTimeout(resumeTimer)
    const resumeAt = nextResumeTime(state.requests, Date.now())
    if (resumeAt !== null) resumeTimer = setTimeout(session.retry, Math.min(resumeAt - Date.now(), LONGEST_TIMER_MS))
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
