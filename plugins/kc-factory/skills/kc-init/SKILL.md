---
name: kc-init
description: Set up a repo for kc-factory. Sets up autopilot first when it is missing, writes and validates .claude/factory.json with you, and ignores .factory/. Run once per repo before /kc-factory:factory.
disable-model-invocation: true
---

# Set up the factory in this repo

The factory needs two committed config files, `.claude/autopilot.json` (how autopilot builds and checks the app) and `.claude/factory.json` (the tracker and routing), and `.factory/` ignored by git. This writes them with the user. Ask for what you cannot find out; never guess a site, key or status name. If a step fails and you cannot fix it, stop and report.

**Never write Atlassian credentials anywhere**: not in a config file, the shell, `.env` or settings. The factory reaches Jira only through the session's Atlassian connector, which holds its own sign-in.

Run from the repo root.

## Steps

1. **Autopilot first.** Find it: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/plugin-root.sh ${CLAUDE_PLUGIN_ROOT} kc-autopilot` prints `autopilot_root` (on exit 1, tell the user to install `kc-autopilot` and stop). If `.claude/autopilot.json` is missing, set autopilot up now by following `<autopilot_root>/skills/kc-init/SKILL.md` step by step, reading `${CLAUDE_PLUGIN_ROOT}` there as `<autopilot_root>`; it is the same setup `/kc-autopilot:kc-init` runs. If it exists, check it: `bash <autopilot_root>/scripts/read-config.sh .claude/autopilot.json > /dev/null`, and print its errors if any.
2. **The tracker connection.** Load the session's Jira tools with ToolSearch (search `jira issue`, `jira project`). If there are none, or a read fails as unauthorised, tell the user to connect an Atlassian connector (`/mcp` in the CLI, or the connector settings in the desktop app) and carry on without the lookups below.
3. **Ask.** Ask the user for:
   - `tracker.site`: the Jira site, a host name like `example.atlassian.net`. Offer the one the connector reports, if it lists its accessible sites.
   - `tracker.project_keys`: the project keys whose tickets the factory may take, like `ABC`.
   - `tracker.statuses.in_progress` and `in_review`: the status names a ticket moves to when work starts and when its PR is ready. Offer the project's real status names: read them through the connector (a project-statuses tool, or the transitions of a recent ticket in the project). The defaults are `In Progress` and `In Review`.
   - Optionally: `concurrency` (tickets built at once, 1 to 8, default 3), `tracker.comment_on` (which comments the factory posts: `needs-info`, `reject`, `accept`, `ready`, `blocked`; default all), `intake.model` (default `best`), and `routing` changes. The validator `${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh` defines every field and default.
4. **Write** `.claude/factory.json` with only the fields the user set; defaults fill the rest. If it already exists, do not overwrite it: show the user the changes you would make and write only after their yes. Then `bash ${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh .claude/factory.json > /dev/null` and fix every error it prints until it exits 0.
5. **Ignore job state.** Add `.factory/` to `.gitignore` if it is missing (create the file if needed; do not duplicate the line). `git check-ignore -q .factory/x` must then succeed.
6. **Commit.** `/kc-factory:factory` refuses to run until both configs and the ignore line are committed. Offer to commit; only on the user's yes run `git add .claude/factory.json .claude/autopilot.json .gitignore && git commit -m "chore: set up kc-factory" -- .claude/factory.json .claude/autopilot.json .gitignore`, so nothing else is swept in. Never push.
7. **Report**: what was written, what you could not determine, whether it was committed, and, when step 2 found no Jira tools, that `/kc-factory:factory` needs an Atlassian connector (`/mcp`) before its first run.
