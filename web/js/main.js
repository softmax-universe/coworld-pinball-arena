/**
 * The page: wires the game, the machine display, the stored programs, the game API and the cogent.
 *
 * Order of things on load: the display is drawn, the active program of
 * each seat is put in the game's inbox, and the game starts loading. Beside that, the page asks whether the person is signed in; if so it finds their
 * workspace and connects the chat. The game never waits for the cogent.
 */

import { signedInAs, signOut, startSignIn } from './cogent-auth.js'
import { connectCogent, startWorkspace } from './cogent-connection.js'
import { createChatPanel } from './chat-panel.js'
import { createGameApi } from './game-api.js'
import { createGameBridge, giveKeysToGame } from './game-bridge.js'
import { createProgramsPanel, effectLine, failureLine } from './programs-panel.js'
import { createProgramStore, effectOf } from './programs.js'
import { createSidePanel, drawScore } from './side-panel.js'

/**
 * The AIDE scope of this game: its Coworld and league. Everything the page sends the cogent carries
 * it, and the page acts only on policies and game requests that name it.
 *
 * The ids are those of the registered Coworld `pinball-arena` (version 0.1.2) and its
 * league. Each upload of the Coworld gets a new id: change it here then (coworld/README.md).
 */
const GAME_SCOPE = {
  scope: 'coworld',
  coworld: 'cow_3ff5f418-2002-410a-84ab-c85fdf6742d7',
  league: 'league_9a3f459f-8223-4dc1-acd9-7292e46919dd',
}
const byId = (id) => document.getElementById(id)
const canvas = byId('canvas')

// With `?fake-game` the page runs the stand-in from web/test/ instead of the real build.
const gameScript = new URLSearchParams(location.search).has('fake-game') ? 'test/fake-game.js' : undefined

const programs = createProgramStore(localStorage)
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
  canvas.focus()
}

game.on('hud', (hud) => {
  tableNotice.hidden = true
  sidePanel.showHud(hud)
  if (hud.phase === 'over') episodeIsOver = true
  else if (episodeIsOver) newEpisodeStarted()
})

game.on('episode', ({ summary }) => {
  session?.reportEpisode(summary)
  drawScore(byId('end-score'), summary.score)
  endScreen.hidden = false
})

byId('play-again').addEventListener('click', restart)

const musicButton = byId('music-cycle')
const soundtrack = byId('soundtrack')
const musicModes = [
  { name: 'Off' },
  { name: 'Space Echo', file: 'music/space-echo.ogg' },
  { name: 'Space Adventure', file: 'music/space-adventure.ogg' },
]
let musicIndex = 0
soundtrack.volume = 0.24
musicButton.addEventListener('click', (event) => {
  musicIndex = (musicIndex + 1) % musicModes.length
  const mode = musicModes[musicIndex]
  soundtrack.pause()
  musicButton.textContent = `♫ Music · ${mode.name}`
  if (mode.file) {
    soundtrack.src = mode.file
    soundtrack.play().catch((error) => {
      if (error.name !== 'AbortError' && musicModes[musicIndex] === mode) {
        musicButton.textContent = `♫ ${mode.name} unavailable`
      }
    })
  }
  // A pointer click gives Space back to the plunger. Keyboard users can cycle in place.
  if (event.detail > 0) canvas.focus({ preventScroll: true })
})

// ---------------------------------------------------------------------------------------------
// Programs and the game API
// ---------------------------------------------------------------------------------------------

const programsPanel = createProgramsPanel(
  {
    notice: byId('program-notice'),
    noticeTitle: byId('program-notice-title'),
    noticeDetail: byId('program-notice-detail'),
    restart: byId('restart-now'),
  },
  restart,
)

const api = createGameApi({
  programs,
  game,
  onProgramsChanged(program) {
    updateDemoButton()
    if (program) showProgramNotice(program, 'new', 'NEW PROGRAM FROM YOUR COGENT')
  },
})

const demoToggle = byId('demo-toggle')
demoToggle.addEventListener('click', () => {
  activate('flipper', programs.active('flipper') === null ? 'demo' : null)
  canvas.focus()
})

function updateDemoButton() {
  const programPlays = programs.active('flipper') !== null
  demoToggle.setAttribute('aria-pressed', programPlays)
  demoToggle.textContent = programPlays ? 'PLAY YOURSELF' : 'WATCH DEMO'
}

/** The person picked a program, or took the flippers back with `name` null. */
function activate(seat, name) {
  const program = api.activate(seat, name)
  updateDemoButton()
  if (program) showProgramNotice(program, 'plain')
  else programsPanel.clearNotice()
}

function showProgramNotice(program, tone, title) {
  const effect = program.builtIn ? 'next-episode' : effectOf(programs.source(program.name))
  programsPanel.showNotice({ tone, title, detail: effectLine(program, effect), canRestart: program.seat === 'arena' })
  showAttention()
}

// The game has the last word on when a program takes effect.
game.on('programLoaded', ({ seat, name, version, effect }) => {
  const notice = byId('program-notice')
  if (notice.hidden || notice.dataset.tone === 'error') return
  byId('program-notice-detail').textContent = effectLine({ seat, name, version }, effect)
})

game.on('programError', ({ type, ...failure }) => {
  session?.reportProgramFailure(failure)
  programsPanel.showNotice({
    tone: 'error',
    title: 'PROGRAM FAILED',
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
  byId('chat-open').setAttribute('aria-pressed', open)
  byId('chat-close').setAttribute('aria-pressed', !open)
  if (!open) canvas.focus({ preventScroll: true })
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
setChatOpen(false)

function startChat(email) {
  chatPanel.showSignedIn(email, 'Finding your cogent…')
  startWorkspace((progress) => chatPanel.showSignedIn(email, progress)).then(
    (workspaceId) => {
      const connection = connectCogent({
        workspaceId,
        api,
        scope: GAME_SCOPE,
        storage: localStorage,
        onUnreachable: chatPanel.setUnreachable,
      })
      session = connection.session
      tryAgain = connection.tryAgain
      session.onChange(showAttention)
      chatPanel.attach(session)
    },
    (error) => {
      chatPanel.showSignedIn(email, error.message)
      tryAgain = () => startChat(email)
      chatPanel.offerTryAgain()
    },
  )
}

// ---------------------------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------------------------

giveKeysToGame(canvas, document.querySelector('.table-area'), byId('chat'))

api.loadActive('arena')
api.loadActive('flipper')
updateDemoButton()
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
