/**
 * The cogent server for this site, shared by the local server (dev.mjs) and the Vercel function
 * (api/cogent.js). Without a cookie secret or a site origin there is nothing to sign in with, so a
 * stand-in answers the cogent paths with a plain "not configured" message. The game itself needs
 * none of this: signed-out play is only static files.
 */
import { createCogentServer } from './cogent-server.js'

/** The SDK's default mount point. web/js/cogent-auth.js uses the same path. */
export const COGENT_BASE = '/softmax-cogent'

const NOT_CONFIGURED = 'Sign-in is not configured on this server. Set COGENT_SECRET and SITE_ORIGIN.\n'

const isCogentPath = (url = '') => {
  const path = url.split('?')[0]
  return path === COGENT_BASE || path.startsWith(`${COGENT_BASE}/`)
}

/** Has the same `node` and `upgrade` shape as the real cogent server, and refuses everything. */
const notConfigured = {
  node(req, res, next) {
    if (!isCogentPath(req.url)) return next()

    res.writeHead(503, { 'content-type': 'text/plain; charset=utf-8' })
    res.end(NOT_CONFIGURED)
  },
  upgrade(req, socket, head, next) {
    if (!isCogentPath(req.url)) return next()

    socket.end(
      'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\n' +
        `Content-Length: ${Buffer.byteLength(NOT_CONFIGURED)}\r\n\r\n${NOT_CONFIGURED}`
    )
  },
}

/**
 * `origin` must be exactly the address people open the site at: Softmax sends the browser back to
 * it after sign-in, and the WebSocket pass-through refuses any other origin.
 */
export function createSiteCogent({ secret, origin, softmaxOrigin }) {
  if (!secret || !origin) return notConfigured

  return createCogentServer({ origin, secret, base: COGENT_BASE, ...(softmaxOrigin ? { softmaxOrigin } : {}) })
}
