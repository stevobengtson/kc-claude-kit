export type JobStage = 'intake' | 'needs-info' | 'rejected' | 'queued' | 'delivering' | 'ready' | 'blocked'

// One job as `.factory/jobs/index.json` lists it (job.sh writes it); `history` is not drawn.
export type JobCard = {
  key: string
  title?: string
  stage: JobStage
  risk?: string
  surfaces?: string[]
  pr_url?: string
  reason?: string
  cost_usd?: number | null
  // true when cost_usd leaves out agents the whole run shared, so it is a lower bound.
  cost_partial?: boolean
  created_at: string
  updated_at: string
}

declare module 'claude-code' {
  interface PluginState {
    // `lastRead` is when the index was last read, as an ISO time: the "now" elapsed times count to.
    'kc-factory': { jobs: JobCard[]; lastRead: string }
  }
}
