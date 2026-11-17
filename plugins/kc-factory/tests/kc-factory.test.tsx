import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

import { formatCost, formatElapsed } from '../hooks/job-format'

const ROOT = '/work/shop'
const INDEX = `${ROOT}/.factory/jobs/index.json`
const NOW = Date.parse('2026-11-16T12:00:00Z')
const SECOND = 1_000

const ORDER_TOTALS = {
  key: 'ABC-1',
  title: 'Show order totals on the storefront',
  stage: 'delivering',
  risk: 'low',
  surfaces: ['ui'],
  created_at: '2026-11-16T11:48:00Z',
  updated_at: '2026-11-16T11:50:00Z',
  history: [],
  cost_usd: 1.5,
}
const REFUND_EMAILS = {
  key: 'ABC-2',
  title: 'Email the customer when a refund is issued',
  stage: 'ready',
  risk: 'medium',
  surfaces: ['api', 'email'],
  pr_url: 'https://github.com/example/shop/pull/12',
  created_at: '2026-11-16T10:00:00Z',
  updated_at: '2026-11-16T10:42:00Z',
  history: [],
  cost_usd: null,
}

const paneProps = (placement: 'dock' | 'widget') => ({
  title: 'Factory',
  isFocused: false,
  bodyColumns: 60,
  placement,
  scroll: { offset: 0, bodyRows: 30 },
  view: {},
})

const BAND_PROPS = {
  hasSurvey: false,
  isCollapsed: false,
  isWorking: false,
  maxRows: 20,
  bodyColumns: 120,
  scroll: { offset: 0, bodyRows: 20 },
  view: {},
}

const OPEN_PANE = { id: 'kc-factory', title: 'Factory', isShown: true, isFocused: false, isPlaced: true }
// What the engine beneath draws for a component the plugin passes on; the stub returns a
// stand-in, typed `never` because the engine's own element type is not constructible here.
const ENGINE_DRAWING = { type: 'engine', ref: 0 } as never

type World = { index: string | undefined; opened: string[]; reads: number; isPaneOpen: boolean }

// The engine beneath the plugin: a project root, one index file (or none) and a pane that opens.
function buildWorld(on: On, index: string | undefined) {
  const state: World = { index, opened: [], reads: 0, isPaneOpen: false }
  const clock = mock.clock(on, { now: NOW })
  on('session.root', () => ({ value: ROOT }))
  on('fs.read', (_, e) => {
    state.reads += 1
    if (e.path !== INDEX || state.index === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: state.index }
  })
  on('command.register', () => ({ value: { command: 'factory-dashboard' } }))
  on('ui.open', (_, e) => {
    state.opened.push(e.id)
    state.isPaneOpen = true
    return { value: { isPlaced: true } }
  })
  on('ui.panes', () => ({
    value: state.isPaneOpen ? [OPEN_PANE] : [],
  }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: {} }))
  on('ui.render', () => ENGINE_DRAWING)
  return { state, clock }
}

// The person's /factory-dashboard: the plugin's own `$.ui.open` raises `ui.open` beneath it.
const runDashboard = ($: Engine) =>
  $.command.run({
    command: 'factory-dashboard',
    args: '',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 200 },
  })

