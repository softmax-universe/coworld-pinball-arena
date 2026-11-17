/*
 * VENDORED. Do not edit: refresh it instead.
 *
 * The server half of the Softmax Cogent SDK (`createCogentServer`), built to plain JavaScript.
 * It needs only Node built-ins.
 *
 * Source:  packages/softmax-cogent/src/server.ts in the Softmax metta repository
 *          (github.com/softmax-universe/softmax), commit b2684546b6
 *          (git blob 5771894e995576a111c97432e47b1c34dc14837e).
 * Build:   the SDK ships TypeScript only. This is the output of the SDK's own server build step,
 *          run with vite 8.3.5 (the version the SDK pins):
 *              vite build --config vite.server.config.ts        -> dist/server.js
 *          Everything below this comment is that file, byte for byte
 *          (sha256 2fc129edd19fbad774d0d86aac5657ffa47a75f3d45d340a3e098ba9cee2fe85).
 *
 * To refresh: in a metta checkout with dependencies installed, run
 *              pnpm --filter @softmax/cogent-sdk pack:site
 *          and copy packages/softmax-cogent/dist-package/server.js over the code below (that
 *          command runs the same vite build). Or run only the vite command above inside
 *          packages/softmax-cogent. Then update the commit, blob and sha256 in this comment.
 *
 * Not vendored: embed.js, the SDK's React chat widget. The `<base>/embed.js` route therefore
 * fails (it answers 502). This site draws its own chat panel and never asks for it.
 */
