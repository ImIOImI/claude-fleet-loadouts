#!/usr/bin/env bash
# Build the loadout discovery index (index.json) for the loadout-library-v2
# index artifact. Reads every loadouts/*/loadout.md frontmatter — id (= folder
# name), title, description, version, tags — and emits a JSON array
# [{id,title,description,tags,version}] sorted by id, to OUTFILE ($1) or stdout.
#
# `version` is REQUIRED non-empty by the consumer's index parser; loadout.md's
# version is optional, so an absent version defaults to 0.0.0 here.
#
# Requires: yq (mikefarah), jq.  Usage: scripts/build-index.sh [OUTFILE]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
out="${1:-}"

shopt -s nullglob
entries=()
for md in "$root"/loadouts/*/loadout.md; do
  dir="$(dirname "$md")"
  id="$(basename "$dir")"

  # Same frontmatter extractor as publish-loadout.sh.
  fm="$(awk 'NR==1 && /^---[[:space:]]*$/{f=1; next} f && /^---[[:space:]]*$/{exit} f{print}' "$md")"
  [ -n "$fm" ] || { echo "error: $md has no YAML frontmatter" >&2; exit 1; }

  meta() { printf '%s\n' "$fm" | yq "$1"; }
  title="$(meta '.title // ""')"
  description="$(meta '.description // ""')"
  version="$(meta '.version // ""')"
  tags_json="$(printf '%s\n' "$fm" | yq -o=json '[.tags // []] | flatten')"

  [ -n "$title" ] || { echo "error: $md frontmatter missing required 'title'" >&2; exit 1; }
  [ -n "$description" ] || { echo "error: $md frontmatter missing required 'description'" >&2; exit 1; }
  # version is required non-empty downstream; default an absent one.
  [ -n "$version" ] || version="0.0.0"

  entries+=( "$(jq -n \
    --arg id "$id" --arg title "$title" --arg description "$description" \
    --arg version "$version" --argjson tags "$tags_json" \
    '{id:$id, title:$title, description:$description, tags:$tags, version:$version}')" )
done

[ "${#entries[@]}" -gt 0 ] || { echo "error: no loadouts found under $root/loadouts/*/loadout.md" >&2; exit 1; }

index="$(printf '%s\n' "${entries[@]}" | jq -s 'sort_by(.id)')"
if [ -n "$out" ]; then printf '%s\n' "$index" > "$out"; else printf '%s\n' "$index"; fi
