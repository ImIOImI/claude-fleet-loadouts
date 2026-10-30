---
title: Git Sync
version: 1.0.0
description: >-
  Keeps folders under /shared in sync with git remotes on a 5-minute automation, so several
  claude-fleet nodes share files and keep working offline. Install once per node (normally in
  the automations workspace), then add folders with an organisation config loadout or a JSON
  file in /shared/.git-sync.d/. Auto-sync folders need FLEET_NODE_ID set on that workspace.
tags: [automation, git, sync, shared]
dependencies:
  tools:
    - { cmd: git }
    - { cmd: jq }
scripts:
  - label: write the example config
    file: install/write-example.sh
    unless: test -f /shared/.git-sync.d/example.json.sample
---

# Git Sync

Adds a **`git-sync` automation** (every 5 minutes, plus Run now) that clones and syncs the
folders listed in `/shared/.git-sync.d/*.json`, using the git credentials of the workspace it's
installed in (`GH_TOKEN`, `gh auth`, or SSH). **Install it once per node.** A second install is
harmless (a lock makes it a no-op) but pointless.

## Config

Every `*.json` file in `/shared/.git-sync.d/` is loaded. `*.sample` files are ignored (the install
drops `example.json.sample`). No secrets here.

```json
{
  "folders": [
    { "name": "reviews", "remote": "https://git.example.com/acme/reviews.git",
      "branch": "main", "mode": "auto-sync", "author_scoped": true },
    { "name": "knowledge", "remote": "https://git.example.com/acme/knowledge.git", "mode": "mirror" }
  ]
}
```

- `name`: the folder under `/shared` (`[a-z0-9][a-z0-9._-]*`).
- `mode`:
  - `mirror` (the default) pulls fast-forward only and never discards local edits.
  - `auto-sync` commits, rebases and pushes.
- `author_scoped` (auto-sync, default `true`): commit only `<node id>/…`. Edits elsewhere raise
  a todo and stay local.

## Node id

Auto-sync commits as **`FLEET_NODE_ID`**: `<name>@<team>` for people, `agent-<name>@<team>` for
agents. Set it as an env var on the workspace that runs the automation. Without it, auto-sync
folders are skipped with a todo; mirrors still sync.

## Long writers: `.sync-hold`

A tool that writes for minutes creates `<folder>/<node id>/.sync-hold` (or `<folder>/.sync-hold`
when unscoped) and deletes it when done. git-sync skips that folder meanwhile, so nobody sees a
half-written result. Holds older than 2 h are ignored, with a todo. Add `.sync-hold` to the
repo's `.gitignore`.

## What you'll see

| Situation | Result |
|---|---|
| Rebase conflict | todo `git-sync:<name>:conflict`; local commits kept |
| Edits in a mirror, or outside your folder | todo `…:local-edits` / `…:outside-edits` |
| Non-git directory in the way | todo `…:not-a-repo`; never overwritten |
| Network or auth failure | quiet; notify `…:failing` on the 3rd in a row |
| Stale hold | todo `…:stale-hold` |

## Organisation config loadouts

Ship your folder list as a separate loadout that depends on this one. Install scripts run in
the container **without** the loadout's files, so embed the config in the script:

```yaml
# loadout.md frontmatter
title: Git Sync (Acme)
version: 1.0.0
description: Acme's shared repos for git-sync. Install once per node.
dependencies:
  loadouts:
    - { id: git-sync, version: "^1.0.0" }
scripts:
  - label: write Acme git-sync config
    file: install/write-config.sh
```

```sh
# install/write-config.sh: rewrites the managed file on every install, so new versions apply.
set -e
mkdir -p /shared/.git-sync.d
cat >/shared/.git-sync.d/acme.json.tmp <<'EOF'
{ "folders": [ { "name": "reviews", "remote": "https://git.example.com/acme/reviews.git", "mode": "auto-sync" } ] }
EOF
mv /shared/.git-sync.d/acme.json.tmp /shared/.git-sync.d/acme.json
```
