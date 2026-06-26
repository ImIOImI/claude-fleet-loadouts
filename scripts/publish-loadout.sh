#!/usr/bin/env bash
# Package a single loadout folder as an OCI artifact and push it to a registry
# with ORAS. Each file in the loadout becomes its own layer, with the file's
# loadout-relative path preserved in its title annotation — so a consumer can
#   oras pull <ref> -o <userData>/loadouts/<id>
# and get the tree back verbatim (no tar/untar). Loadout metadata (title,
# description, tags, version) parsed from loadout.md's frontmatter is mirrored
# into manifest annotations, so a consumer can read it via `oras manifest fetch`
# without pulling any blobs.
#
# Usage:
#   scripts/publish-loadout.sh <loadout-dir> [--dry-run]
#
# Env (with defaults):
#   REGISTRY   container registry host           (default: ghcr.io)
#   OWNER      registry namespace / org          (default: imioimi)
#   REPO       repository segment for loadouts    (default: claude-fleet-loadouts)
#
# Requires: oras, yq (mikefarah). Auth: `oras login` / `docker login` beforehand.
set -euo pipefail

ARTIFACT_TYPE="application/vnd.claude-fleet.loadout.v1"
REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${OWNER:-imioimi}"
REPO="${REPO:-claude-fleet-loadouts}"

dir="${1:?usage: publish-loadout.sh <loadout-dir> [--dry-run]}"
dry_run=false
[ "${2:-}" = "--dry-run" ] && dry_run=true

dir="${dir%/}"
md="$dir/loadout.md"
[ -f "$md" ] || { echo "error: $md not found (not a loadout folder)" >&2; exit 1; }

id="$(basename "$dir")"

# ── Parse the YAML frontmatter (the block between the first two '---' lines) ──
fm="$(awk 'NR==1 && /^---[[:space:]]*$/{f=1; next} f && /^---[[:space:]]*$/{exit} f{print}' "$md")"
[ -n "$fm" ] || { echo "error: $md has no YAML frontmatter" >&2; exit 1; }

meta() { printf '%s\n' "$fm" | yq "$1"; }
title="$(meta '.title // ""')"
description="$(meta '.description // ""')"
version="$(meta '.version // ""')"
tags_csv="$(meta '[.tags // []] | flatten | join(",")')"

[ -n "$title" ] || { echo "error: $md frontmatter missing required 'title'" >&2; exit 1; }
[ -n "$description" ] || { echo "error: $md frontmatter missing required 'description'" >&2; exit 1; }

# ── Reference + tags: always 'latest', plus the semver 'version' if present ──
base="$REGISTRY/$OWNER/$REPO/$id"
if [ -n "$version" ]; then ref="$base:$version,latest"; else ref="$base:latest"; fi

# ── Manifest annotations (discovery without pulling blobs) ──
# NOTE: deliberately NOT setting `org.opencontainers.image.title` on the
# manifest — oras pull writes the manifest itself out as a file named by that
# annotation, which would pollute the pulled loadout tree. The human title
# lives in the namespaced `com.claude-fleet.loadout.title` instead. (Layer
# descriptors DO use org.opencontainers.image.title — that's the per-file path
# oras uses to reconstruct the tree, and it's correct there.)
ann=(
  --annotation "com.claude-fleet.loadout.title=$title"
  --annotation "org.opencontainers.image.description=$description"
  --annotation "org.opencontainers.image.source=https://github.com/$OWNER/$REPO"
  --annotation "com.claude-fleet.loadout.id=$id"
)
[ -n "$version" ]  && ann+=( --annotation "org.opencontainers.image.version=$version" )
[ -n "$tags_csv" ] && ann+=( --annotation "com.claude-fleet.loadout.tags=$tags_csv" )

# ── Collect the loadout's files as loadout-relative paths (sorted, stable) ──
mapfile -t files < <(cd "$dir" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
[ "${#files[@]}" -gt 0 ] || { echo "error: $dir has no files" >&2; exit 1; }

echo "==> $id  ->  $ref"
echo "    title:   $title"
echo "    version: ${version:-<none>}"
echo "    tags:    ${tags_csv:-<none>}"
echo "    files:   ${files[*]}"

if $dry_run; then
  echo "    (dry run — not pushing)"
  exit 0
fi

# Push from inside the loadout dir so layer title annotations are the
# loadout-relative paths (loadout.md, CLAUDE.md, skills/.../SKILL.md, …).
( cd "$dir" && oras push "$ref" --artifact-type "$ARTIFACT_TYPE" "${ann[@]}" "${files[@]}" )
echo "==> pushed $ref"
