/**
 * A stand-in for the game build, for working on the page without it. Open the page with
 * `?fake-game` (see main.js) and this script plays the game's part of the bridge described in
 * `web/js/game-bridge.js`: it draws a ball bouncing in the canvas, sends `hud`, `floating`,
 * `episode` and `programLoaded` messages, and obeys `program`, `restart` and `flipper`.
 *
 * A program whose name starts with `broken` gets a `programError` instead of `programLoaded`.
 * `window.fakeGame.endEpisode()` ends the Episode at once, and `window.fakeGame.keys` lists the
 * keys the canvas received.
 */
;(function () {
  const BALLS_PER_EPISODE = 3
  const SECONDS_PER_BALL = 12
  const QUESTS = ['RAMP IS LIT', 'HIT THE DROP TARGETS', 'SHOOT THE LEFT ORBIT']
  const AWARDS = ['JACKPOT 50,000', 'BUMPER 1,000', 'EXTRA BALL', 'RAMP 25,000']

  const canvas = Module.canvas
  const context = canvas.getContext('2d')
  const keys = []
  let episode
  let demo = false
  let lastSecond = 0

  function send(message) {
    Module.pinballMessage(JSON.stringify(message))
  }

  function sendHud() {
    send({
      type: 'hud',
      phase: episode.over ? 'over' : 'play',
      ballNumber: episode.ball,
      ballsPerEpisode: BALLS_PER_EPISODE,
      score: episode.score,
      quest: episode.over ? '' : QUESTS[episode.ball - 1],
      award: episode.award,
      clockSeconds: episode.clock,
      tiltWarnings: episode.clock % 9 === 4 ? 1 : 0,
      tilted: false,
      ballSaveActive: episode.ballSeconds < 4,
    })
  }

  function startEpisode() {
    episode = { ball: 1, ballSeconds: 0, score: 0, award: '', clock: 420, over: false, x: 0.3, y: 0.2, dx: 0.004, dy: 0.006 }
    send({ type: 'floating', items: [] })
    sendHud()
  }

  function endEpisode() {
    if (episode.over) return
    episode.over = true
    send({ type: 'floating', items: [] })
    sendHud()
    send({ type: 'episode', summary: { score: episode.score, ballSeconds: [12, 12, 12], hits: { bumper: 14 }, rulesFired: ['jackpot'] } })
  }

  function everySecond() {
    if (episode.over) return
    episode.clock -= 1
    episode.ballSeconds += 1
    if (episode.ballSeconds % 3 === 0) {
      episode.award = AWARDS[Math.floor(Math.random() * AWARDS.length)]
      episode.score += 12500 * (1 + Math.floor(Math.random() * 40))
      send({
        type: 'floating',
        items: [
          { x: episode.x, y: episode.y, text: episode.award, colour: 'yellow' },
          { x: 0.5, y: 0.12, text: 'BONUS', colour: 'green' },
          { x: 0.22, y: 0.62, text: '2X', colour: 'red' },
        ],
      })
    }
    if (episode.ballSeconds >= SECONDS_PER_BALL) {
      episode.ball += 1
      episode.ballSeconds = 0
    }
    if (episode.ball > BALLS_PER_EPISODE) {
      episode.ball = BALLS_PER_EPISODE
      endEpisode()
    } else {
      sendHud()
    }
  }

  function readInbox() {
    for (const text of Module.pinballInbox.splice(0)) {
      const message = JSON.parse(text)
      if (message.type === 'restart') startEpisode()
      if (message.type === 'flipper') demo = message.mode === 'demo'
      if (message.type === 'program') {
        const { name, version = 1 } = message
        if (name.startsWith('broken')) {
          send({ type: 'programError', name, version, stage: 'compile', message: 'Line 12: NEXT without FOR', output: ['building ramp'] })
        } else {
          send({ type: 'programLoaded', name, version, effect: 'next-episode' })
        }
      }
    }
  }

  function draw() {
    // The size attributes follow the element, as the real game's do.
    const scale = window.devicePixelRatio
    canvas.width = Math.round(canvas.clientWidth * scale)
    canvas.height = Math.round(canvas.clientHeight * scale)
    const { width, height } = canvas

    context.fillStyle = '#15133a'
    context.fillRect(0, 0, width, height)
    context.strokeStyle = '#b4bace'
    context.lineWidth = width * 0.012
    context.strokeRect(width * 0.02, width * 0.02, width * 0.96, height - width * 0.04)

    context.fillStyle = '#ffd23f'
    for (const [x, y] of [[0.3, 0.3], [0.6, 0.25], [0.45, 0.42]]) {
      context.beginPath()
      context.arc(x * width, y * height, width * 0.06, 0, Math.PI * 2)
      context.fill()
    }

    context.strokeStyle = '#e4e7f0'
    context.lineWidth = width * 0.03
    context.lineCap = 'round'
    const flipperLift = keys.at(-1) === 'KeyZ' || keys.at(-1) === 'Slash' ? 0.03 : 0
    context.beginPath()
    context.moveTo(width * 0.25, height * 0.88)
    context.lineTo(width * 0.44, height * (0.91 - flipperLift))
    context.moveTo(width * 0.75, height * 0.88)
    context.lineTo(width * 0.56, height * (0.91 - flipperLift))
    context.stroke()

    if (!episode.over) {
      episode.x += episode.dx
      episode.y += episode.dy
      if (episode.x < 0.06 || episode.x > 0.94) episode.dx = -episode.dx
      if (episode.y < 0.04 || episode.y > 0.86) episode.dy = -episode.dy
    }
    context.fillStyle = '#e4e7f0'
    context.beginPath()
    context.arc(episode.x * width, episode.y * height, width * 0.026, 0, Math.PI * 2)
    context.fill()

    context.fillStyle = '#9aa0bd'
    context.font = `${width * 0.04}px sans-serif`
    context.textAlign = 'center'
    context.fillText(demo ? 'FAKE GAME: DEMO PLAYS' : 'FAKE GAME', width / 2, height * 0.97)
  }

  function frame(time) {
    readInbox()
    const second = Math.floor(time / 1000)
    if (second !== lastSecond) {
      lastSecond = second
      everySecond()
    }
    draw()
    requestAnimationFrame(frame)
  }

  canvas.addEventListener('keydown', (event) => {
    keys.push(event.code)
    event.preventDefault()
  })

  window.fakeGame = { endEpisode, keys }
  startEpisode()
  requestAnimationFrame(frame)
})()
