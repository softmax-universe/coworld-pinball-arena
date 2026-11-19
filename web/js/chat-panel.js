/**
 * The chat panel: the conversation with the person's cogent, the state of each request, the
 * cogent's questions and approvals, and one line that says what the cogent is doing.
 *
 * It draws `session.state` from `cogent-session.js` again after every change and calls the
 * session when the person acts. It keeps no state of its own beyond what is in the text boxes.
 */

const COGENT_WORDING = {
  connecting: 'Connecting to your cogent…',
  ready: 'Your cogent is ready.',
  busy: 'Your cogent is working.',
  waking: 'Waking your cogent. This can take a minute… The table keeps its current program.',
  paused: 'Your cogent is paused. Start it at softmax.com, then press try again. The table keeps its current program.',
  asleep: 'Your cogent is asleep. It wakes when you send a message.',
  disconnected: 'Connection lost, reconnecting. The table keeps its current program.',
}
const UNREACHABLE_WORDING = 'Cannot reach your cogent. Still trying. The table keeps its current program.'

const CANCELLABLE_STATUSES = ['queued', 'running', 'waiting']
const APPROVAL_CHOICES = [
  ['once', 'Allow once'],
  ['deny', 'Deny'],
]

/** The line under the panel's heading. `unreachable` is true after repeated failed connections. */
export function cogentWording(cogent, unreachable) {
  if (unreachable && (cogent === 'connecting' || cogent === 'disconnected')) return UNREACHABLE_WORDING
  return COGENT_WORDING[cogent]
}

/** A message's text. The content is a string or the list-of-parts form; parts that are not text are left out. */
function textOf(content) {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content
    .filter((part) => part.type === 'text')
    .map((part) => part.text)
    .join('')
}

/**
 * What the conversation shows, top to bottom, from the session's state:
 * `{ kind: 'message', who: 'person' | 'cogent', text }` and
 * `{ kind: 'status', requestId, status, wording, canCancel }`.
 *
 * A message the person sent is in `state.requests` first and in `state.messages` only once the
 * cogent starts on it, so it is taken from the request until history has it. A request's status
 * line follows the last message of that request.
 */
export function conversationItems({ messages, requests }) {
  const items = []
  for (const record of messages) {
    const { role, content } = record.message
    const who = { user: 'person', assistant: 'cogent' }[role]
    const text = textOf(content)
    if (who && text) items.push({ kind: 'message', who, text, requestId: record.request_id })
  }

  for (const request of requests) {
    const inHistory = items.some(
      (item) =>
        item.who === 'person' &&
        (item.requestId === request.id || (item.requestId === undefined && item.text === request.text)),
    )
    if (request.text && !inHistory) {
      items.push({ kind: 'message', who: 'person', text: request.text, requestId: request.id })
    }
    if (!request.wording) continue

    const status = {
      kind: 'status',
      requestId: request.id,
      status: request.status,
      wording: request.wording,
      canCancel: CANCELLABLE_STATUSES.includes(request.status),
    }
    const lastOfRequest = items.findLastIndex((item) => item.requestId === request.id)
    if (lastOfRequest === -1) items.push(status)
    else items.splice(lastOfRequest + 1, 0, status)
  }
  return items
}

function element(tag, className, text) {
  const made = document.createElement(tag)
  if (className) made.className = className
  if (text !== undefined) made.textContent = text
  return made
}

function button(className, text, onClick) {
  const made = element('button', className, text)
  made.type = 'button'
  made.addEventListener('click', onClick)
  return made
}

/**
 * `elements` holds the panel's parts from index.html. `actions` is `{ onSignIn, onSignOut,
 * onTryAgain }`. The panel shows nothing until `showSignedOut` or `showSignedIn` is called.
 */
