---
type: regex
target: {source: file, path: .factory/jobs/ABC-1/intake.md}
pattern: "\\n## Scope[ \\t]*\\r?\\n\\s*\\S[\\s\\S]*\\n## Acceptance criteria[ \\t]*\\r?\\n\\s*1\\.\\s+\\S[\\s\\S]*\\n## Out of scope[ \\t]*\\r?\\n\\s*-\\s+\\S[\\s\\S]*\\n## Ticket[ \\t]*\\r?\\n\\s*https://shop\\.example\\.com/browse/ABC-1\\s*$"
---
