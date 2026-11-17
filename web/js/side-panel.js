/**
 * The machine's display beside the table: ball number, score, the two message boxes, the clock,
 * and the floating texts over the table. It shows what the game's `hud` and `floating` messages
 * say and decides nothing itself.
 */

/** The display has this many digit places until a score needs more. */
const SCORE_PLACES = 7
const FLOATING_COLOURS = ['yellow', 'red', 'green', 'blue', 'white']
/** What a floating text is: a text piece of the table, a rule's message, or a score change. */
const FLOATING_KINDS = ['text', 'message', 'score']

/**
 * The score's digits in groups of three, `50000` as `['50', '000']`. The segment font has no
 * comma, so the display sets the groups a little apart instead.
 */
export function scoreGroups(score) {
  return score.toLocaleString('en-US').split(',')
}

/** `412` seconds as `6:52`. */
export function clockText(seconds) {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`
}

export function ballText(hud) {
  if (hud.phase === 'over') return 'GAME OVER'
  return `BALL ${hud.ballNumber} OF ${hud.ballsPerEpisode}`
}

/** The small warnings under the message boxes, as `{ text, tone }`. */
export function flagsOf(hud) {
  const flags = []
  if (hud.tilted) flags.push({ text: 'TILT', tone: 'red' })
  else if (hud.tiltWarnings > 0) flags.push({ text: `TILT WARNING ${hud.tiltWarnings}`, tone: 'yellow' })
  if (hud.ballSaveActive) flags.push({ text: 'BALL SAVE', tone: 'green' })
  return flags
}

/** The colour class and the kind of one floating item. Anything unknown shows as a plain white text. */
export function floatingLook({ colour, kind }) {
  return {
    className: `lamp-${FLOATING_COLOURS.includes(colour) ? colour : 'white'}`,
    kind: FLOATING_KINDS.includes(kind) ? kind : 'text',
  }
}

function spans(className, texts) {
  const row = document.createElement('span')
  row.className = className
  for (const text of texts) {
    const group = document.createElement('span')
    group.textContent = text
    row.append(group)
  }
  return row
}

/** Fills a score element: the lit digits over a row of unlit `8`s, as on a segment display. */
export function drawScore(element, score) {
  const groups = scoreGroups(score)
  const digits = groups.join('').length
  const places = Math.max(SCORE_PLACES, digits)
  const unlit = scoreGroups(Number('8'.repeat(places)))
  element.style.setProperty('--places', places)
  element.style.setProperty('--gaps', unlit.length - 1)
  element.setAttribute('aria-label', `Score ${score.toLocaleString('en-US')}`)
  element.replaceChildren(spans('score-unlit', unlit), spans('score-lit', groups))
}

/** `elements` holds the display's parts: `ballLine`, `score`, `quest`, `award`, `flags`, `clock`, `floating`. */
export function createSidePanel(elements) {
  drawScore(elements.score, 0)

  return {
    showHud(hud) {
      elements.ballLine.textContent = ballText(hud)
      drawScore(elements.score, hud.score)
      elements.quest.textContent = hud.quest
      elements.award.textContent = hud.award
      elements.clock.textContent = `CLOCK ${clockText(hud.clockSeconds)} LEFT`
      elements.flags.replaceChildren(
        ...flagsOf(hud).map(({ text, tone }) => {
          const flag = document.createElement('span')
          flag.className = `lamp-${tone}`
          flag.textContent = text
          return flag
        }),
      )
    },

    /**
     * `items` is the full set of texts hovering over the table, placed by fractions of its size.
     * styles.css gives each kind its own look through `data-kind`.
     */
    showFloating(items) {
      elements.floating.replaceChildren(
        ...items.map(({ x, y, text, ...item }) => {
          const look = floatingLook(item)
          const label = document.createElement('span')
          label.className = look.className
          label.dataset.kind = look.kind
          label.style.left = `${x * 100}%`
          label.style.top = `${y * 100}%`
          label.textContent = text
          return label
        }),
      )
    },
  }
}
