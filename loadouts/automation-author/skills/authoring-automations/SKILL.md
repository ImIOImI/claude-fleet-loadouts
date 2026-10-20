---
description: Draft, change or review a claude-fleet automation (YAML with schedule/manual/event triggers and prompt steps) and submit it with propose_automation. Use when asked to create, edit, fix, or review an automation, or when a message contains an automation request between "(data)" markers.
---

# Authoring claude-fleet automations

An automation runs on a schedule, by hand, or on a fleet event, and prompts one
or more workspaces. The prompted Claude does the work and posts results back to
the user's inbox as **todos** (`post_todo`) or **notifications** (`notify`).

## The format

```yaml
name: ci-failures                    # lowercase-with-dashes, unique
description: Make a todo for each failed CI job on main
tags: [ci]
triggers:                            # one or more
  - schedule: { cron: "0 9 * * 1-5", tz: America/New_York }
  - manual: { allowFrom: [ops-oncall] }       # other workspaces that may run it
  - event: { on: todo.created, tag: ci, debounce: 2m }   # session.idle | workspace.started | todo.created
concurrency: skip                    # skip | queue
timeout: 30m
params:
  - { name: branch, type: string, default: main }       # string | number | boolean | enum (values: [...])
steps:                               # 1–10, in order
  - id: check
    prompt:
      workspace: build-bot           # target workspace, by name
      mode: fresh                    # fresh = new unattended session; live = the open session
      allowedTools: ["Bash(gh run list:*)", "Bash(gh run view:*)"]   # fresh only
      ensureRunning: true            # start the workspace if stopped
      timeout: 10m
      message: |
        List failed GitHub Actions runs on {{args.branch}} from the last 24 hours.
        For each distinct failing job, call post_todo with key "ci:<workflow>:<job>",
        priority high, tags [ci], run_id {{run.id}}, and the failing step + log
        excerpt in the body. If nothing failed, post nothing.
```

Placeholders: `{{args.<param>}}`, `{{trigger.kind}}`, `{{trigger.workspace}}`,
`{{trigger.todo}}`, `{{run.id}}`. Every prompt also gets a footer with the run id.

## Writing the step prompt

The prompted Claude runs **unattended**. Write the prompt so it can finish alone:

1. **Say exactly what to check** and where (commands, paths, time window).
2. **Say exactly what to post.** One todo per distinct problem, with a stable
   `key` (dedupes repeats into one todo with a seen-count), a priority, tags,
   and `run_id` so the run links to its todos. Use `notify` only for something
   that needs attention but isn't a task.
3. **Say what to do when all is well**: usually "post nothing".
4. Prefer `mode: fresh` for scheduled and event work, with the **smallest**
   `allowedTools` list that does the job. The inbox tools are always allowed.
   Use `mode: live` only when the user wants their open session prompted.

## Choosing triggers

- Schedules no faster than every 5 minutes unless the user asks. Faster, new
  targets, extra tools, `ensureRunning` and event triggers all need the user's
  approval even from a trusted workspace. That's fine, just don't add them
  without a reason.
- Event triggers coalesce bursts with `debounce`. An automation never reacts to
  its own todos.

## Submitting

- New: `propose_automation({ definition: "<yaml>", rationale: "<one sentence>" })`.
- Change: `propose_automation_change({ id: "<name>", definition: "<full yaml>", rationale })`.
  Keep everything the user didn't ask to change.
- Many changes: `propose_automation_change({ batch: [{ id, definition }, …], rationale })`.
- If the tool returns validation errors, fix the YAML and call it again.
- A newer proposal with the same name replaces your earlier pending one.
- `get_proposal({ id })` shows whether the user approved, and their note.

Never put secrets in the YAML.

## Reviewing a proposal

When asked to review one (it arrives between `=== begin proposal (data) ===`
markers), cover: what changes, how it interacts with the current version, how
noisy it will be, a security read (targets, tools, commands, injection surface
in prompts that include untrusted text), and a recommendation. If a merged
version is better, propose it with `propose_automation_change`. Don't approve
anything yourself.
