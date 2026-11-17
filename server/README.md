# The server part

The game is a static site: everything in `web/`. Signed-out play needs no server at all; any
static file host will do.

The server part exists for one thing: connecting a signed-in person to their cogent. A browser
cannot attach the Softmax credential to a WebSocket, and page code should never hold that
credential. So a small Node server on the site's own address does three jobs:

1. Sends the person to softmax.com to sign in, and receives them back.
2. Keeps the credential in an encrypted, HttpOnly cookie that page code cannot read.
3. Passes the cogent's WebSocket (and a few API calls) through to softmax.com, adding the
   credential on the way.

All of that is the server half of the Softmax Cogent SDK, vendored as one file with no dependencies.

## Files

| File | What it is |
| --- | --- |
| `server/cogent-server.js` | The vendored SDK server half. Do not edit; its header says where it came from and how to refresh it. |
| `server/site-cogent.mjs` | Creates the cogent server from the settings, or a stand-in that answers "not configured". |
| `server/dev.mjs` | Local server: static files from `web/` plus the cogent routes. Node built-ins only. |
| `api/cogent.js`, `vercel.json` | The same cogent routes as one Vercel function; Vercel serves `web/` itself. |
| `web/js/cogent-auth.js` | What the page calls: `signedInAs`, `startSignIn`, `signOut`, `cogentSocketUrl`. |
| `server/test/` | Smoke test of the local server. |

## Routes

Everything is under `/softmax-cogent`.

| Route | Method | What it does |
| --- | --- | --- |
| `/softmax-cogent/sign-in?return=<path>` | GET | Redirects to softmax.com's approval page. |
| `/softmax-cogent/callback` | GET | softmax.com sends the browser back here with a one-time code. Sets the session cookie, redirects to `<path>`. |
| `/softmax-cogent/sign-out` | POST | Clears the session cookie. Same-site requests only. Answers 204. |
| `/softmax-cogent/api/whoami` | GET | Who is signed in: `{"user_email": ...}`. Signed out is a 200 with `"unknown"`. |
| `/softmax-cogent/api/players`, `/softmax-cogent/api/v2/hermes`, `/softmax-cogent/api/v2/cogents/...` | various | The few Softmax API calls needed to find, start and wake the person's workspace. Anything not on the SDK's list is a 404. |
| `/softmax-cogent/api/v2/workspaces/<id>/aide/1.0.0/frontend` | WebSocket | The cogent connection, passed through to softmax.com. Refused unless the `Origin` header equals the site origin and the session cookie is valid. |

The SDK also has `/softmax-cogent/embed.js` (its own chat widget). That file is not vendored, so
the route fails; this site draws its own chat panel.

The session cookie lasts 30 days. The credential inside it covers the person's whole Softmax
account and lasts a year, so anyone with the cookie secret can open every visitor's credential.
Treat the secret accordingly.

## Environment variables

| Variable | Needed | Meaning |
| --- | --- | --- |
| `COGENT_SECRET` | for sign-in | The cookie secret, at least 32 characters. Changing it signs everyone out. Never commit it. |
| `SITE_ORIGIN` | for sign-in on Vercel | The exact address people open, such as `https://<hostname>`. Must be `https` unless it is `localhost` or `127.0.0.1`. The local server defaults to `http://localhost:<PORT>`. |
| `SOFTMAX_ORIGIN` | no | Defaults to `https://softmax.com`. |
| `PORT` | no | Local server only. Defaults to 8080. |

With no `COGENT_SECRET` (or, on Vercel, no `SITE_ORIGIN`) the cogent routes answer
`503 Sign-in is not configured on this server.` and the game still works signed out.

## Run it locally

```sh
node server/dev.mjs                              # the game only; sign-in is off
COGENT_SECRET=<32 or more characters> node server/dev.mjs      # with sign-in
npm test                                         # or: node --test "server/test/*.test.js"
```

Open `http://localhost:8080`. Sign-in works on `localhost` and `127.0.0.1` with nothing set up at
Softmax, because Softmax always allows those callback hosts. Use the same host name the server
prints: opening `127.0.0.1` when the origin is `localhost` (or the other way round) makes the
callback and the WebSocket fail. To use `127.0.0.1`, set `SITE_ORIGIN=http://127.0.0.1:8080`.

Any long random string works as a local secret, for example the output of `openssl rand -hex 32`.

## Before a public deployment works

On the Softmax side:

- **The site's exact hostname must be added to the allowed cogent sites**: `cogentSiteHosts` in
  `workspaces/web/web-client/src/features/identity/identity-search.ts` in the metta repository,
  shipped with a softmax.com web deploy. It is an exact match with no wildcards, and today the list
  has no Vercel host. Until then softmax.com will not send the sign-in code back to the site.
- The SDK's README says this credential model is for sites Softmax controls. Softmax should agree
  that this site may hold the credential.

On the Vercel side:

- Set `COGENT_SECRET` and `SITE_ORIGIN` as environment variables of the project.
- One deployment address only. Every Vercel preview deployment has its own hostname, and both the
  allowed-sites list and `SITE_ORIGIN` need an exact match, so sign-in works on the one production
  hostname (and on localhost) and nowhere else.
- WebSockets on Vercel need Fluid compute, which is the default for projects created since April 2025.
- `web/game/` (the WebAssembly build) is in `.gitignore`. A deployment from git will not contain
  the game unless the build output gets there some other way. That is not solved here.

## Not tested

Nothing has been deployed to Vercel. `api/cogent.js` and `vercel.json` follow Vercel's documented
conventions (a function that exports a Node http server receives `upgrade` events), but:

- **The WebSocket pass-through on Vercel.** The SDK writes the handshake reply onto the raw socket
  and pipes bytes to softmax.com. Vercel's examples all use the `ws` library. Whether the raw
  approach works there is not known. If it does not, the pass-through needs a small adapter or a
  different host for this one route.
- That the function still sees the `/softmax-cogent/...` path after the rewrite in `vercel.json`.
- The time limit after which Vercel closes a WebSocket. The page must reconnect and reread in any
  case, as the AIDE contract requires.
- A full sign-in, and a real cogent connection through the pass-through, even locally. What was
  checked locally: the sign-in redirect, the "not configured" answers, and that the socket route
  refuses a missing cookie (401) and a foreign origin (403).
