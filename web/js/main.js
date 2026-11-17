/**
 * The page: wires the game, the machine display, the stored table programs and the cogent.
 *
 * Order of things on load: the display and the programs list are drawn, the program that plays
 * next is put in the game's inbox, and the game starts loading. Beside that, the page asks whether
 * the person is signed in; if so it finds their workspace and connects the chat. The game never
 * waits for the cogent.
 */

import { signedInAs, signOut, startSignIn } from './cogent-auth.js'
import { connectCogent, findWorkspaceId } from './cogent-connection.js'
import { createChatPanel } from './chat-panel.js'
import { createGameBridge, giveKeysToGame } from './game-bridge.js'
import { createProgramsPanel, effectLine, failureLine } from './programs-panel.js'
import { createProgramStore, effectOf } from './programs.js'
import { createSidePanel, drawScore } from './side-panel.js'

const GUIDE_URL = 'guide/arena-basic.md'
/** The game has the house program built in, so the store only needs something to hold its place. */
const HOUSE_SOURCE = "' The house program is built into the game."
/** Below this the chat is a drawer over the table instead of a column beside it. Matches styles.css. */
const DRAWER_LAYOUT = '(max-width: 1099px), (max-aspect-ratio: 1/1)'

const byId = (id) => document.getElementById(id)
const canvas = byId('canvas')

// With `?fake-game` the page runs the stand-in from web/test/ instead of the real build.
const gameScript = new URLSearchParams(location.search).has('fake-game') ? 'test/fake-game.js' : undefined

const programs = createProgramStore(localStorage, HOUSE_SOURCE)
const game = createGameBridge(canvas, gameScript)
/** The cogent session once there is one. Signed out, or before the connection, it stays null. */
let session = null

// ---------------------------------------------------------------------------------------------
// The machine display and the table
// ---------------------------------------------------------------------------------------------

const sidePanel = createSidePanel({
  ballLine: byId('ball-line'),
  score: byId('score'),
  quest: byId('quest'),
  award: byId('award'),
  flags: byId('flags'),
  clock: byId('clock'),
  floating: byId('floating'),
})

const tableNotice = byId('table-notice')
const endScreen = byId('end-screen')
/** True once the game has said the Episode is over, so the next other phase means a new Episode. */
let episodeIsOver = false

function newEpisodeStarted() {
  episodeIsOver = false
  endScreen.hidden = true
  programsPanel.clearNotice()
  showAttention()
}

function restart() {
  game.send({ type: 'restart' })
  newEpisodeStarted()
}

game.on('hud', (hud) => {
  tableNotice.hidden = true
  sidePanel.showHud(hud)
  if (hud.phase === 'over') episodeIsOver = true
  else if (episodeIsOver) newEpisodeStarted()
})

game.on('floating', ({ items }) => sidePanel.showFloating(items))

game.on('episode', ({ summary }) => {
  session?.reportEpisode(summary)
  drawScore(byId('end-score'), summary.score)
  endScreen.hidden = false
})

byId('play-again').addEventListener('click', restart)

const demoToggle = byId('demo-toggle')
demoToggle.addEventListener('click', () => {
  const demo = demoToggle.getAttribute('aria-pressed') !== 'true'
  demoToggle.setAttribute('aria-pressed', demo)
  demoToggle.textContent = demo ? 'PLAY YOURSELF' : 'WATCH DEMO'
  game.send({ type: 'flipper', mode: demo ? 'demo' : 'human' })
})

// ---------------------------------------------------------------------------------------------
// Table programs
// ---------------------------------------------------------------------------------------------

const programsPanel = createProgramsPanel(
  {
    list: byId('program-list'),
    notice: byId('program-notice'),
    noticeTitle: byId('program-notice-title'),
    noticeDetail: byId('program-notice-detail'),
    restart: byId('restart-now'),
  },
  {
    programs,
    onSelect(name) {
      programs.select(name)
      const program = sendSelectedProgram()
      programsPanel.showNotice({ tone: 'plain', detail: effectLine(program, effectOf(programs.source(name))) })
    },
    onRestart: restart,
  },
)

