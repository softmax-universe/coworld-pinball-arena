/**
 * The wire layer for AIDE 1.0.0, the Softmax interface between a web page and a cogent's workspace:
 * one WebSocket carrying JSON-RPC 2.0, one JSON object per text frame.
 *
 * This module knows the envelope and nothing about chat or table programs. It sends requests and
 * matches their replies, passes notifications on, and answers the requests the agent sends to the
 * page. `cogent-session.js` builds the conversation on top of it, and `programs.js` is where that
 * conversation stores the table programs. No DOM.
 *
 * The contract: https://softmax.com/docs/aide (protocol.md and asyncapi.json, version 1.0.0).
 */

const SUBPROTOCOL = 'aide.1.0.0'

/** The JSON-RPC code of every application error. The contract's own code travels in `data.code`. */
const APPLICATION_ERROR = -32000
const INTERNAL_ERROR = -32603

/**
 * An error reply, received or to be sent. `code` is the contract's code (`unsupported`,
 * `conflict`, ...), or null for a bare JSON-RPC protocol error, which has only `rpcCode`.
 * A handler throws one to refuse a request from the agent.
 */
export class AideError extends Error {
  constructor(code, message, data = {}) {
    super(message)
    this.name = 'AideError'
    this.code = code
    this.rpcCode = APPLICATION_ERROR
    this.data = data
  }
}

function errorFromReply({ code, message, data }) {
  const error = new AideError(data?.code ?? null, message, data)
  error.rpcCode = code
  return error
}

/** A transport failure. `outcome` says whether the request can have reached the workspace. */
function unavailable(message, outcome) {
  return new AideError('unavailable', message, { code: 'unavailable', outcome })
}

/**
 * `createSocket(subprotocol)` opens the WebSocket; in the browser that is
 * `(protocol) => new WebSocket(cogentSocketUrl(workspaceId), protocol)`.
 *
 * Call `connect()` to start, and again after `onClosed` to reconnect. Nothing reconnects by itself.
 */
export function createAideClient(createSocket) {
  let socket = null
  // The largest frame the relay accepts, from the binding frame. Null while there is no bound connection.
  let maxMessageBytes = null
  const waitingReplies = new Map()
  const requestHandlers = {}
  const notificationListeners = {}
  const boundListeners = []
  const closedListeners = []
  const encoder = new TextEncoder()

  function connect() {
    const opened = createSocket(SUBPROTOCOL)
    socket = opened
    maxMessageBytes = null
    // A socket that was replaced by a later connect() may still deliver events; they are ignored.
    opened.addEventListener('message', (event) => {
      if (opened === socket) receive(event.data)
    })
    opened.addEventListener('close', () => {
      if (opened === socket) connectionLost()
    })
  }

  function connectionLost() {
    socket = null
    maxMessageBytes = null
    const lost = [...waitingReplies.values()]
    waitingReplies.clear()
    // The frames went out, so the workspace may have acted on them.
    for (const { reject } of lost) reject(unavailable('The connection was lost.', 'unknown'))
    for (const listener of closedListeners) listener()
  }

  function receive(text) {
    let frame
    try {
      frame = JSON.parse(text)
    } catch {
      return
    }

    if (frame.binding) {
      maxMessageBytes = frame.binding.max_message_bytes
      const binding = { frontendId: frame.binding.frontend_id, maxMessageBytes }
      for (const listener of boundListeners) listener(binding)
    } else if (frame.method !== undefined && frame.id !== undefined) {
      socket.send(JSON.stringify({ jsonrpc: '2.0', id: frame.id, ...answer(frame) }))
    } else if (frame.method !== undefined) {
      for (const listener of notificationListeners[frame.method] ?? []) listener(frame.params)
    } else {
      settle(frame)
    }
  }

  /** The `result` or `error` member of the reply to a request from the agent. */
  function answer({ method, params, id }) {
    try {
      const handler = requestHandlers[method]
      if (!handler) throw new AideError('unsupported', `This page does not support ${method}.`)
      return { result: handler(params, id) }
    } catch (error) {
      if (error instanceof AideError) {
        return {
          error: { code: APPLICATION_ERROR, message: error.message, data: { ...error.data, code: error.code } },
        }
      }
      // A bug in the page. The agent still gets a reply instead of waiting 30 seconds for none.
      console.error(error)
      return { error: { code: INTERNAL_ERROR, message: 'The page failed to handle the request.' } }
    }
  }

  function settle(reply) {
    const waiting = waitingReplies.get(reply.id)
    if (!waiting) return
    waitingReplies.delete(reply.id)
    if (reply.error) waiting.reject(errorFromReply(reply.error))
    else waiting.resolve(reply.result)
  }

  /**
   * Sends one request and resolves with its result, or rejects with an AideError.
   * Pass the `id` of an earlier try to repeat a request whose outcome was unknown: the workspace
   * treats the id as an idempotency key and will not do the work twice.
   */
  function request(method, params, id = crypto.randomUUID()) {
    if (maxMessageBytes === null) {
      return Promise.reject(unavailable('There is no connection to the cogent.', 'not_delivered'))
    }
    const text = JSON.stringify({ jsonrpc: '2.0', id, method, params })
    // The relay closes the connection on an oversized frame, so it is refused here instead.
    if (encoder.encode(text).length > maxMessageBytes) {
      return Promise.reject(new AideError('too_large', 'The message is too large to send.', { code: 'too_large' }))
    }
    return new Promise((resolve, reject) => {
      waitingReplies.set(id, { resolve, reject })
      socket.send(text)
    })
  }

  return {
    connect,
    request,
    close: () => socket?.close(),
    /** `listener({ frontendId, maxMessageBytes })` runs when a connection is ready for requests. */
    onBound: (listener) => void boundListeners.push(listener),
    /** `listener()` runs when the connection ends, whichever side ended it. */
    onClosed: (listener) => void closedListeners.push(listener),
    /** `listener(params)` runs for each notification of that method. Others are ignored. */
    onNotification(method, listener) {
      notificationListeners[method] ??= []
      notificationListeners[method].push(listener)
    },
    /**
     * `handler(params, id)` answers a request from the agent: it returns the result at once, or
     * throws an AideError to refuse. A method with no handler is answered with `unsupported`.
     */
    handle: (method, handler) => void (requestHandlers[method] = handler),
  }
}
