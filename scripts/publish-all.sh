#!/usr/bin/env bash
# Publish every loadout under loadouts/ via publish-loadout.sh. Pass --dry-run
# to validate + preview each without pushing. Env (REGISTRY/OWNER/REPO) flows
# through to publish-loadout.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
extra="${1:-}"

shopt -s nullglob
count=0
for md in "$root"/loadouts/*/loadout.md; do
  "$here/publish-loadout.sh" "$(dirname "$md")" $extra
  count=$((count + 1))
done

[ "$count" -gt 0 ] || { echo "no loadouts found under $root/loadouts/*/loadout.md" >&2; exit 1; }
echo "==> done ($count loadout(s))"