describe('format', () => {
  test('elapsed time', async () => {
    expect([formatElapsed(45 * SECOND), formatElapsed(12 * 60 * SECOND), formatElapsed(2 * 3_600 * SECOND + 5 * 60 * SECOND)]).toEqual([
      '45s',
      '12m',
      '2h 5m',
    ])
  })

  test('cost', async () => {
    expect([formatCost(1.5, false), formatCost(null, false), formatCost(undefined, false)]).toEqual(['$1.50', 'cost unavailable', 'cost unavailable'])
  })

  test('a partial cost is a lower bound', async () => {
    expect([formatCost(1.5, true), formatCost(1.5, false), formatCost(null, true)]).toEqual(['$1.50+', '$1.50', 'cost unavailable'])
  })
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`no index file draws "No factory jobs yet" on ${surface}`, async ($, on) => {
    buildWorld(on, undefined)
    await runDashboard($)

    const ui = await $.ui.mount({ plugin: 'kc-factory', surface, component: 'Pane', requestId: 'kc-factory', props: paneProps('dock') })
    expect((await ui.find({ type: 'Text', text: /No factory jobs yet/ }))?.text).toBe('No factory jobs yet')
    await ui.unmount()
  })

  test(`an unparsable index draws "No factory jobs yet" on ${surface}`, async ($, on) => {
    buildWorld(on, '{ not json')
    await runDashboard($)

    const ui = await $.ui.mount({ plugin: 'kc-factory', surface, component: 'Pane', requestId: 'kc-factory', props: paneProps('dock') })
    expect((await ui.find({ type: 'Text', text: /No factory jobs yet/ }))?.text).toBe('No factory jobs yet')
    await ui.unmount()
  })

  test(`two jobs draw two cards with their stages on ${surface}`, async ($, on) => {
    buildWorld(on, JSON.stringify([ORDER_TOTALS, REFUND_EMAILS]))
    await runDashboard($)

    const ui = await $.ui.mount({ plugin: 'kc-factory', surface, component: 'Pane', requestId: 'kc-factory', props: paneProps('dock') })
    const drawn = JSON.stringify(await ui.drawn())
    for (const shown of [
      'ABC-1',
      'Show order totals on the storefront',
      'delivering',
      'risk low',
      'ui',
      '12m', // running: now − created_at
      '$1.50',
      'ABC-2',
      'ready',
      'risk medium',
      'api, email',
      '42m', // finished: updated_at − created_at
      'https://github.com/example/shop/pull/12',
    ]) {
      expect(drawn).toContain(shown)
    }
    await ui.unmount()
  })

  test(`a null cost draws "cost unavailable" on ${surface}`, async ($, on) => {
    buildWorld(on, JSON.stringify([REFUND_EMAILS]))
    await runDashboard($)

    const ui = await $.ui.mount({ plugin: 'kc-factory', surface, component: 'Pane', requestId: 'kc-factory', props: paneProps('dock') })
    expect(JSON.stringify(await ui.drawn())).toContain('cost unavailable')
    await ui.unmount()
  })

  test(`a partial cost draws "$X+" and says what it leaves out on ${surface}`, async ($, on) => {
    buildWorld(on, JSON.stringify([{ ...ORDER_TOTALS, cost_partial: true }]))
    await runDashboard($)

    const ui = await $.ui.mount({ plugin: 'kc-factory', surface, component: 'Pane', requestId: 'kc-factory', props: paneProps('dock') })
    const drawn = JSON.stringify(await ui.drawn())
    expect(drawn).toContain('$1.50+')
    expect(drawn).toContain('agents shared across the run not included')
    await ui.unmount()
  })

  test(`a whole cost has no "+" and no note on ${surface}`, async ($, on) => {
    buildWorld(on, JSON.stringify([ORDER_TOTALS]))
    await runDashboard($)

    const ui = await $.ui.mount({ plugin: 'kc-factory', surface, component: 'Pane', requestId: 'kc-factory', props: paneProps('dock') })
    const drawn = JSON.stringify(await ui.drawn())
    expect(drawn).not.toContain('$1.50+')
    expect(drawn).not.toContain('agents shared across the run not included')
    await ui.unmount()
  })

  test(`the widget draws one line per job on ${surface}`, async ($, on) => {
    buildWorld(on, JSON.stringify([ORDER_TOTALS, REFUND_EMAILS]))
    await runDashboard($)

    const ui = await $.ui.mount({ plugin: 'kc-factory', surface, component: 'Pane', requestId: 'kc-factory', props: paneProps('widget') })
    expect((await ui.find({ type: 'Text', text: /ABC-1/ }))?.text).toBe('ABC-1 delivering')
    expect((await ui.find({ type: 'Text', text: /ABC-2/ }))?.text).toBe('ABC-2 ready')
    expect(JSON.stringify(await ui.drawn())).not.toContain('Show order totals')
    await ui.unmount()
  })

  test(`advancing the clock re-reads a changed index on ${surface}`, async ($, on) => {
    const { state, clock } = buildWorld(on, JSON.stringify([ORDER_TOTALS]))
    await runDashboard($)
    const ui = await $.ui.mount({ plugin: 'kc-factory', surface, component: 'Pane', requestId: 'kc-factory', props: paneProps('widget') })
    expect((await ui.find({ type: 'Text', text: /ABC-1/ }))?.text).toBe('ABC-1 delivering')

    state.index = JSON.stringify([{ ...ORDER_TOTALS, stage: 'ready', updated_at: '2026-11-16T12:00:04Z' }])
    await clock.advance(5 * SECOND)

    expect((await ui.find({ type: 'Text', text: /ABC-1/ }))?.text).toBe('ABC-1 ready')
    await ui.unmount()
  })

  test(`the refresh stops once no job is running on ${surface}`, async ($, on) => {
    const { state, clock } = buildWorld(on, JSON.stringify([ORDER_TOTALS]))
    await runDashboard($)
    state.index = JSON.stringify([{ ...ORDER_TOTALS, stage: 'ready' }])
    await clock.advance(5 * SECOND)
    const readsWhenDone = state.reads

    await clock.advance(30 * SECOND)
    expect(state.reads).toBe(readsWhenDone)
  })

  test(`closing the pane stops the refresh on ${surface}`, async ($, on) => {
    const { state, clock } = buildWorld(on, JSON.stringify([ORDER_TOTALS]))
    await runDashboard($)
    // The person's close mark: the engine no longer lists the pane.
    state.isPaneOpen = false
    await clock.advance(5 * SECOND)
    const readsWhenClosed = state.reads

    await clock.advance(30 * SECOND)
    expect(state.reads).toBe(readsWhenClosed)
  })
}

