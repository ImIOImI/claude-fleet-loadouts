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
    - { cmd: flock }
scripts:
  - label: write the example config
    file: install/write-example.sh
    unless: test -f /shared/.git-sync.d/example.json.sample
---

# Git Sync

Adds a **`git-sync` automation** (every 5 minutes, plus Run now) that clones and syncs the
folders listed in `/shared/.git-sync.d/*.json`, using the git credentials of the workspace it's
installed in (`GH_TOKEN`, `gh auth`, or SSH). **Install it once per node.** A lock stops two
installs from syncing at once, but each still runs with its own workspace's env, so a second
install with a different `FLEET_NODE_ID` or credentials makes results flip between runs.

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
- `branch` (default `main`): a non-empty string.
- `mode`:
  - `mirror` (the default) pulls fast-forward only and never discards local edits.
  - `auto-sync` commits, rebases and pushes.
- `author_scoped` (auto-sync; `true` or `false`, default `true`): commit only `<node id>/…`. Edits
  elsewhere raise a todo and stay local.

An invalid file fails the run (exit 2) with the file and folder named, and nothing is touched.
After the first clone, changing a folder's `remote` or `branch` doesn't re-point it: the run raises
`…:remote-changed` and skips it. To re-clone, move the folder aside (`mv /shared/x /shared/x.old`).
Removing a folder from the config stops syncing it; the clone stays on disk.

## Node id

Auto-sync commits as **`FLEET_NODE_ID`**: `<name>@<team>` for people, `agent-<name>@<team>` for
agents. **It must be unique per node**: one person on two machines uses two ids (e.g.
`troy-laptop@platform` and `troy-desktop@platform`). Each node writes only its own folder, so two
nodes sharing an id fight over it in rebase conflicts. Set it as an env var on the workspace that
runs the automation. Without it, auto-sync folders are skipped with a todo; mirrors still sync.

## Long writers: `.sync-hold`

A tool that writes for minutes creates `<folder>/<node id>/.sync-hold` (or `<folder>/.sync-hold`
when unscoped) and deletes it when done. git-sync skips that folder meanwhile, so nobody sees a
half-written result. Holds older than 2 h are ignored, with a todo. Add `.sync-hold` to the
repo's `.gitignore`.

## What you'll see

Each todo is posted once, and again only if its details change; it isn't re-posted every run.

| Situation | Result |
|---|---|
| Rebase conflict | todo `git-sync:<name>:conflict`; local commits kept, not pushed |
| Conflict reapplying your uncommitted edits (autostash) | todo `…:conflict`; the edits are in `git stash list` |
| Edits in a mirror, or outside your folder | todo `…:local-edits` / `…:outside-edits` |
| A file over 50 MB in your folder | todo `…:large-file`; it stays local and uncommitted |
| Non-git directory in the way | todo `…:not-a-repo`; never overwritten |
| Clone's origin or branch differs from the config | todo `…:remote-changed`; skipped |
| Unexpected keys in the clone's `.git/config` | todo `…:unsafe-config`; skipped (see below) |
| Clone is on a detached HEAD | todo `…:detached`; skipped until you check out the branch |
| A local commit outside your `<node id>/` folder (scoped auto-sync) | todo `…:outside-commits`; the whole push is held, not just that commit |
| Stale hold | todo `…:stale-hold` |
| Any failure (network, auth, timeout, no upstream, push rejected…) | quiet; notify `…:failing` on the 3rd in a row, then daily |

Network calls time out after 60 s, except a first clone, which gets up to the full run budget and
is deferred to the next run (named in stdout) if less than 90 s of that budget remains. A run stops
starting folders after about 200 s and picks up the rest next time.

With `author_scoped: false`, auto-sync pushes **any** local commit in the folder, including one
made by another node or tool sharing the same `/shared` mount — there's no outside-commits guard.
Use unscoped folders only where every writer is trusted.

## Security

Clones live under `/shared`, which every workspace on the node can write. git-sync never runs a
clone's hooks or fsmonitor, and skips any clone whose `.git/config` sets keys beyond the ones
`git clone` and git-sync set (`core.*` basics, `remote.origin.url`/`fetch`, the branch's
`remote`/`merge`), including `include.*`. The todo names the keys, never their values. Don't keep
secrets in synced repos: every workspace on the node, and everyone with access to the remote, can
read them.

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
