import assert from 'node:assert/strict'
import { after, before, test } from 'node:test'
import { get } from 'node:http'
import { fileURLToPath } from 'node:url'
import { createDevServer } from '../dev.mjs'
import { createSiteCogent } from '../site-cogent.mjs'

// A tiny stand-in for web/, so the test does not depend on the real page or a WebAssembly build.
const webRoot = fileURLToPath(new URL('./fixture-web', import.meta.url))
// No secret: the state of a fresh checkout.
const server = createDevServer({ cogent: createSiteCogent({}), webRoot })
let site

before((_, done) => {
  server.listen(0, '127.0.0.1', () => {
    site = `http://127.0.0.1:${server.address().port}`
    done()
  })
})
after(() => server.close())

/** `fetch` tidies ".." out of a URL before sending it; this sends the path exactly as written. */
function rawGet(path) {
  return new Promise((done, failed) => {
    get(`${site}`, { path }, (res) => {
      let body = ''
      res.on('data', (chunk) => (body += chunk))
      res.on('end', () => done({ status: res.statusCode, body }))
    }).on('error', failed)
  })
}

test('serves the page as HTML', async () => {
  const response = await fetch(`${site}/`)

  assert.equal(response.status, 200)
  assert.equal(response.headers.get('content-type'), 'text/html; charset=utf-8')
  assert.match(await response.text(), /<title>fixture<\/title>/)
})

test('serves WebAssembly as application/wasm', async () => {
  const response = await fetch(`${site}/game/tiny.wasm`)

  assert.equal(response.status, 200)
  assert.equal(response.headers.get('content-type'), 'application/wasm')
  assert.equal((await response.arrayBuffer()).byteLength, 8)
})

test('refuses paths that climb out of the web folder', async () => {
  // This test file sits just outside the fixture folder, so each path names a real file.
  for (const path of ['/../dev-server.test.js', '/..%2fdev-server.test.js', '/game/%2e%2e/%2e%2e/dev-server.test.js']) {
    const response = await rawGet(path)

    assert.equal(response.status, 403, path)
    assert.doesNotMatch(response.body, /createDevServer/, path)
  }
})

test('with no secret, a cogent route says sign-in is not configured', async () => {
  const response = await fetch(`${site}/softmax-cogent/api/whoami`)

  assert.equal(response.status, 503)
  assert.match(await response.text(), /not configured/)
})