test('/factory-dashboard opens the pane', async ($, on) => {
  const { state } = buildWorld(on, undefined)
  await $.session.start({ cwd: ROOT, surface: 'terminal', isInteractive: true })
  await runDashboard($)
  expect(state.opened).toEqual(['kc-factory'])
})

const ADVANCE_TO_DELIVERING = 'bash /plugins/kc-factory/scripts/job.sh advance ABC-1 delivering'

test('the first delivering stage opens the pane where it docks beside the chat', async ($, on) => {
  const { state } = buildWorld(on, JSON.stringify([ORDER_TOTALS]))
  const band = await $.ui.mount({
    plugin: 'kc-factory',
    surface: 'terminal',
    component: 'AbovePrompt',
    props: BAND_PROPS,
    viewport: { columns: 200, rows: 50, isFullscreen: true },
  })
  await band.unmount()

  await $.tool.call({ tool: 'Bash', command: 'git status' })
  expect(state.opened).toEqual([])
  await $.tool.call({ tool: 'Bash', command: ADVANCE_TO_DELIVERING })
  expect(state.opened).toEqual(['kc-factory'])

  // A later job's delivery leaves a pane the person closed closed.
  await $.tool.call({ tool: 'Bash', command: ADVANCE_TO_DELIVERING.replace('ABC-1', 'ABC-2') })
  expect(state.opened).toEqual(['kc-factory'])
})

test('a later job write redraws a pane that is still open', async ($, on) => {
  const { state } = buildWorld(on, JSON.stringify([{ ...ORDER_TOTALS, stage: 'ready' }]))
  await runDashboard($)
  const ui = await $.ui.mount({ plugin: 'kc-factory', surface: 'terminal', component: 'Pane', requestId: 'kc-factory', props: paneProps('widget') })
  expect((await ui.find({ type: 'Text', text: /ABC-1/ }))?.text).toBe('ABC-1 ready')

  // A second run: nothing is running, so no timer is going; the job write itself redraws.
  state.index = JSON.stringify([{ ...ORDER_TOTALS, stage: 'delivering' }])
  await $.tool.call({ tool: 'Bash', command: ADVANCE_TO_DELIVERING })

  expect((await ui.find({ type: 'Text', text: /ABC-1/ }))?.text).toBe('ABC-1 delivering')
  await ui.unmount()
})

test('the delivering stage leaves the pane closed where it would not dock', async ($, on) => {
  const { state } = buildWorld(on, JSON.stringify([ORDER_TOTALS]))
  const band = await $.ui.mount({
    plugin: 'kc-factory',
    surface: 'terminal',
    component: 'AbovePrompt',
    props: BAND_PROPS,
    viewport: { columns: 200, rows: 50, isFullscreen: false },
  })
  await band.unmount()

  await $.tool.call({ tool: 'Bash', command: ADVANCE_TO_DELIVERING })
  expect(state.opened).toEqual([])
})
