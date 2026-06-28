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

# ── Discovery index artifact (loadout-library-v2) ──
# One artifact at <REGISTRY>/<OWNER>/<REPO>/index:latest, type
# application/vnd.claude-fleet.loadout-index.v1, a single index.json layer the
# app pulls to enumerate this repo's loadouts.
INDEX_ARTIFACT_TYPE="application/vnd.claude-fleet.loadout-index.v1"
REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-imioimi}"
REPO="${REPO:-claude-fleet-loadouts}"
index_ref="$REGISTRY/$OWNER/$REPO/index:latest"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"$here/build-index.sh" "$tmp/index.json"
echo "==> index ($(jq 'length' "$tmp/index.json") loadout(s))  ->  $index_ref"

if [ "$extra" = "--dry-run" ]; then
  echo "    (dry run — not pushing index)"
  cat "$tmp/index.json"
else
  ( cd "$tmp" && oras push "$index_ref" --artifact-type "$INDEX_ARTIFACT_TYPE" index.json )
  echo "==> pushed $index_ref"
fi