export function createChatPanel(elements, actions) {
  let session = null
  let unreachable = false
  /** The question and approval cards on show, by id. They are kept while they are open so that a redraw does not empty a half-typed answer. */
  const askCards = new Map()

  elements.signIn.addEventListener('click', actions.onSignIn)
  elements.signOut.addEventListener('click', actions.onSignOut)
  elements.tryAgain.addEventListener('click', actions.onTryAgain)

  elements.composer.addEventListener('submit', (event) => {
    event.preventDefault()
    const text = elements.text.value.trim()
    if (!text || !session) return
    session.send(text)
    elements.text.value = ''
  })
  elements.text.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      elements.composer.requestSubmit()
    }
  })

  /** Redraws the state line each second while the cogent wakes, so the seconds count up. */
  let wakingClock = null

  function drawState() {
    const { cogent, requests, wakingSince, awayReason, surfaceError } = session.state
    const waited = wakingSince === null ? '' : ` ${Math.round((Date.now() - wakingSince) / 1000)} s so far.`
    const reason = awayReason ? ` Softmax says: "${awayReason}".` : ''
    const gameStatus = surfaceError ? ` Game connection failed. ${surfaceError}` : ''
    elements.cogentState.textContent = cogentWording(cogent, unreachable) + waited + reason + gameStatus
    if (wakingSince !== null) wakingClock ??= setInterval(drawState, 1000)
    else if (wakingClock !== null) {
      clearInterval(wakingClock)
      wakingClock = null
    }
    elements.cogentState.dataset.cogent = cogent
    // A request held until a time still ahead cannot be hurried, so it does not call for the button.
    const canResume = requests.some(
      (request) => request.status === 'waiting' && !(request.until && Date.parse(request.until) > Date.now()),
    )
    elements.tryAgain.hidden = !(['waking', 'paused', 'disconnected'].includes(cogent) || unreachable || canResume || surfaceError)
  }

  function drawLog() {
    const log = elements.log
    const wasAtEnd = log.scrollHeight - log.scrollTop - log.clientHeight < 24
    log.replaceChildren(
      ...conversationItems(session.state).map((item) => {
        if (item.kind === 'message') return element('p', `chat-message from-${item.who}`, item.text)
        const line = element('p', 'request-status')
        line.dataset.status = item.status
        line.append(element('span', '', item.wording))
        if (item.canCancel) line.append(button('quiet-button', 'Cancel', () => session.cancel(item.requestId)))
        return line
      }),
    )
    if (wasAtEnd) log.scrollTop = log.scrollHeight
  }

  function questionCard({ id, prompt }) {
    const card = element('form', 'ask')
    const answer = element('input')
    answer.type = 'text'
    answer.placeholder = 'Your answer'
    answer.setAttribute('aria-label', 'Your answer')
    const send = element('button', 'send-button', 'Answer')
    send.type = 'submit'
    card.append(element('p', 'ask-kind', 'YOUR COGENT ASKS'), element('p', 'ask-prompt', prompt), answer, send)
    card.addEventListener('submit', (event) => {
      event.preventDefault()
      if (answer.value.trim()) session.answerQuestion(id, answer.value.trim())
    })
    return card
  }

  function approvalCard(approval) {
    const card = element('div', 'ask')
    card.append(element('p', 'ask-kind', 'YOUR COGENT WANTS APPROVAL'), element('p', 'ask-prompt', approval.prompt))
    if (approval.command) card.append(element('pre', 'ask-command', approval.command))
    const choices = element('div', 'ask-choices')
    for (const [choice, label] of APPROVAL_CHOICES) {
      if (approval.choices && !approval.choices.includes(choice)) continue
      choices.append(button(`choice-${choice}`, label, () => session.answerApproval(approval.request_id, choice)))
    }
    card.append(choices)
    return card
  }

  function drawAsks() {
    const open = new Map()
    for (const question of session.state.questions) open.set(question.id, () => questionCard(question))
    for (const approval of session.state.approvals) open.set(approval.request_id, () => approvalCard(approval))

    for (const [id, card] of askCards) {
      if (open.has(id)) continue
      card.remove()
      askCards.delete(id)
    }
    for (const [id, build] of open) {
      if (askCards.has(id)) continue
      const card = build()
      askCards.set(id, card)
      elements.asks.append(card)
    }
  }

  function draw() {
    drawState()
    drawLog()
    drawAsks()
  }

  return {
    /** No chat: the sign-in control stands in its place. */
    showSignedOut() {
      elements.signedOut.hidden = false
    },

    /** The chat, not usable yet. `status` says what the page is doing or why there is no cogent. */
    showSignedIn(email, status) {
      elements.conversation.hidden = false
      elements.email.textContent = email
      elements.cogentState.textContent = status
      elements.text.disabled = true
      elements.tryAgain.hidden = true
    },

    /** Before there is a session: shows the "try again" button. */
    offerTryAgain() {
      elements.tryAgain.hidden = false
    },

    /** Starts showing a session. */
    attach(cogentSession) {
      session = cogentSession
      elements.text.disabled = false
      session.onChange(draw)
      draw()
    },

    setUnreachable(flag) {
      unreachable = flag
      drawState()
    },
  }
}
