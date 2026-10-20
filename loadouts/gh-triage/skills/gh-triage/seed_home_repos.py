#!/usr/bin/env python3
"""Draft a home-repos.txt: repos you named, plus unarchived org repos created by you or your teams.

Creator comes from the org audit log (org owners only; ~180-day retention), falling
back to the first commit's author. Prints to stdout — review it before saving.
"""
import argparse
import json
import re
import subprocess


def gh(*args):
    return subprocess.run(["gh", *args], capture_output=True, text=True).stdout


def root_author(full):
    hdr = gh("api", "-i", f"repos/{full}/commits?per_page=1")
    m = re.search(r'[?&]page=(\d+)>; rel="last"', hdr)
    return gh("api", f"repos/{full}/commits?per_page=1&page={m.group(1) if m else 1}",
              "--jq", ".[0].author.login // empty").strip()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--org", required=True)
    p.add_argument("--teams", default="", help="comma-separated team slugs whose members count as 'my team'")
    p.add_argument("--named", default="", help="comma-separated repo names to always include")
    a = p.parse_args()

    me = gh("api", "user", "--jq", ".login").strip()
    members = {me} | {l for t in filter(None, a.teams.split(","))
                      for l in gh("api", f"orgs/{a.org}/teams/{t}/members", "--paginate", "--jq", ".[].login").split()}
    audit = {}
    for line in gh("api", f"orgs/{a.org}/audit-log", "-X", "GET", "-f", "phrase=action:repo.create", "--paginate",
                   "--jq", ".[] | [.actor, .repo] | @tsv").splitlines():
        actor, repo = line.split("\t")
        audit[repo.lower()] = actor

    named = [f"{a.org}/{r.strip()}" for r in a.named.split(",") if r.strip()]
    lines = [f"{r}  # named" for r in named]
    skip = {r.lower() for r in named}
    repos = [json.loads(l)["full_name"] for l in gh("api", f"orgs/{a.org}/repos", "--paginate",
                                                    "--jq", ".[] | select(.archived | not) | {full_name}").splitlines()]
    for full in sorted(repos, key=str.lower):
        if full.lower() in skip:
            continue
        creator, source = audit.get(full.lower()), "audit log"
        if creator is None:
            creator, source = root_author(full), "first commit"
        if creator in members:
            lines.append(f"{full}  # created by {creator} ({source})")
    print("# Repos you commonly write in. Review requests elsewhere are cleared unless you're named.\n"
          "# Hand-maintained; one owner/repo per line.\n" + "\n".join(lines))


if __name__ == "__main__":
    main()
