import type { Elements, RenderElement } from 'claude-code'

import type { JobCard, JobStage } from '../types'

// The elements a card draws with; every surface's table has these three.
type Draw = Pick<Elements['terminal'], 'Box' | 'Text' | 'Link'>

const MINUTE_MS = 60_000
const HOUR_MS = 60 * MINUTE_MS

// Stages a job is still moving through, so its clock is still running.
const RUNNING_STAGES: readonly JobStage[] = ['intake', 'queued', 'delivering']

const STAGE_COLOR: Partial<Record<JobStage, string>> = {
  ready: '#4a8a52',
  blocked: '#a3141c',
  rejected: '#a3141c',
  'needs-info': '#7a4a00',
}

export function isRunning(job: JobCard): boolean {
  return RUNNING_STAGES.includes(job.stage)
}

// A running job counts up to `nowMs`; a finished one stops at its last update.
function elapsedMs(job: JobCard, nowMs: number): number | null {
  const startMs = Date.parse(job.created_at)
  const endMs = isRunning(job) ? nowMs : Date.parse(job.updated_at)
  if (Number.isNaN(startMs) || Number.isNaN(endMs)) return null
  return Math.max(0, endMs - startMs)
}

export function formatElapsed(ms: number): string {
  if (ms < MINUTE_MS) return `${Math.floor(ms / 1_000)}s`
  if (ms < HOUR_MS) return `${Math.floor(ms / MINUTE_MS)}m`
  return `${Math.floor(ms / HOUR_MS)}h ${Math.floor((ms % HOUR_MS) / MINUTE_MS)}m`
}

// What a partial cost leaves out: run-wide agents (review prep, gates, shipping) no one job owns.
export const PARTIAL_COST_NOTE = 'agents shared across the run not included'

// A partial cost is a lower bound, so it reads "$X+".
export function formatCost(costUsd: number | null | undefined, isPartial = false): string {
  if (typeof costUsd !== 'number') return 'cost unavailable'
  return `$${costUsd.toFixed(2)}${isPartial ? '+' : ''}`
}

export function jobCard({ Box, Text, Link }: Draw, job: JobCard, nowMs: number, width: number): RenderElement {
  const elapsed = elapsedMs(job, nowMs)
  const details = [
    job.risk === undefined ? null : `risk ${job.risk}`,
    job.surfaces === undefined || job.surfaces.length === 0 ? null : job.surfaces.join(', '),
    formatCost(job.cost_usd, job.cost_partial === true),
  ].filter((detail): detail is string => detail !== null)
  const isCostPartial = job.cost_partial === true && typeof job.cost_usd === 'number'

  return (
    <Box key={job.key} flexDirection="column" width={width} marginBottom={1}>
      <Text>
        <Text bold>{job.key}</Text>
        <Text color={STAGE_COLOR[job.stage]}>{`  ${job.stage}`}</Text>
        <Text dimColor>{elapsed === null ? '' : `  ${formatElapsed(elapsed)}`}</Text>
      </Text>
      {job.title !== undefined && <Text>{job.title}</Text>}
      <Text dimColor>{details.join(' · ')}</Text>
      {isCostPartial && <Text dimColor>{`cost: ${PARTIAL_COST_NOTE}`}</Text>}
      {job.reason !== undefined && <Text dimColor>{job.reason}</Text>}
      {job.pr_url !== undefined && <Link href={job.pr_url} />}
    </Box>
  )
}

// A minimized pane on the desktop app: one glanceable line per job.
export function widgetLine({ Text }: Draw, job: JobCard): RenderElement {
  return <Text>{`${job.key} ${job.stage}`}</Text>
}
