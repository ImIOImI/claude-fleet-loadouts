---
description: Build a standalone OCI repository that distributes claude-fleet loadouts as OCI artifacts on GHCR — the source-tree layout, the artifact format, the ORAS publish scripts, the CI workflow, and the GitHub repo-creation steps. Use when asked to set up, scaffold, or stand up a loadout distribution repo over OCI (not just push to an existing one).
---

# Building an OCI repository for claude-fleet loadouts

A claude-fleet **loadout** is a folder (`loadout.md` + convention files like
`CLAUDE.md`, `skills/`, `commands/`, `agents/`, `rules/`, `output-styles/`).
This skill stands up a **standalone git repo** that distributes loadouts as OCI
artifacts — one OCI artifact per loadout — to GitHub Container Registry using
[ORAS](https://oras.land), so a claude-fleet install can pull loadouts instead
of relying on the app's hardcoded built-in starters.

Scope is **publish-only** (build the distribution repo; the app-side consume
path is separate) and the repo is **standalone** — not inside the app repo, so
loadout authoring/versioning doesn't churn the application's history.

## The deliverable

A repo that, on every push to `main`, publishes each loadout under `loadouts/`
to `ghcr.io/<owner>/<repo>/<loadout-id>:<version>` (and `:latest`). Build it in
this order.

## 1. Repo layout

```
loadouts/<id>/...            loadout source folders (the published content)
scripts/publish-loadout.sh   package + push ONE loadout via oras
scripts/publish-all.sh       loop publish-loadout.sh over every loadout
.github/workflows/publish-loadouts.yml   CI: publish on push to main
Makefile                     dry-run / publish convenience targets
README.md  .gitignore
```

Prereqs for working on it: `oras` (https://oras.land) and `yq` (mikefarah v4,
the Go YAML one).

## 2. The artifact format (the contract everything else implements)

- **artifactType:** `application/vnd.claude-fleet.loadout.v1`
- **Layers:** one per file in the loadout folder. Each layer's
  `org.opencontainers.image.title` annotation is the file's **loadout-relative
  path** (`loadout.md`, `CLAUDE.md`, `skills/<name>/SKILL.md`, …) — this is how
  `oras pull` reconstructs the tree verbatim, no tar/untar.
- **Registry layout:** one OCI repository per loadout id, tagged `latest` plus
  the semver `version` from frontmatter.
- **Manifest annotations** (so a consumer reads metadata via
  `oras manifest fetch` without pulling blobs): `com.claude-fleet.loadout.id`,
  `com.claude-fleet.loadout.title`, `com.claude-fleet.loadout.tags`,
  `org.opencontainers.image.version`, `org.opencontainers.image.description`,
  `org.opencontainers.image.source`.

### ⚠ The one non-obvious gotcha

Do **NOT** put `org.opencontainers.image.title` on the **manifest**. `oras pull`
treats a manifest with that annotation as a named file and writes the *manifest
JSON itself* into the output dir — polluting the pulled loadout tree. Put the
human title in `com.claude-fleet.loadout.title` instead. (Layer descriptors DO
use `org.opencontainers.image.title` — correct and required there; it's the
per-file path.)

## 3. The publish script

`scripts/publish-loadout.sh <dir> [--dry-run]` — parse frontmatter (the block
between the first two `---` lines), build annotations, then `oras push` from
**inside** the loadout dir so layer titles are loadout-relative. `REGISTRY`,
`OWNER`, `REPO` are env-overridable; `title`+`description` required, `version`
optional (absent ⇒ push only `latest`):

```bash
fm="$(awk 'NR==1 && /^---[[:space:]]*$/{f=1;next} f && /^---[[:space:]]*$/{exit} f{print}' "$dir/loadout.md")"
meta() { printf '%s\n' "$fm" | yq "$1"; }
title="$(meta '.title // ""')"; description="$(meta '.description // ""')"
version="$(meta '.version // ""')"; tags_csv="$(meta '[.tags // []]|flatten|join(",")')"
id="$(basename "$dir")"; base="$REGISTRY/$OWNER/$REPO/$id"
[ -n "$version" ] && ref="$base:$version,latest" || ref="$base:latest"   # oras takes comma-separated tags
mapfile -t files < <(cd "$dir" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
( cd "$dir" && oras push "$ref" \
    --artifact-type application/vnd.claude-fleet.loadout.v1 \
    --annotation "com.claude-fleet.loadout.title=$title" \
    --annotation "org.opencontainers.image.description=$description" \
    --annotation "org.opencontainers.image.source=https://github.com/$OWNER/$REPO" \
    --annotation "com.claude-fleet.loadout.id=$id" \
    --annotation "org.opencontainers.image.version=$version" \
    --annotation "com.claude-fleet.loadout.tags=$tags_csv" \
    "${files[@]}" )
```

`scripts/publish-all.sh [--dry-run]` loops every `loadouts/*/loadout.md` through
it. Make `--dry-run` validate + print the plan without pushing — invaluable in
CI and locally.

## 4. The CI workflow

`.github/workflows/publish-loadouts.yml`, on push to `main` (paths
`loadouts/**`, `scripts/**`, the workflow) + `workflow_dispatch`:

```yaml
permissions: { contents: read, packages: write }
steps:
  - uses: actions/checkout@v4
  - id: owner
    run: echo "value=${GITHUB_REPOSITORY_OWNER,,}" >> "$GITHUB_OUTPUT"   # GHCR names must be lowercase
  - uses: oras-project/setup-oras@v1
  - uses: docker/login-action@v3
    with: { registry: ghcr.io, username: ${{ github.actor }}, password: ${{ secrets.GITHUB_TOKEN }} }
  - run: ./scripts/publish-all.sh --dry-run
    env: { REGISTRY: ghcr.io, OWNER: "${{ steps.owner.outputs.value }}" }
  - run: ./scripts/publish-all.sh
    env: { REGISTRY: ghcr.io, OWNER: "${{ steps.owner.outputs.value }}" }
```

No extra secrets — the workflow `GITHUB_TOKEN` with `packages: write` is enough.
mikefarah `yq` is preinstalled on `ubuntu-latest`.

## 5. Seed at least one loadout

Add a `loadouts/<id>/` folder with a valid `loadout.md` (frontmatter `title` +
`description` required; `version` + `tags` recommended) so the pipeline has
content on day one. Keep secrets out — loadouts are reusable.

## 6. Create the GitHub repo and push (the operational gotchas)

```bash
gh repo create <owner>/<repo> --public --source=. --remote=origin --push
```

Three snags hit in practice:

- **`workflow` OAuth scope.** A token without it is *refused* when the push
  includes a file under `.github/workflows/`. Fix:
  `gh auth refresh -s workflow --hostname github.com` (interactive device flow).
- **Git HTTPS auth.** After `gh` login, run `gh auth setup-git` so plain
  `git push` can authenticate (otherwise: "could not read Username").
- **Default branch.** `git init` may leave you on `master` while the workflow
  triggers on `main`. `git branch -M main` before the first push, then
  `gh repo edit <owner>/<repo> --default-branch main`.

## 7. Verify (don't trust it blind)

1. **Local round-trip, no registry** — the fastest correctness check and what
   catches the manifest-title gotcha:
   ```bash
   oras push --oci-layout /tmp/oci:1.0.0 --artifact-type application/vnd.claude-fleet.loadout.v1 \
     --annotation com.claude-fleet.loadout.title=... "${files[@]}"   # run from inside the loadout dir
   oras pull --oci-layout /tmp/oci:1.0.0 -o /tmp/out
   diff -r <loadout-dir> /tmp/out          # MUST be identical — no stray manifest file
   ```
2. **Real registry** after CI runs: `oras repo tags <ref-base>`,
   `oras manifest fetch <ref>:latest | yq -p=json .annotations`, then
   `oras pull <ref>:latest -o /tmp/p && diff -r <loadout-dir> /tmp/p`.

## Consuming (reference — not built here)

```bash
oras manifest fetch <ref>:latest | jq .annotations      # metadata, no blobs
oras pull <ref>:latest -o <userData>/loadouts/<id>      # the installable tree
```
