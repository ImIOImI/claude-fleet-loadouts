#!/usr/bin/env python3
"""Mark noisy GitHub notifications done and rank what's left. See SKILL.md."""
import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HOME_REPOS = Path(__file__).with_name("home-repos.txt")
SUBJECT_RE = re.compile(r"/repos/([^/]+)/([^/]+)/(pulls|issues)/(\d+)$")
RULE_CLOSED = "merged/closed"
RULE_NOISE = "review request outside home repos"
BUCKETS = ["Mentions", "Personal review requests", "Your PRs",
           "Team review requests (home repos)", "Everything else"]


def load_home_repos(path):
    if not Path(path).exists():
        sys.exit(f"{path} not found — build it first with seed_home_repos.py (see SKILL.md)")
    repos = set()
    for line in Path(path).read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            repos.add(line.lower())
    return repos


def parse_subject(n):
    m = SUBJECT_RE.search((n.get("subject") or {}).get("url") or "")
    if not m:
        return None
    owner, repo, kind, num = m.groups()
    return owner, repo, "pr" if kind == "pulls" else "issue", int(num)


def classify(n, state, home, mentioned, login):
    if state and state["state"] in ("CLOSED", "MERGED"):
        return "done", RULE_CLOSED
    mentioned_here = n["reason"] in ("mention", "team_mention") or bool(state and state["url"] in mentioned)
    personal = bool(state and login.lower() in state["reviewers"])
    in_home = n["repository"]["full_name"].lower() in home
    if n["reason"] == "review_requested" and state and not (in_home or mentioned_here or personal):
        return "done", RULE_NOISE
    if mentioned_here:
        return "keep", 0
    if personal:
        return "keep", 1
    if n["reason"] == "author":
        return "keep", 2
    if n["reason"] == "review_requested" and in_home:
        return "keep", 3
    return "keep", 4


PR_FIELDS = "state url reviewRequests(first: 50) { nodes { requestedReviewer { ... on User { login } } } }"


def build_query(subjects):
    parts = []
    for i, (owner, repo, kind, num) in enumerate(subjects):
        body = f"pullRequest(number: {num}) {{ {PR_FIELDS} }}" if kind == "pr" else f"issue(number: {num}) {{ state url }}"
        parts.append(f"s{i}: repository(owner: {json.dumps(owner)}, name: {json.dumps(repo)}) {{ {body} }}")
    return "query {\n" + "\n".join(parts) + "\n}"


def parse_states(data, subjects):
    out = {}
    for i, subj in enumerate(subjects):
        node = data.get(f"s{i}") or {}
        item = node.get("pullRequest") or node.get("issue")
        if not item:
            continue
        nodes = (item.get("reviewRequests") or {}).get("nodes") or []
        reviewers = {(r.get("requestedReviewer") or {}).get("login", "").lower() for r in nodes} - {""}
        out[subj] = {"state": item["state"], "url": item["url"], "reviewers": reviewers}
    return out


def html_url(n, state):
    return state["url"] if state else n["repository"]["html_url"]


def render(cleared, kept, limit):
    lines = [f"## Cleared {len(cleared)}"]
    lines += [f"- {rule}: {c}" for rule, c in Counter(r for _, r in cleared).most_common()]
    by_repo = Counter(n["repository"]["full_name"] for n, _ in cleared)
    if by_repo:
        lines.append("\nBy repo: " + ", ".join(f"{r} {c}" for r, c in by_repo.most_common()))
    lines.append(f"\n## Remaining {len(kept)}")
    for b, name in enumerate(BUCKETS):
        items = [(n, url) for n, bucket, url in kept if bucket == b]
        if not items:
            continue
        lines.append(f"\n### {name} ({len(items)})")
        lines += [f"- {url} — {n['subject']['title']} ({n['reason']})" for n, url in items[:limit]]
        if len(items) > limit:
            lines.append(f"- …and {len(items) - limit} more")
    return "\n".join(lines)


def in_orgs(n, orgs):
    """True when no org filter is set, or the thread's repo belongs to one of `orgs` (lowercased)."""
    if not orgs:
        return True
    owner = ((n.get("repository") or {}).get("full_name") or "").split("/", 1)[0].lower()
    return owner in orgs


def gh(*args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"gh {' '.join(args[:2])} failed: {r.stderr.strip()}")
    return r.stdout


def fetch_notifications():
    return [json.loads(l) for l in gh("api", "notifications", "--paginate", "--jq", ".[]").splitlines()]


def fetch_states(subjects, batch=100):
    states = {}
    for i in range(0, len(subjects), batch):
        chunk = subjects[i:i + batch]
        # GraphQL returns partial data + exit 1 when some subjects are gone; keep what resolved.
        r = subprocess.run(["gh", "api", "graphql", "-f", f"query={build_query(chunk)}"], capture_output=True, text=True)
        try:
            states.update(parse_states(json.loads(r.stdout).get("data") or {}, chunk))
        except json.JSONDecodeError:
            continue
    return states


def fetch_mentions():
    out = gh("search", "prs", "--mentions", "@me", "--state", "open", "--limit", "1000", "--json", "url", "--jq", ".[].url")
    return set(out.split())


def mark_done(ids):
    def done(i):
        return subprocess.run(["gh", "api", "-X", "DELETE", f"notifications/threads/{i}"], capture_output=True).returncode
    with ThreadPoolExecutor(8) as pool:
        return sum(1 for rc in pool.map(done, ids) if rc)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dry-run", action="store_true", help="report only; mark nothing done")
    p.add_argument("--limit", type=int, default=25, help="max items listed per bucket")
    p.add_argument("--repos", default=HOME_REPOS, help="home repo list")
    p.add_argument("--org", action="append", default=[],
                   help="only triage threads from this org (repeatable); others are left untouched")
    a = p.parse_args(argv)
    orgs = {o.lower() for o in a.org}

    login = gh("api", "user", "--jq", ".login").strip()
    home = load_home_repos(a.repos)
    every = fetch_notifications()
    notes = [n for n in every if in_orgs(n, orgs)]
    subjects = sorted({s for s in map(parse_subject, notes) if s})
    states = fetch_states(subjects)
    mentioned = fetch_mentions()

    cleared, kept = [], []
    for n in notes:
        subj = parse_subject(n)
        state = states.get(subj) if subj else None
        verdict, detail = classify(n, state, home, mentioned, login)
        if verdict == "done":
            cleared.append((n, detail))
        else:
            kept.append((n, detail, html_url(n, state)))

    failed = 0 if a.dry_run else mark_done([n["id"] for n, _ in cleared])
    print(("DRY RUN — nothing marked done\n\n" if a.dry_run else "") + render(cleared, kept, a.limit))
    if failed:
        print(f"\n{failed} threads failed to mark done (left in inbox)")
    if len(every) > len(notes):
        print(f"\n{len(every) - len(notes)} threads outside {', '.join(sorted(orgs))} left untouched")
    missing = sum(1 for s in subjects if s not in states)
    if missing:
        print(f"\n{missing} subjects could not be looked up (kept)")


if __name__ == "__main__":
    main()
