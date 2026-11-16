---
plugins: ["../.."]
allowed_tools: [Read, Glob, Grep, Agent, Write]
max_turns: 20
timeout_seconds: 600
---

Run intake on the factory job in `.factory/jobs/ABC-1/`: dispatch the kc-factory intake agent with that job dir, then tell me its decision.
