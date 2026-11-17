import type { Elements, RenderElement } from 'claude-code'

import type { JobCard, JobStage } from '../types'
import { formatCost, formatElapsed, getElapsedMs, PARTIAL_COST_NOTE } from './job-format'

// The elements a card draws with; every surface's table has these three.
type Draw = Pick<Elements['terminal'], 'Box' | 'Text' | 'Link'>

const STAGE_COLOR: Partial<Record<JobStage, string>> = {
  ready: '#4a8a52',
  blocked: '#a3141c',
  rejected: '#a3141c',
  'needs-info': '#7a4a00',
}

/**
 * One job's card in the docked pane: key, stage and elapsed time, then its title, details,
 * reason and PR link. `nowMs` is when the index was last read, the time a running job's
 * clock counts to; `width` is the pane's body width in columns.
 */
export function renderJobCard({ Box, Text, Link }: Draw, job: JobCard, nowMs: number, width: number): RenderElement {
  const elapsedMs = getElapsedMs(job, nowMs)
  const elapsedText = elapsedMs === null ? '' : `  ${formatElapsed(elapsedMs)}`
  const riskText = job.risk === undefined ? null : `risk ${job.risk}`
  const surfaceList = job.surfaces?.join(', ') || null
  const hasPartialFlag = job.cost_partial === true
  const hasCostFigure = typeof job.cost_usd === 'number'
  const isCostPartial = hasPartialFlag && hasCostFigure
  const details = [riskText, surfaceList, formatCost(job.cost_usd, hasPartialFlag)].filter(
    (detail): detail is string => detail !== null,
  )

  return (
    <Box key={job.key} flexDirection="column" width={width}>
      <Text>
        <Text bold>{job.key}</Text>
        <Text color={STAGE_COLOR[job.stage]}>{`  ${job.stage}`}</Text>
        <Text dimColor>{elapsedText}</Text>
      </Text>
      {job.title !== undefined && <Text>{job.title}</Text>}
      <Text dimColor>{details.join(' · ')}</Text>
      {isCostPartial && <Text dimColor>{`cost: ${PARTIAL_COST_NOTE}`}</Text>}
      {job.reason !== undefined && <Text dimColor>{job.reason}</Text>}
      {job.pr_url !== undefined && <Link href={job.pr_url} />}
    </Box>
  )
}

/** One glanceable line per job, for a pane minimized to a widget on the desktop app. */
export function renderWidgetLine({ Text }: Draw, job: JobCard): RenderElement {
  return <Text key={job.key}>{`${job.key} ${job.stage}`}</Text>
}
