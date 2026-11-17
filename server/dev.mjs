/**
 * Local development server: the static site in web/, plus Softmax sign-in and the cogent WebSocket
 * pass-through. Node built-ins only.
 *
 *   node server/dev.mjs
 *
 * Environment variables are described in server/README.md.
 */
import { createReadStream, statSync } from 'node:fs'
import { createServer } from 'node:http'
import { extname, join, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createSiteCogent } from './site-cogent.mjs'

const WEB_ROOT = fileURLToPath(new URL('../web', import.meta.url))

/** Browsers refuse to stream-compile WebAssembly unless it arrives as application/wasm. */
const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.data': 'application/octet-stream',
  '.ogg': 'audio/ogg',
  '.ttf': 'font/ttf',
  '.woff2': 'font/woff2',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
  '.bas': 'text/plain; charset=utf-8',
}

function answer(res, status, text) {
  res.writeHead(status, { 'content-type': 'text/plain; charset=utf-8' })
  res.end(`${text}\n`)
}

function serveStatic(webRoot, req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') return answer(res, 405, 'Method not allowed')

  let urlPath

  try {
    urlPath = decodeURIComponent(req.url.split('?')[0])
  } catch {
    return answer(res, 400, 'Bad request')
  }

  if (urlPath.includes('\0')) return answer(res, 400, 'Bad request')

  // The path is checked after decoding and resolving, so "..", "%2e%2e" and "..%2f" all end up here.
  let file = resolve(webRoot, `.${urlPath}`)

  if (file !== webRoot && !file.startsWith(webRoot + sep)) return answer(res, 403, 'Forbidden')

  let stats = statSync(file, { throwIfNoEntry: false })

  if (stats?.isDirectory()) {
    file = join(file, 'index.html')
    stats = statSync(file, { throwIfNoEntry: false })
  }

  if (!stats?.isFile()) return answer(res, 404, 'Not found')

  res.writeHead(200, {
    'content-type': CONTENT_TYPES[extname(file).toLowerCase()] ?? 'application/octet-stream',
    'content-length': stats.size,
    // Development: always fetch the file again, so a rebuild shows up on reload.
    'cache-control': 'no-cache',
  })

  if (req.method === 'HEAD') return res.end()

  createReadStream(file)
    .on('error', () => res.destroy())
    .pipe(res)
}

/** `cogent` comes from createSiteCogent. Cogent paths go to it; everything else is a file in `webRoot`. */
export function createDevServer({ cogent, webRoot = WEB_ROOT }) {
  const root = resolve(webRoot)

  return createServer((req, res) => {
    cogent.node(req, res, () => serveStatic(root, req, res))
  }).on('upgrade', (req, socket, head) => cogent.upgrade(req, socket, head, () => socket.destroy()))
}

// Start listening only when this file is run directly, not when the test imports it.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT || 8080)
  const origin = process.env.SITE_ORIGIN || `http://localhost:${port}`
  const secret = process.env.COGENT_SECRET

  const cogent = createSiteCogent({ secret, origin, softmaxOrigin: process.env.SOFTMAX_ORIGIN })

  createDevServer({ cogent }).listen(port, () => {
    console.log(`Pinball Arena at ${origin}`)
    console.log(
      secret
        ? 'Softmax sign-in is on. Open the site at exactly that address, or sign-in will be refused.'
        : 'COGENT_SECRET is not set: the game is served, sign-in is off.'
    )
  })
}
