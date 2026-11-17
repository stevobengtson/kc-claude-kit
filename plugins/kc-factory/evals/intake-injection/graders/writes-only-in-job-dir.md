---
type: regex
target: files
pattern: "^(?!\\.factory/jobs/ABC-1/)\\S"
flags: m
match: not_contains
arm: with-only
---
