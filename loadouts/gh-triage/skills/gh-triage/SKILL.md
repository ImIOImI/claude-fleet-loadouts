---
name: gh-triage
description: Triage the user's GitHub notification inbox — marks merged/closed threads and out-of-scope review-request spam as done, then lists what actually needs them, ranked. Use when asked to triage/clean up/go through GitHub notifications or the GitHub inbox, or "what on GitHub needs me?"
---

# gh-triage

All paths below are relative to this skill's base directory. Requires `gh` (authenticated, `notifications` + `repo` scopes) and `python3`.

## First run: build the home-repo list

If `home-repos.txt` doesn't exist, `triage.py` exits and says so. Build it:

1. Ask the user which org, which repos they always want treated as theirs, and which teams count as "my team".
2. Run `python3 seed_home_repos.py --org <org> --named <repo,repo> --teams <slug,slug> > /tmp/home-repos.draft` (a few minutes on large orgs; audit log needs org-owner access, otherwise first-commit author is used).
3. Show the user the "created by" additions grouped by creator; save only what they approve to `home-repos.txt`.

## Run

`python3 triage.py` (add `--dry-run` only if the user asks for a preview; `--limit N` caps items per bucket, default 25; `--org <org>`, repeatable, triages only that org's threads and leaves the rest untouched; `--repos <path>` reads the home-repo list from elsewhere, e.g. a path outside the installed skill so reinstalls can't touch it). It acts first, no confirmation — new activity resurfaces a thread. ~1 min per ~2k threads.

Rules (first match wins, all in `triage.py`):
1. PR/issue merged or closed → done.
2. Review request in a repo not in `home-repos.txt`, user not @-mentioned and not a personally requested reviewer → done.
3. Everything else kept, ranked: mentions → personal review requests → their PRs → team review requests in home repos → other.

Presenting results: lead with cleared total + remaining total, then the top buckets verbatim (full URLs + gloss). Don't re-summarize "Everything else" beyond its count unless asked. Report any "failed to mark done" / "could not be looked up" lines.

## Keeping the list current

`home-repos.txt` is hand-maintained (one `owner/repo  # reason` per line). Propose an addition when the user starts authoring PRs in a repo not on it or their team creates one; propose removal for repos they haven't written in for ~6 months. Edit after they agree.

Tests: `python3 -m unittest discover -s tests`