/** Tells the game which program plays next, and returns its `{ name, version }`. */
function sendSelectedProgram() {
  const name = programs.selected()
  const program = programs.list().find((each) => each.name === name)
  game.send(name === 'house' ? { type: 'program', name } : { type: 'program', ...program, source: programs.source(name) })
  programsPanel.drawList()
  return program
}

function programArrived(program) {
  sendSelectedProgram()
  programsPanel.showNotice({
    tone: 'new',
    title: 'NEW TABLE PROGRAM RECEIVED',
    detail: effectLine(program, effectOf(programs.source(program.name))),
  })
  showAttention()
}

// The game has the last word on when a program takes effect.
game.on('programLoaded', ({ name, version, effect }) => {
  const notice = byId('program-notice')
  if (notice.hidden || notice.dataset.tone === 'error') return
  byId('program-notice-detail').textContent = effectLine({ name, version }, effect)
})

game.on('programError', ({ type, ...failure }) => {
  session?.reportProgramFailure(failure)
  programsPanel.showNotice({
    tone: 'error',
    title: 'TABLE PROGRAM FAILED',
    detail: failureLine(failure),
    canRestart: false,
  })
  showAttention()
})

// ---------------------------------------------------------------------------------------------
// The chat panel and the cogent
// ---------------------------------------------------------------------------------------------

/** Set once the cogent is connected; "try again" does nothing before that. */
let tryAgain = () => {}

const chatPanel = createChatPanel(
  {
    conversation: byId('conversation'),
    signedOut: byId('signed-out'),
    cogentState: byId('cogent-state'),
    tryAgain: byId('try-again'),
    log: byId('chat-log'),
    asks: byId('chat-asks'),
    composer: byId('composer'),
    text: byId('chat-text'),
    email: byId('account-email'),
    signIn: byId('sign-in'),
    signOut: byId('sign-out'),
  },
  {
    onSignIn: () => startSignIn(),
    onSignOut: () => signOut().then(() => location.reload()),
    onTryAgain: () => tryAgain(),
  },
)

function setChatOpen(open) {
  document.body.dataset.chat = open ? 'open' : 'closed'
  if (!open) canvas.focus()
  showAttention()
}

/** Marks the button that opens the chat when something there waits for the person. */
function showAttention() {
  const asks = session ? session.state.questions.length + session.state.approvals.length : 0
  const waiting = asks > 0 || !byId('program-notice').hidden
  byId('chat-open').dataset.attention = waiting
}

byId('chat-open').addEventListener('click', () => setChatOpen(true))
byId('chat-close').addEventListener('click', () => setChatOpen(false))
setChatOpen(!matchMedia(DRAWER_LAYOUT).matches)

function startChat(email) {
  chatPanel.showSignedIn(email, 'Finding your cogent…')
  const guide = fetch(GUIDE_URL).then((response) => (response.ok ? response.text() : ''))

  Promise.all([findWorkspaceId(), guide]).then(([workspaceId, guideText]) => {
    if (workspaceId === null) {
      chatPanel.showSignedIn(email, 'No cogent workspace was found for this account. Start one at softmax.com, then reload.')
      return
    }
    const connection = connectCogent({
      workspaceId,
      programs,
      guide: guideText,
      storage: localStorage,
      onUnreachable: chatPanel.setUnreachable,
    })
    session = connection.session
    tryAgain = connection.tryAgain
    session.onProgram(programArrived)
    session.onChange(showAttention)
    chatPanel.attach(session)
  })
}

// ---------------------------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------------------------

giveKeysToGame(canvas, document.querySelector('.stage'), byId('chat'))

sendSelectedProgram()
game.load(() => {
  tableNotice.hidden = false
  tableNotice.textContent = 'GAME BUILD NOT FOUND'
})

// A static host has no sign-in at all, and any failure here means the same thing: play signed out.
signedInAs()
  .catch(() => null)
  .then((email) => {
    if (email) startChat(email)
    else chatPanel.showSignedOut()
  })
