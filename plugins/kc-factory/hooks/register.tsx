import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { JobCard } from '../types'
import { isRunning, jobCard, widgetLine } from './cards'

const PANE = 'kc-factory'
const PANE_TITLE = 'Factory'
// job.sh writes it under the repository's root; the session's project root is that root.
const INDEX_PATH = '.factory/jobs/index.json'
const REFRESH_MS = 5_000
// The factory skill moving a job into delivery: the moment worth showing the pane for.
const STARTS_DELIVERY = /job\.sh advance .*\bdelivering\b/

const jobsAtom = atom({ plugin: 'kc-factory', key: 'jobs' } as const, [] as JobCard[])
const lastReadAtom = atom({ plugin: 'kc-factory', key: 'lastRead' } as const, '')

// What outlives a dispatch but not a reload: the open pane's refresh timer and what the
// surface last said about docking a pane.
let refreshTimer: Timer | null = null
let doesDockPanes = false
let hasOpenedUnasked = false

function isJobCard(value: unknown): value is JobCard {
  if (typeof value !== 'object' || value === null) return false
  const job = value as Record<string, unknown>
  return (
    typeof job.key === 'string' &&
    typeof job.stage === 'string' &&
    typeof job.created_at === 'string' &&
    typeof job.updated_at === 'string'
  )
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
  const shouldRefresh = jobs.some(isRunning) && (await isPaneOpen($))
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
  const readAt = new Date(await $.clock.now()).toISOString()
  await update($, jobsAtom, () => jobs)
  await update($, lastReadAtom, () => readAt)
  await syncRefreshTimer($, jobs)
}

const openPane = ($: EngineInterface) => $.ui.open({ id: PANE, title: PANE_TITLE })

// A mod's command is `/<name>`, unnamespaced, and `/dashboard` is a name Claude Code ships.
const COMMAND = 'factory-dashboard'

export const register: Register = (on) => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await $.command.register({ name: COMMAND, description: "Show the factory's jobs in a pane beside the chat" })
    return result
  })

  on('command.run', { command: COMMAND }, async ($) => {
    await openPane($)
    return { text: 'Factory pane opened.' }
  }).catch(($, e, next) => next(e))

  // Every open of the pane, asked for or not, reads the index afresh.
  on('ui.open', { id: PANE }, async ($, e, next) => {
    const result = await next(e)
    await refresh($)
    return result
  }).catch(($, e, next) => next(e))

  // Observes only: the call runs as asked and its result passes on unchanged.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const result = await next(e)
    if (doesDockPanes && !hasOpenedUnasked && STARTS_DELIVERY.test(e.command)) {
      hasOpenedUnasked = true
      await openPane($)
    }
    return result
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
      return <draw.Box flexDirection="column">{jobs.map((job) => widgetLine(draw, job))}</draw.Box>
    }
    const nowMs = Date.parse(lastRead)
    return (
      <draw.Box flexDirection="column">{jobs.map((job) => jobCard(draw, job, nowMs, e.props.bodyColumns))}</draw.Box>
    )
  })
}
