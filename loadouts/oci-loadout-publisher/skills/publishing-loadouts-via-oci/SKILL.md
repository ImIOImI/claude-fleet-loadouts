---
description: Set up or maintain an OCI registry repository that publishes claude-fleet loadouts as OCI artifacts (one per loadout) to GHCR via ORAS. Use when asked to publish loadouts over OCI, build a loadout distribution repo, add a loadout to the registry, or debug the publish pipeline.
---

# Publishing claude-fleet loadouts as OCI artifacts

A claude-fleet **loadout** is a folder (`loadout.md` + convention files like
`CLAUDE.md`, `skills/`, `commands/`, `agents/`, `rules/`, `output-styles/`).
This skill packages each loadout folder as its own **OCI artifact** and pushes
it to a registry (GitHub Container Registry) with [ORAS](https://oras.land), so
a claude-fleet install can `oras pull` loadouts instead of relying on the app's
hardcoded built-in starters.

Scope is **publish-only**: source folders → OCI artifacts on GHCR. The app-side
consume path (pull + install into `<userData>/loadouts/<id>/`) is separate.

## Prerequisites

- `oras` (https://oras.land) and `yq` (mikefarah v4 — the Go one, reads YAML).
- Registry auth: `oras login ghcr.io -u <user>` with a token that has
  `write:packages`. In CI use the workflow `GITHUB_TOKEN` (no extra secret).
- If you push the GitHub Actions workflow file via `gh`/git, the token needs the
  `workflow` OAuth scope (`gh auth refresh -s workflow --hostname github.com`),
  and `gh auth setup-git` so plain `git push` can authenticate over HTTPS.

## Registry layout

One OCI repository **per loadout id**, tagged `latest` plus the semver `version`
from the loadout's frontmatter:

```
ghcr.io/<owner>/claude-fleet-loadouts/<loadout-id>:<version>
ghcr.io/<owner>/claude-fleet-loadouts/<loadout-id>:latest
```

## Artifact format (the contract)

- **artifactType:** `application/vnd.claude-fleet.loadout.v1`
- **Layers:** one per file in the loadout folder. Each layer's
  `org.opencontainers.image.title` annotation is the file's **loadout-relative
  path** (`loadout.md`, `CLAUDE.md`, `skills/<name>/SKILL.md`, …). This is how
  `oras pull` reconstructs the tree verbatim — no tar/untar.
- **Manifest annotations** (so a consumer reads metadata via
  `oras manifest fetch` without pulling blobs):

  | annotation | source |
  |---|---|
  | `com.claude-fleet.loadout.id` | folder name |
  | `com.claude-fleet.loadout.title` | frontmatter `title` |
  | `com.claude-fleet.loadout.tags` | comma-joined frontmatter `tags` |
  | `org.opencontainers.image.version` | frontmatter `version` |
  | `org.opencontainers.image.description` | frontmatter `description` |
  | `org.opencontainers.image.source` | the source repo URL |

### ⚠ The one non-obvious gotcha

Do **NOT** put `org.opencontainers.image.title` on the **manifest**. `oras pull`
treats a manifest with that annotation as a named file and writes the *manifest
JSON itself* into the output dir as a stray file — polluting the pulled loadout
tree. Keep the human title in `com.claude-fleet.loadout.title` instead. (Layer
descriptors DO use `org.opencontainers.image.title` — that's correct and
required there; it's the per-file path.)

## Publishing one loadout

Parse the frontmatter (the block between the first two `---` lines), build
annotations, then `oras push` from **inside** the loadout dir so layer titles
are loadout-relative:

```bash
dir=loadouts/spec-driven
md="$dir/loadout.md"
fm="$(awk 'NR==1 && /^---[[:space:]]*$/{f=1;next} f && /^---[[:space:]]*$/{exit} f{print}' "$md")"
meta() { printf '%s\n' "$fm" | yq "$1"; }
title="$(meta '.title // ""')"; description="$(meta '.description // ""')"
version="$(meta '.version // ""')"; tags_csv="$(meta '[.tags // []]|flatten|join(",")')"
id="$(basename "$dir")"

base="ghcr.io/<owner>/claude-fleet-loadouts/$id"
[ -n "$version" ] && ref="$base:$version,latest" || ref="$base:latest"   # oras takes comma-separated tags

mapfile -t files < <(cd "$dir" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)

( cd "$dir" && oras push "$ref" \
    --artifact-type application/vnd.claude-fleet.loadout.v1 \
    --annotation "com.claude-fleet.loadout.title=$title" \
    --annotation "org.opencontainers.image.description=$description" \
    --annotation "org.opencontainers.image.source=https://github.com/<owner>/claude-fleet-loadouts" \
    --annotation "com.claude-fleet.loadout.id=$id" \
    --annotation "org.opencontainers.image.version=$version" \
    --annotation "com.claude-fleet.loadout.tags=$tags_csv" \
    "${files[@]}" )
```

`title` and `description` are required; fail loudly if missing. `version`/`tags`
are optional — when `version` is absent, push only `latest`.

Factor this into `scripts/publish-loadout.sh <dir> [--dry-run]` (env-overridable
`REGISTRY`/`OWNER`/`REPO`) and a `scripts/publish-all.sh` that loops every
`loadouts/*/loadout.md`. A `--dry-run` that validates + prints the plan without
pushing is invaluable in CI and locally.

## CI workflow

`.github/workflows/publish-loadouts.yml`, triggered on push to `main` (paths
`loadouts/**`, `scripts/**`, the workflow itself) + `workflow_dispatch`:

```yaml
permissions: { contents: read, packages: write }
steps:
  - uses: actions/checkout@v4
  - id: owner
    run: echo "value=${GITHUB_REPOSITORY_OWNER,,}" >> "$GITHUB_OUTPUT"   # lowercase
  - uses: oras-project/setup-oras@v1
  - uses: docker/login-action@v3
    with: { registry: ghcr.io, username: ${{ github.actor }}, password: ${{ secrets.GITHUB_TOKEN }} }
  - run: ./scripts/publish-all.sh --dry-run        # validate
    env: { REGISTRY: ghcr.io, OWNER: "${{ steps.owner.outputs.value }}" }
  - run: ./scripts/publish-all.sh                  # publish
    env: { REGISTRY: ghcr.io, OWNER: "${{ steps.owner.outputs.value }}" }
```

GHCR repo names must be lowercase — lowercase the owner. mikefarah `yq` is
preinstalled on `ubuntu-latest`.

## Verify before trusting it

1. **Local round-trip, no registry** — push to an OCI **layout** dir and diff:
   ```bash
   oras push --oci-layout /tmp/oci:1.0.0 --artifact-type application/vnd.claude-fleet.loadout.v1 \
     --annotation com.claude-fleet.loadout.title=... "${files[@]}"   # run from inside the loadout dir
   oras pull --oci-layout /tmp/oci:1.0.0 -o /tmp/out
   diff -r <loadout-dir> /tmp/out          # MUST be identical (no stray manifest file — see gotcha)
   ```
   This exercises the exact push/pull code path with no daemon/registry and is
   what catches the manifest-title bug.
2. **Real registry** after CI runs: `oras repo tags <ref-base>`,
   `oras manifest fetch <ref>:latest | yq -p=json .annotations`, then
   `oras pull <ref>:latest -o /tmp/p && diff -r <loadout-dir> /tmp/p`.

## Consuming (reference — not built by this skill)

```bash
oras manifest fetch <ref>:latest | jq .annotations      # metadata, no blobs
oras pull <ref>:latest -o <userData>/loadouts/<id>      # the installable tree
```

## Adding a loadout

Drop a `loadouts/<id>/` folder with a valid `loadout.md` (frontmatter `title` +
`description` required; `version` + `tags` recommended), push to `main`. Bump
`version` to cut a new tag. Keep secrets out — loadouts are reusable.
