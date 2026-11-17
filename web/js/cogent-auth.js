/**
 * Softmax sign-in for the page, and the address of the cogent's WebSocket.
 *
 * The page never holds the Softmax credential. The site's server part keeps it in an encrypted
 * HttpOnly cookie and adds it to the requests it passes on to softmax.com, so everything here
 * talks only to this site's own /softmax-cogent/... paths (see server/README.md).
 *
 * On a host with no server part, `signedInAs` answers null and the game plays signed out.
 */

const BASE = '/softmax-cogent'

/** The signed-in person's email address, or null when nobody is signed in or sign-in is unavailable. */
export async function signedInAs() {
  let response

  try {
    response = await fetch(`${BASE}/api/whoami`, { credentials: 'same-origin' })
  } catch {
    return null
  }

  // A static host answers 404 with an HTML page; a server with no secret answers 503.
  if (!response.ok || !response.headers.get('content-type')?.includes('json')) return null

  // Softmax answers a signed-out visitor with 200 and the email "unknown", not with an error.
  const { user_email: email } = await response.json()
  return email && email !== 'unknown' ? email : null
}

/**
 * Leaves the page for softmax.com, where the person approves this site, and comes back to
 * `returnTo` (a path on this site) signed in.
 */
export function startSignIn(returnTo = location.pathname + location.search) {
  location.assign(`${BASE}/sign-in?return=${encodeURIComponent(returnTo)}`)
}

/** Clears the session cookie. True when the server confirmed it. */
export async function signOut() {
  const response = await fetch(`${BASE}/sign-out`, { method: 'POST', credentials: 'same-origin' })
  return response.ok
}

/**
 * The WebSocket address of a workspace's AIDE 1.0.0 frontend, through this site's server. Open it
 * with `new WebSocket(url, 'aide.1.0.0')`. The browser sends the session cookie with the handshake
 * and the server swaps it for the credential. The workspace id is the `provisioning_id` of the
 * workspace that `GET /softmax-cogent/api/v2/hermes` returns.
 */
export function cogentSocketUrl(workspaceId) {
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${scheme}//${location.host}${BASE}/api/v2/workspaces/${encodeURIComponent(workspaceId)}/aide/1.0.0/frontend`
}
