import type { JobCard, JobStage } from '../types'

const SECOND_MS = 1_000
const MINUTE_MS = 60 * SECOND_MS
const HOUR_MS = 60 * MINUTE_MS

// Stages a job is still moving through, so its clock is still running.
const RUNNING_STAGES: readonly JobStage[] = ['intake', 'queued', 'delivering']

/** Whether the job is still moving through the factory, so its elapsed time still counts. */
export function isJobRunning(job: JobCard): boolean {
  return RUNNING_STAGES.includes(job.stage)
}

/** Milliseconds since the job was created: up to `nowMs` while it runs, up to its last update once it stops. Null when a time does not parse. */
export function getElapsedMs(job: JobCard, nowMs: number): number | null {
  const startMs = Date.parse(job.created_at)
  const endMs = isJobRunning(job) ? nowMs : Date.parse(job.updated_at)
  if (Number.isNaN(startMs) || Number.isNaN(endMs)) return null
  return Math.max(0, endMs - startMs)
}

/** A duration as "45s", "12m" or "2h 5m". */
export function formatElapsed(ms: number): string {
  if (ms < MINUTE_MS) return `${Math.floor(ms / SECOND_MS)}s`
  if (ms < HOUR_MS) return `${Math.floor(ms / MINUTE_MS)}m`
  return `${Math.floor(ms / HOUR_MS)}h ${Math.floor((ms % HOUR_MS) / MINUTE_MS)}m`
}

/** What a partial cost leaves out: run-wide agents (review prep, gates, triage, shipping) no one job owns. */
export const PARTIAL_COST_NOTE = 'agents shared across the run not included'

/** A cost as "$1.50", "$1.50+" when it is a lower bound, or "cost unavailable". */
export function formatCost(costUsd: number | null | undefined, isPartial: boolean): string {
  if (typeof costUsd !== 'number') return 'cost unavailable'
  return `$${costUsd.toFixed(2)}${isPartial ? '+' : ''}`
}
