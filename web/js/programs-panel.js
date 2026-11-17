/**
 * The "table programs" list and the notice above it.
 *
 * The list shows every stored program with the one that plays next marked, and lets the person
 * pick another. The notice says what happened to a program most recently: the cogent sent one,
 * the person picked one, or one failed. With it comes "restart now", because a program usually
 * waits for the next Episode.
 */

const EFFECT_WORDING = {
  'next-episode': 'plays from the next Episode',
  'next-ball': 'plays from the next ball',
  now: 'is on the table now',
}
const FAILURE_WORDING = {
  compile: 'could not be read',
  run: 'stopped with an error',
  budget: 'ran too long and was stopped',
}

/** `ramp-school v3`. The house program has no versions to tell apart. */
export function programLabel({ name, version }) {
  return name === 'house' ? 'house' : `${name} v${version}`
}

/** `effect` is when the program takes effect, as in `programs.js`. */
export function effectLine(program, effect) {
  return `${programLabel(program)} ${EFFECT_WORDING[effect]}.`
}

/** `failure` is the game's `programError` message. */
export function failureLine(failure) {
  return `${programLabel(failure)} ${FAILURE_WORDING[failure.stage]}: ${failure.message}`
}

/**
 * `elements` holds the parts from index.html, `programs` is the program store, `onSelect(name)`
 * runs when the person picks a program and `onRestart()` when they press "restart now".
 */
export function createProgramsPanel(elements, { programs, onSelect, onRestart }) {
  elements.restart.addEventListener('click', onRestart)

  function drawList() {
    const selected = programs.selected()
    elements.list.replaceChildren(
      ...programs.list().map((program) => {
        const isSelected = program.name === selected
        const pick = document.createElement('button')
        pick.type = 'button'
        pick.setAttribute('aria-pressed', isSelected)
        pick.append(programLabel(program))
        if (isSelected) {
          const mark = document.createElement('span')
          mark.textContent = 'PLAYS NEXT'
          pick.append(mark)
        }
        pick.addEventListener('click', () => {
          if (!isSelected) onSelect(program.name)
        })
        const row = document.createElement('li')
        row.append(pick)
        return row
      }),
    )
  }

  drawList()

  return {
    drawList,

    /** `tone` is `new` (from the cogent), `plain` or `error`. `title` may be empty. */
    showNotice({ tone, title = '', detail, canRestart = true }) {
      elements.notice.hidden = false
      elements.notice.dataset.tone = tone
      elements.noticeTitle.textContent = title
      elements.noticeTitle.hidden = title === ''
      elements.noticeDetail.textContent = detail
      elements.restart.hidden = !canRestart
    },

    clearNotice() {
      elements.notice.hidden = true
    },
  }
}
