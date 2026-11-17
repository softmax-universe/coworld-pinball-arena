import test from 'node:test'
import assert from 'node:assert/strict'

import { conversationItems, cogentWording } from '../js/chat-panel.js'
import { nextResumeTime, reconnectDelay } from '../js/cogent-connection.js'
import { effectLine, failureLine } from '../js/programs-panel.js'
import { ballText, clockText, flagsOf, scoreGroups } from '../js/side-panel.js'

const message = (sequence, role, content, requestId) => ({
  sequence,
  request_id: requestId,
  message: { role, content },
})

test('the display shows the score in groups of three, the clock as minutes and seconds', () => {
  assert.deepEqual(scoreGroups(50000), ['50', '000'])
  assert.deepEqual(scoreGroups(0), ['0'])
  assert.deepEqual(scoreGroups(1234567), ['1', '234', '567'])
  assert.equal(clockText(412), '6:52')
  assert.equal(clockText(5), '0:05')
})

test('the ball line gives the ball number its context, and says when the game is over', () => {
  assert.equal(ballText({ phase: 'play', ballNumber: 2, ballsPerEpisode: 3 }), 'BALL 2 OF 3')
  assert.equal(ballText({ phase: 'over', ballNumber: 3, ballsPerEpisode: 3 }), 'GAME OVER')
})

test('tilt warnings and ball save show only while they apply; a tilt replaces its warnings', () => {
  assert.deepEqual(flagsOf({ tiltWarnings: 0, tilted: false, ballSaveActive: false }), [])
  assert.deepEqual(
    flagsOf({ tiltWarnings: 2, tilted: false, ballSaveActive: true }).map((flag) => flag.text),
    ['TILT WARNING 2', 'BALL SAVE'],
  )
  assert.deepEqual(
    flagsOf({ tiltWarnings: 2, tilted: true, ballSaveActive: false }).map((flag) => flag.text),
    ['TILT'],
  )
})

test('a message the person just sent shows at once, with its request status under it', () => {
  const items = conversationItems({
    messages: [message(1, 'user', 'hello'), message(2, 'assistant', 'Hello. What table would you like?')],
    requests: [{ id: 'r1', status: 'queued', wording: 'Queued', until: null, text: 'more ramps' }],
  })
  assert.deepEqual(
    items.map((item) => [item.kind, item.who ?? item.status, item.text ?? item.wording]),
    [
      ['message', 'person', 'hello'],
      ['message', 'cogent', 'Hello. What table would you like?'],
      ['message', 'person', 'more ramps'],
      ['status', 'queued', 'Queued'],
    ],
  )
  assert.equal(items.at(-1).canCancel, true)
})

test('once history has the sent message it is shown once, and a finished request has no status line', () => {
  const state = {
    messages: [message(1, 'user', 'more ramps', 'r1'), message(2, 'assistant', 'Two ramps added.', 'r1')],
    requests: [{ id: 'r1', status: 'completed', wording: '', until: null, text: 'more ramps' }],
  }
  assert.deepEqual(
    conversationItems(state).map((item) => item.text),
    ['more ramps', 'Two ramps added.'],
  )
})

test('a request status follows the last message of its own request, not the end of the chat', () => {
  const items = conversationItems({
    messages: [message(1, 'user', 'first', 'r1'), message(2, 'user', 'second', 'r2')],
    requests: [
      { id: 'r1', status: 'failed', wording: 'The cogent could not finish this', until: null },
      { id: 'r2', status: 'running', wording: 'Working', until: null },
    ],
  })
  assert.deepEqual(
    items.map((item) => item.text ?? item.wording),
    ['first', 'The cogent could not finish this', 'second', 'Working'],
  )
  assert.equal(items[1].canCancel, false)
})

test('tool traffic and empty assistant turns are not conversation; text parts are joined', () => {
  const items = conversationItems({
    messages: [
      message(1, 'assistant', null),
      message(2, 'tool', '{"ok":true}'),
      message(3, 'assistant', [
        { type: 'text', text: 'Here is ' },
        { type: 'text', text: 'the plan.' },
      ]),
    ],
    requests: [],
  })
  assert.deepEqual(
    items.map((item) => item.text),
    ['Here is the plan.'],
  )
})

test('after repeated failed connections the panel says the cogent cannot be reached', () => {
  assert.match(cogentWording('connecting', false), /Connecting/)
  assert.match(cogentWording('connecting', true), /Cannot reach/)
  assert.match(cogentWording('ready', true), /ready/)
})

test('reconnecting backs off from one second and never waits more than thirty', () => {
  assert.deepEqual([0, 1, 2, 3].map(reconnectDelay), [1000, 2000, 4000, 8000])
  assert.equal(reconnectDelay(20), 30000)
})

test('the session is asked to continue at the earliest hold time still ahead', () => {
  const now = Date.parse('2026-11-17T12:00:00Z')
  const requests = [
    { status: 'waiting', until: '2026-11-17T11:00:00Z' },
    { status: 'waiting', until: '2026-11-17T14:00:00Z' },
    { status: 'waiting', until: '2026-11-17T13:00:00Z' },
    { status: 'waiting', until: null },
    { status: 'running', until: null },
  ]
  assert.equal(nextResumeTime(requests, now), Date.parse('2026-11-17T13:00:00Z'))
  assert.equal(nextResumeTime(requests.slice(0, 1), now), null)
})

test('program notices name the program and say when it plays or how it failed', () => {
  assert.equal(effectLine({ name: 'ramp-school', version: 3 }, 'next-ball'), 'ramp-school v3 plays from the next ball.')
  assert.equal(effectLine({ name: 'house', version: 1 }, 'next-episode'), 'house plays from the next Episode.')
  assert.equal(
    failureLine({ name: 'ramp-school', version: 3, stage: 'compile', message: 'Line 12: NEXT without FOR' }),
    'ramp-school v3 could not be read: Line 12: NEXT without FOR',
  )
})
