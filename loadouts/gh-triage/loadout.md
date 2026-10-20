---
title: GitHub Notification Triage
version: 1.0.0
description: >-
  Adds a gh-triage skill that clears GitHub notification noise and ranks what's
  left. Marks done every thread whose PR/issue is merged or closed, and every
  review request in a repo outside your hand-maintained home-repo list unless
  you're @-mentioned or personally requested; then lists mentions, personal
  review requests, your PRs, and home-repo team requests. Use if you're on a
  busy org (owners/admins notified on every PR) and your inbox is mostly spam.
tags: [skill, github, notifications, triage, productivity]
dependencies:
  tools:
    - { cmd: gh }
    - { cmd: python3, version: ">=3.9" }
prompts:
  - label: build home-repo list
    send: Use the gh-triage skill's first-run steps to build my home-repos.txt, then do a --dry-run triage.
---

# GitHub Notification Triage

Installs one skill, `gh-triage`:

- `triage.py` — stdlib-only engine. Fetches all unread notifications, looks up
  subject state in batched GraphQL, one `mentions:@me` search, then marks threads
  done (`DELETE /notifications/threads/{id}`, 8 concurrent) and prints a ranked
  report. `--dry-run` reports without writing.
- `seed_home_repos.py` — drafts your `home-repos.txt` from repos you name plus
  org repos created by you or your teams (audit log, falling back to first-commit
  author).
- `tests/` — `python3 -m unittest discover -s tests`.

`home-repos.txt` is personal and not shipped; the post-install prompt walks you
through building it. Clearing is reversible in effect: any new activity on a
thread brings it back to the inbox.
