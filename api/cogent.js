/**
 * The one Vercel function of the site: Softmax sign-in and the cogent WebSocket pass-through.
 * vercel.json sends every /softmax-cogent/... request here. The game's files are served by Vercel
 * as static files and never reach this function.
 *
 * It exports a Node http server, which is the form Vercel documents for functions that accept
 * WebSockets (https://vercel.com/docs/functions/websockets): Vercel delivers requests as `request`
 * events and WebSocket handshakes as `upgrade` events.
 *
 * Deployed, and both events arrive with the /softmax-cogent/... path. NOT YET TESTED ON VERCEL:
 *   - An accepted WebSocket. Vercel's examples hand the `upgrade` event to the `ws` library.
 *     The cogent server instead writes the "101 Switching Protocols" reply onto the raw socket
 *     itself and pipes bytes to softmax.com. Whether Vercel's runtime allows that is not known.
 *   - Vercel closes a WebSocket when the function reaches its time limit. The page must reconnect.
 */
import { createServer } from 'node:http'
import { createSiteCogent } from '../server/site-cogent.mjs'

const cogent = createSiteCogent({
  secret: process.env.COGENT_SECRET,
  origin: process.env.SITE_ORIGIN,
  softmaxOrigin: process.env.SOFTMAX_ORIGIN,
})

function notFound(res) {
  res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' })
  res.end('Not found\n')
}

export default createServer((req, res) => {
  cogent.node(req, res, () => notFound(res))
}).on('upgrade', (req, socket, head) => cogent.upgrade(req, socket, head, () => socket.destroy()))
