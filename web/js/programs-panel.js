/** Program activation and failure notices in the Cogent terminal. */

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

/** `ramp-school v3`. The built-in programs have no versions to tell apart. */
export function programLabel({ name, version }) {
  return name === 'house' || name === 'demo' ? name : `${name} v${version}`
}

/** `effect` is when a table program takes effect, as in `programs.js`. A Flipper program plays at once. */
export function effectLine(program, effect) {
  if (program.seat === 'flipper') return `${programLabel(program)} plays the flippers now.`
  return `${programLabel(program)} ${EFFECT_WORDING[effect]}.`
}

/** `failure` is the game's `programError` message. */
export function failureLine(failure) {
  return `${programLabel(failure)} ${FAILURE_WORDING[failure.stage]}: ${failure.message}`
}

export function createProgramsPanel(elements, onRestart) {
  elements.restart.addEventListener('click', onRestart)

  return {
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