import { createCipheriv, createDecipheriv, createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import { STATUS_CODES, request } from "node:http";
import { request as request$1 } from "node:https";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
// src/server.ts
/**
* The server half of the SDK, for any Node site. The browser only talks to this, on the site's own origin:
*
*   <base>/embed.js   the script
*   <base>/sign-in    sends the user to softmax.com to approve this site
*   <base>/callback   softmax.com sends them back with a one-time code, which becomes their session
*   <base>/sign-out   ends it
*   <base>/api/...    forwards the routes the cogent needs, with the user's credential
*   <base>/api/v2/workspaces/<id>/aide/1.0.0/frontend
*                     the chat's WebSocket, upgraded to softmax.com with the user's credential (`upgrade`)
*
* The credential only ever lives in an encrypted HttpOnly cookie, so a site needs one secret and no database.
*/
var SESSION_COOKIE = "softmax_cogent_session";
var STATE_COOKIE = "softmax_cogent_state";
var SESSION_SECONDS = 2592e3;
var STATE_SECONDS = 600;
var MAX_BODY_BYTES = 2097152;
/** Everything the cogent calls. Anything else on the user's account stays out of reach of this site. */
var ROUTES = [
	{
		methods: ["GET"],
		path: /^\/whoami$/
	},
	{
		methods: ["GET"],
		path: /^\/players$/
	},
	{
		methods: ["GET"],
		path: /^\/v2\/hermes$/
	},
	{
		methods: ["POST"],
		path: /^\/v2\/cogents$/
	},
	{
		methods: ["PUT"],
		path: /^\/v2\/cogents\/[\w-]+\/hermes$/
	},
	{
		methods: ["POST"],
		path: /^\/v2\/cogents\/[\w-]+\/hermes\/wake$/
	},
	{
		methods: ["PUT"],
		path: /^\/v2\/cogents\/[\w-]+\/hermes\/lifecycle$/
	},
	{
		methods: ["DELETE"],
		path: /^\/v2\/cogents\/[\w-]+\/hermes\/[\w-]+$/
	}
];
/** The one socket the cogent opens: its workspace's AIDE 1.0.0 chat. */
var AIDE_FRONTEND = /^\/v2\/workspaces\/[\w-]+\/aide\/1\.0\.0\/frontend$/;
/** What a browser and softmax.com negotiate between themselves; nothing else of the browser's request goes on. */
var WEBSOCKET_REQUEST_HEADERS = [
	"sec-websocket-key",
	"sec-websocket-version",
	"sec-websocket-protocol",
	"sec-websocket-extensions"
];
/** How long softmax.com has to accept or refuse a socket before the browser is told it timed out. */
var HANDSHAKE_MS = 1e4;
var WEBSOCKET_REPLY_HEADERS = /* @__PURE__ */ new Set([
	"upgrade",
	"connection",
	"sec-websocket-accept",
	"sec-websocket-protocol",
	"sec-websocket-extensions"
]);
var FORWARDED_REPLY_HEADERS = [
	"content-type",
	"retry-after",
	"cache-control"
];
var isLocal = (origin) => ["localhost", "127.0.0.1"].includes(origin.hostname);
function cookiesOf(header) {
	const cookies = /* @__PURE__ */ new Map();
	for (const part of (header ?? "").split(/;\s*/)) {
		const at = part.indexOf("=");
		if (at > 0) cookies.set(part.slice(0, at), part.slice(at + 1));
	}
	return cookies;
}
var sameText = (a, b) => {
	const left = Buffer.from(a);
	const right = Buffer.from(b);
	return left.length === right.length && timingSafeEqual(left, right);
};
/** A path on this site only: browsers strip tabs and read `\` as `/`, so `/<tab>/other.example` goes elsewhere. */
function safeReturn(value) {
	if (!value || value.includes("\\") || [...value].some((character) => character.charCodeAt(0) <= 32)) return "/";
	return value.startsWith("/") && new URL(value, "https://site.invalid").origin === "https://site.invalid" ? value : "/";
}
/** The body, or null past the limit, without holding more than the limit however long the sender keeps going. */
async function readLimited(request) {
	if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY_BYTES) return null;
	const chunks = [];
	let size = 0;
	if (request.body) for await (const chunk of request.body.values({ preventCancel: true })) {
		size += chunk.byteLength;
		if (size > MAX_BODY_BYTES) return null;
		chunks.push(chunk);
	}
	return Buffer.concat(chunks);
}
function createCogentServer(options) {
	const origin = new URL(options.origin);
	const base = (options.base ?? "/softmax-cogent").replace(/\/$/, "");
	const softmax = options.softmaxOrigin ?? "https://softmax.com";
	const api = options.softmaxApi ?? `${softmax}/api/observatory`;
	const script = options.embedScript ?? new URL("./embed.js", import.meta.url);
	if (options.secret.length < 32) throw new Error("The secret must be at least 32 characters.");
	if (options.developmentToken && !isLocal(origin)) throw new Error("developmentToken only works on a local origin.");
	if (origin.protocol !== "https:" && !isLocal(origin)) throw new Error("The origin must be https.");
	const key = createHash("sha256").update(options.secret).digest();
	/** `purpose` is authenticated, so a session cookie can't be replayed as a sign-in's state, or the reverse. */
	function seal(purpose, value) {
		const nonce = randomBytes(12);
		const cipher = createCipheriv("aes-256-gcm", key, nonce);
		cipher.setAAD(Buffer.from(purpose));
		const body = Buffer.concat([cipher.update(value, "utf8"), cipher.final()]);
		return Buffer.concat([
			nonce,
			cipher.getAuthTag(),
			body
		]).toString("base64url");
	}
	/** Null for anything this server did not seal, including a cookie from before the secret changed. */
	function unseal(purpose, value) {
		if (!value) return null;
		const raw = Buffer.from(value, "base64url");
		if (raw.length < 29) return null;
		const decipher = createDecipheriv("aes-256-gcm", key, raw.subarray(0, 12));
		decipher.setAuthTag(raw.subarray(12, 28));
		decipher.setAAD(Buffer.from(purpose));
		try {
			return Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString("utf8");
		} catch {
			return null;
		}
	}
	const cookie = (name, value, maxAge) => `${name}=${value}; HttpOnly; SameSite=Lax; Path=${base}; Max-Age=${maxAge}${origin.protocol === "https:" ? "; Secure" : ""}`;
	/** A cookie sends itself on cross-site requests in some cases, so writes must also say they came from here. */
	function fromThisSite(request) {
		const from = request.headers.get("origin");
		return from ? from === origin.origin : request.headers.get("sec-fetch-site") === "same-origin";
	}
	async function forward(request, path, search) {
		const route = ROUTES.find((candidate) => candidate.path.test(path));
		if (!route) return new Response("Not available to this site.", { status: 404 });
		if (!route.methods.includes(request.method)) return new Response("Method not allowed.", { status: 405 });
		if (request.method !== "GET" && !fromThisSite(request)) return new Response("Cross-site write refused.", { status: 403 });
		const token = options.developmentToken ?? unseal(SESSION_COOKIE, cookiesOf(request.headers.get("cookie")).get(SESSION_COOKIE));
		const headers = new Headers();
		for (const name of ["accept", "content-type"]) {
			const value = request.headers.get(name);
			if (value) headers.set(name, value);
		}
		if (token) headers.set("authorization", `Bearer ${token}`);
		if (request.method !== "GET" && !token) return new Response("Sign in first.", { status: 401 });
		const body = request.method === "GET" ? null : await readLimited(request);
		if (request.method !== "GET" && !body) return new Response("Too large.", { status: 413 });
		const upstream = await fetch(`${api}${path}${search}`, {
			method: request.method,
			headers,
			...body ? { body } : {},
			signal: request.signal
		});
		const reply = new Headers();
		for (const name of FORWARDED_REPLY_HEADERS) {
			const value = upstream.headers.get(name);
			if (value) reply.set(name, value);
		}
		return new Response(upstream.body, {
			status: upstream.status,
			headers: reply
		});
	}
	function signIn(url) {
		const state = randomBytes(24).toString("base64url");
		const callback = new URL(`${origin.origin}${base}/callback`);
		callback.searchParams.set("state", state);
		callback.searchParams.set("delivery", "redirect");
		const target = new URL("/cli-auth", softmax);
		target.searchParams.set("callback", callback.href);
		const sealed = seal(STATE_COOKIE, JSON.stringify({
			state,
			returnTo: safeReturn(url.searchParams.get("return"))
		}));
		return new Response(null, {
			status: 302,
			headers: {
				location: target.href,
				"set-cookie": cookie(STATE_COOKIE, sealed, STATE_SECONDS)
			}
		});
	}
	async function callback(request, url) {
		const opened = unseal(STATE_COOKIE, cookiesOf(request.headers.get("cookie")).get(STATE_COOKIE));
		const started = opened ? JSON.parse(opened) : null;
		const state = url.searchParams.get("state");
		const code = url.searchParams.get("code");
		if (!started || !state || !code || !sameText(started.state, state)) return new Response("This sign-in did not start in this browser. Please try again.", { status: 400 });
		const exchanged = await fetch(`${api}/credentials/auth-codes/exchange`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ code })
		});
		if (!exchanged.ok) return new Response("Softmax refused the sign-in. Please try again.", { status: 502 });
		const { token } = await exchanged.json();
		const headers = new Headers({ location: `${origin.origin}${safeReturn(started.returnTo)}` });
		headers.append("set-cookie", cookie(SESSION_COOKIE, seal(SESSION_COOKIE, token), SESSION_SECONDS));
		headers.append("set-cookie", cookie(STATE_COOKIE, "", 0));
		return new Response(null, {
			status: 302,
			headers
		});
	}
	/** The cogent's answer to a request under `base`, or null for anything else, which is the site's own. */
	async function route(request, url) {
		const path = url.pathname.slice(base.length);
		if (path.startsWith("/api/")) return forward(request, path.slice(4), url.search);
		if (path === "/embed.js" && request.method === "GET") return new Response(await readFile(script), { headers: {
			"content-type": "text/javascript; charset=utf-8",
			"cache-control": "public, max-age=300"
		} });
		if (path === "/sign-in" && request.method === "GET") return signIn(url);
		if (path === "/callback" && request.method === "GET") return callback(request, url);
		if (path === "/sign-out" && request.method === "POST") {
			if (!fromThisSite(request)) return new Response("Cross-site write refused.", { status: 403 });
			return new Response(null, {
				status: 204,
				headers: { "set-cookie": cookie(SESSION_COOKIE, "", 0) }
			});
		}
		return new Response("Not found.", { status: 404 });
	}
	const isOurs = (pathname) => pathname === base || pathname.startsWith(`${base}/`);
	/**
	* The cogent's answer to a request under `base`, or null for anything else, which is the site's own. This is the one
	* place failures stop: Softmax being down, or one bad request, must not take the host site's server with it.
	*/
	async function handle(request) {
		const url = new URL(request.url);
		if (!isOurs(url.pathname)) return null;
		return route(request, url).catch((error) => {
			if (request.signal.aborted) return new Response(null, { status: 499 });
			console.error("Cogent SDK: a request failed.", error);
			return new Response("The Softmax API could not be reached.", { status: 502 });
		});
	}
	/** `handle` for Node's http server, Express or Connect. Passes on what isn't the cogent's. */
	async function serve(req, res, next) {
		const pathname = URL.canParse(req.url ?? "", origin) ? new URL(req.url ?? "", origin).pathname : null;
		if (pathname === null || !isOurs(pathname)) {
			if (next) return next();
			res.writeHead(pathname === null ? 400 : 404);
			res.end();
			return;
		}
		if (![
			"GET",
			"HEAD",
			"POST",
			"PUT",
			"DELETE",
			"OPTIONS"
		].includes(req.method ?? "")) {
			res.writeHead(405);
			res.end();
			return;
		}
		const abort = new AbortController();
		res.on("close", () => abort.abort());
		const headers = new Headers();
		for (const [name, value] of Object.entries(req.headers)) if (typeof value === "string") headers.set(name, value);
		else if (value) for (const item of value) headers.append(name, item);
		const hasBody = !["GET", "HEAD"].includes(req.method ?? "GET");
		const response = await handle(new Request(new URL(req.url ?? "/", origin), {
			method: req.method ?? "GET",
			headers,
			signal: abort.signal,
			...hasBody ? {
				body: Readable.toWeb(req),
				duplex: "half"
			} : {}
		}));
		const reply = {};
		response.headers.forEach((value, name) => {
			if (name !== "set-cookie") reply[name] = value;
		});
		const cookies = response.headers.getSetCookie();
		if (cookies.length) reply["set-cookie"] = cookies;
		if (hasBody && !req.readableEnded) reply.connection = "close";
		res.writeHead(response.status, reply);
		if (!response.body) {
			res.end();
			return;
		}
		await pipeline(Readable.fromWeb(response.body), res).catch(() => res.destroy());
	}
	/** Never rejects: nothing about one request may become an unhandled rejection in the host's process. */
	const node = (req, res, next) => serve(req, res, next).catch((error) => {
		console.error("Cogent SDK: a request failed.", error);
		if (res.headersSent) return void res.destroy();
		res.writeHead(502);
		res.end();
	});
	/** A refused upgrade is an ordinary HTTP answer on the socket, which then closes. */
	function refuse(socket, status, text) {
		socket.end(`HTTP/1.1 ${status} ${STATUS_CODES[status]}\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${Buffer.byteLength(text)}\r\n\r\n${text}`);
	}
	/**
	* Node's `upgrade` event, for the chat's WebSocket: `server.on('upgrade', cogent.upgrade)`. Upgrades elsewhere are
	* the site's own and go to `next`; without `next` they are refused. The socket opens on softmax.com exactly as
	* softmax.com's own page opens it: the user's credential as a bearer token, and the browser's WebSocket negotiation,
	* subprotocol included, passed through untouched. Frames then flow both ways unread. A Fetch API server cannot
	* upgrade, so `handle` has no equivalent.
	*/
	function upgrade(req, socket, head, next) {
		const url = URL.canParse(req.url ?? "", origin) ? new URL(req.url ?? "", origin) : null;
		if (url === null || !isOurs(url.pathname)) {
			if (next) return next();
			socket.on("error", () => socket.destroy());
			return refuse(socket, url === null ? 400 : 404, "Not found.");
		}
		socket.on("error", () => socket.destroy());
		const path = url.pathname.slice(base.length);
		if (!path.startsWith("/api/") || !AIDE_FRONTEND.test(path.slice(4))) return refuse(socket, 404, "Not available to this site.");
		if (req.headers.origin !== origin.origin) return refuse(socket, 403, "Cross-site socket refused.");
		const token = options.developmentToken ?? unseal(SESSION_COOKIE, cookiesOf(req.headers.cookie).get(SESSION_COOKIE));
		if (!token) return refuse(socket, 401, "Sign in first.");
		const headers = {
			authorization: `Bearer ${token}`,
			connection: "Upgrade",
			upgrade: "websocket"
		};
		for (const name of WEBSOCKET_REQUEST_HEADERS) {
			const value = req.headers[name];
			if (typeof value === "string") headers[name] = value;
		}
		const target = new URL(`${api}${path.slice(4)}${url.search}`);
		const upstream = (target.protocol === "https:" ? request$1 : request)(target, {
			method: "GET",
			headers
		});
		let answered = false;
		/** The browser gets one answer: the upgrade, softmax.com's refusal, or this server's. */
		const answer = (status, text) => {
			if (answered) return;
			answered = true;
			clearTimeout(deadline);
			refuse(socket, status, text);
		};
		const deadline = setTimeout(() => {
			answer(504, "Softmax did not answer in time.");
			upstream.destroy();
		}, HANDSHAKE_MS);
		socket.once("close", () => {
			clearTimeout(deadline);
			upstream.destroy();
		});
		upstream.on("upgrade", (reply, remote, remoteHead) => {
			if (answered) return void remote.destroy();
			answered = true;
			clearTimeout(deadline);
			let accepted = "HTTP/1.1 101 Switching Protocols\r\n";
			for (let index = 0; index < reply.rawHeaders.length; index += 2) if (WEBSOCKET_REPLY_HEADERS.has(reply.rawHeaders[index].toLowerCase())) accepted += `${reply.rawHeaders[index]}: ${reply.rawHeaders[index + 1]}\r\n`;
			const close = () => {
				socket.destroy();
				remote.destroy();
			};
			remote.on("error", close);
			remote.on("close", close);
			socket.on("close", close);
			socket.write(`${accepted}\r\n`);
			if (remoteHead.length) socket.write(remoteHead);
			if (head.length) remote.write(head);
			remote.pipe(socket);
			socket.pipe(remote);
		});
		upstream.on("response", (reply) => {
			reply.resume();
			answer(reply.statusCode ?? 502, "Softmax refused the connection.");
		});
		upstream.on("error", () => {
			if (!socket.destroyed) answer(502, "The Softmax API could not be reached.");
		});
		upstream.end();
	}
	return {
		handle,
		node,
		upgrade
	};
}
export { createCogentServer };
