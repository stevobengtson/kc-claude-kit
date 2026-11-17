import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { JobCard } from '../types'
import { renderJobCard, renderWidgetLine } from './job-cards'
import { isJobRunning } from './job-format'

const PANE = 'kc-factory'
const PANE_TITLE = 'Factory'
// job.sh writes <repo>/.factory/jobs/index.json unless FACTORY_HOME is set; the pane reads
// that default under the session's project root, so a repo that sets FACTORY_HOME, or a
// session started below the repo root, shows no jobs here.
const INDEX_PATH = '.factory/jobs/index.json'
const REFRESH_MS = 5_000
// The factory skill moving a job into delivery: the moment worth showing the pane for.
const STARTS_DELIVERY = /job\.sh advance .*\bdelivering\b/
// Any job.sh write: what an open pane redraws on.
const WRITES_JOB = /job\.sh (create|advance|set)\b/
const CARD_GAP = 1

const jobsAtom = atom({ plugin: 'kc-factory', key: 'jobs' } as const, [] as JobCard[])
const lastReadAtom = atom({ plugin: 'kc-factory', key: 'lastRead' } as const, 0)

// What outlives a dispatch but not a reload: the open pane's refresh timer and what the
// surface last said about docking a pane.
let refreshTimer: Timer | null = null
let doesDockPanes = false
let hasOpenedUnasked = false

function isJobCard(value: unknown): value is JobCard {
  if (typeof value !== 'object' || value === null) return false
  const job = value as Record<string, unknown>
  const hasRequiredStrings = ['key', 'stage', 'created_at', 'updated_at'].every((field) => typeof job[field] === 'string')
  return hasRequiredStrings
}

// A missing or unparsable index is no jobs: the pane is a view, never a place to report errors.
async function readJobs($: EngineInterface): Promise<JobCard[]> {
  try {
    const root = await $.session.root()
    const parsed: unknown = JSON.parse(await $.fs.read(`${root}/${INDEX_PATH}`))
    return Array.isArray(parsed) ? parsed.filter(isJobCard) : []
  } catch {
    return []
  }
}

// The engine's record, not the module's, so a pane the person closed is seen as closed.
async function isPaneOpen($: EngineInterface): Promise<boolean> {
  try {
    return (await $.ui.panes()).some((pane) => pane.id === PANE)
  } catch {
    return false
  }
}

// The timer runs only while the pane is open and a job's elapsed time or stage can still move.
async function syncRefreshTimer($: EngineInterface, jobs: readonly JobCard[]): Promise<void> {
  const shouldRefresh = jobs.some(isJobRunning) && (await isPaneOpen($))
  if (shouldRefresh && refreshTimer === null) {
    // A tick that fails leaves the last drawing up; the next tick tries again.
    refreshTimer = $.clock.every(REFRESH_MS, () => void refresh($).catch(() => undefined))
  } else if (!shouldRefresh && refreshTimer !== null) {
    refreshTimer.cancel()
    refreshTimer = null
  }
}

async function refresh($: EngineInterface): Promise<void> {
  const jobs = await readJobs($)
  const readAtMs = await $.clock.now()
  await update($, jobsAtom, () => jobs)
  await update($, lastReadAtom, () => readAtMs)
  await syncRefreshTimer($, jobs)
}

const openPane = ($: EngineInterface) => $.ui.open({ id: PANE, title: PANE_TITLE })

// A mod's command is `/<name>`, unnamespaced, and `/dashboard` is a name Claude Code ships.
const COMMAND = 'factory-dashboard'

export const register: Register = (on) => {
  on('session.start', async ($, e, next) => {
    const hostResult = await next(e)
    await $.command.register({ name: COMMAND, description: "Show the factory's jobs in a pane beside the chat" })
    return hostResult
  })

  on('command.run', { command: COMMAND }, async ($) => {
    await openPane($)
    return { text: 'Factory pane opened.' }
  }).catch(($, e, next) => next(e))

  // Every open of the pane, asked for or not, reads the index afresh.
  on('ui.open', { id: PANE }, async ($, e, next) => {
    const hostResult = await next(e)
    await refresh($)
    return hostResult
  }).catch(($, e, next) => next(e))

  // Observes only: the call runs as asked and its result passes on unchanged. A job write
  // redraws an open pane (and restarts its timer); the first delivery opens it, once.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const hostResult = await next(e)
    const isDeliveryStart = STARTS_DELIVERY.test(e.command)
    const canOpenUnasked = doesDockPanes && !hasOpenedUnasked
    if (canOpenUnasked && isDeliveryStart) {
      hasOpenedUnasked = true
      await openPane($)
    } else if (WRITES_JOB.test(e.command) && (await isPaneOpen($))) {
      await refresh($)
    }
    return hostResult
  }).catch(($, e, next) => next(e))

  // Draws nothing: it only learns whether this surface docks a pane beside the chat, so the
  // pane opens unasked only where it is a sidebar and never takes over the screen.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.viewport?.isFullscreen !== undefined) doesDockPanes = e.viewport.isFullscreen
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const draw = $.ui.resolve(e)
    const jobs = await read($, jobsAtom)
    const lastRead = await read($, lastReadAtom)
    if (jobs.length === 0) return <draw.Text dimColor>No factory jobs yet</draw.Text>

    if (e.props.placement === 'widget') {
      return <draw.Box flexDirection="column">{jobs.map((job) => renderWidgetLine(draw, job))}</draw.Box>
    }
    return (
      <draw.Box flexDirection="column" rowGap={CARD_GAP}>
        {jobs.map((job) => renderJobCard(draw, job, lastRead, e.props.bodyColumns))}
      </draw.Box>
    )
  })
}
