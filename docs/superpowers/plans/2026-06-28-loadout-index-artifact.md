# Loadout discovery index artifact (producer side) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a discovery **index artifact** (`<registry>/<owner>/<repo>/index:latest`) so the claude-fleet app can enumerate this repo's loadouts without GitHub's PAT-gated packages API.

**Architecture:** A new `scripts/build-index.sh` parses every `loadouts/*/loadout.md` frontmatter into `index.json` (`[{id,title,description,tags,version}]`, sorted by id). `scripts/publish-all.sh` calls it after publishing the per-loadout artifacts and pushes the index as its own OCI artifact via ORAS. README + the `oci-loadout-repo` skill document the new artifact. The existing per-loadout publish flow is unchanged.

**Tech Stack:** bash, `oras`, `yq` (mikefarah), `jq`. GitHub Actions (`publish-loadouts.yml`).

## Global Constraints

- **Index artifact contract (cross-repo, exact):** ref `<REGISTRY>/<OWNER>/<REPO>/index:latest`; `--artifact-type application/vnd.claude-fleet.loadout-index.v1`; a single layer `index.json` whose content is a JSON array of `{ id, title, description, tags, version }`. The claude-fleet consumer's `ociCore.ts:parseIndex` consumes this verbatim.
- **`version` is REQUIRED non-empty in every index entry.** `parseIndex` throws on a missing/empty `version`, which would make the entire index unparseable. `loadout.md` `version` is optional, so the index builder MUST default an absent version to `0.0.0`.
- **Env contract (unchanged):** `REGISTRY` (default `ghcr.io`), `OWNER` (default `imioimi`), `REPO` (default `claude-fleet-loadouts`). Index ref base = `$REGISTRY/$OWNER/$REPO/index`.
- **`--dry-run` must validate without pushing** (mirrors the existing scripts; CI runs dry-run before the real push).
- **Reuse the existing frontmatter-parse idiom** from `scripts/publish-loadout.sh` (the `awk` frontmatter extractor + `yq` field reads) — do not invent a second parser.
- No new workflow step needed: `publish-loadouts.yml` already runs `./scripts/publish-all.sh --dry-run` then `./scripts/publish-all.sh`; the index push rides along.

---

### Task 1: `scripts/build-index.sh`

**Files:**
- Create: `scripts/build-index.sh`
- Create: `scripts/build-index.test.sh` (repeatable verification — the repo has no test framework, so this is a self-checking script)

**Interfaces:**
- Produces: `scripts/build-index.sh [OUTFILE]` — writes the index JSON to `OUTFILE` (or stdout if omitted); exit 0 on success, non-zero with a message on a malformed/empty loadout set.

- [ ] **Step 1: Write the failing test** — `scripts/build-index.test.sh`:

```bash
#!/usr/bin/env bash
# Verify build-index.sh emits a valid index for the repo's loadouts.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"

json="$("$here/build-index.sh")"

# Is valid JSON array, non-empty.
echo "$json" | jq -e 'type == "array" and length > 0' >/dev/null \
  || { echo "FAIL: not a non-empty JSON array" >&2; exit 1; }

# One entry per loadout folder.
want=$(find "$root"/loadouts -maxdepth 2 -name loadout.md | wc -l | tr -d ' ')
got=$(echo "$json" | jq 'length')
[ "$want" = "$got" ] || { echo "FAIL: expected $want entries, got $got" >&2; exit 1; }

# Every entry has the required fields with the right types and a non-empty version.
echo "$json" | jq -e 'all(.[]; (.id|type=="string" and length>0)
  and (.title|type=="string" and length>0)
  and (.description|type=="string")
  and (.tags|type=="array")
  and (.version|type=="string" and length>0))' >/dev/null \
  || { echo "FAIL: an entry is missing a required field / non-empty version" >&2; exit 1; }

# Sorted by id.
echo "$json" | jq -e '. == (sort_by(.id))' >/dev/null \
  || { echo "FAIL: entries not sorted by id" >&2; exit 1; }

echo "PASS: $(echo "$json" | jq 'length') loadouts indexed"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x scripts/build-index.test.sh && ./scripts/build-index.test.sh`
Expected: FAIL — `build-index.sh: No such file or directory` (the script doesn't exist yet).

- [ ] **Step 3: Write the implementation** — `scripts/build-index.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x scripts/build-index.sh && ./scripts/build-index.test.sh`
Expected: PASS — `PASS: <N> loadouts indexed` (N = number of `loadouts/*/` folders).

- [ ] **Step 5: Commit**

```bash
git add scripts/build-index.sh scripts/build-index.test.sh
git commit -m "feat: build-index.sh emits the loadout discovery index"
```

---

### Task 2: Push the index from `publish-all.sh`

**Files:**
- Modify: `scripts/publish-all.sh`

**Interfaces:**
- Consumes: `scripts/build-index.sh` (Task 1); env `REGISTRY`/`OWNER`/`REPO` (same defaults as `publish-loadout.sh`).
- Produces: an `index:latest` OCI artifact pushed after the per-loadout artifacts; `--dry-run` builds + prints the index but does not push.

- [ ] **Step 1: Modify `publish-all.sh`** — append the index build + push after the loadout loop. Replace the final two lines:

```bash
[ "$count" -gt 0 ] || { echo "no loadouts found under $root/loadouts/*/loadout.md" >&2; exit 1; }
echo "==> done ($count loadout(s))"
```

with:

```bash
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
```

- [ ] **Step 2: Verify the dry-run path builds + prints the index without pushing**

Run: `./scripts/publish-all.sh --dry-run`
Expected: per-loadout dry-run output as before, then `==> index (<N> loadout(s)) -> ghcr.io/imioimi/claude-fleet-loadouts/index:latest`, `(dry run — not pushing index)`, and the JSON array printed. No `oras push`. Exit 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/publish-all.sh
git commit -m "feat: publish the discovery index artifact alongside loadouts"
```

---

### Task 3: Document the index artifact

**Files:**
- Modify: `README.md` (add an "Index artifact" subsection under the artifact-format docs)
- Modify: `loadouts/oci-loadout-repo/skills/building-an-oci-loadout-repo/SKILL.md` (the contract doc — add the index artifact to "The artifact format")

**Interfaces:**
- Consumes: the format from Tasks 1–2. Docs only; no code.

- [ ] **Step 1: Add to `README.md`** — after the existing "Artifact format" section, add:

```markdown
### Index artifact (discovery)

Alongside the per-loadout artifacts, `publish-all.sh` publishes a single
**index** artifact so a client can enumerate this repo's loadouts without the
registry's (PAT-gated) catalog API:

- **Ref:** `ghcr.io/<owner>/claude-fleet-loadouts/index:latest`
- **artifactType:** `application/vnd.claude-fleet.loadout-index.v1`
- **Layer:** a single `index.json` — a JSON array of
  `{ id, title, description, tags, version }`, one entry per loadout, sorted by id.

`index.json` is generated by `scripts/build-index.sh` from each loadout's
`loadout.md` frontmatter. A loadout without a `version` is indexed as `0.0.0`
(the consumer requires a non-empty version). Pull + read it with:

​```sh
oras pull ghcr.io/<owner>/claude-fleet-loadouts/index:latest -o ./_idx
cat ./_idx/index.json
​```
```

- [ ] **Step 2: Add to the `oci-loadout-repo` skill** — in `loadouts/oci-loadout-repo/skills/building-an-oci-loadout-repo/SKILL.md`, under "The artifact format (the contract everything else implements)", add a paragraph:

```markdown
**Discovery index.** In addition to the per-loadout artifacts, the repo
publishes one **index** artifact at `<registry>/<owner>/<repo>/index:latest`,
artifactType `application/vnd.claude-fleet.loadout-index.v1`, with a single
`index.json` layer holding a JSON array of `{ id, title, description, tags,
version }` (one per loadout, sorted by id; an absent `version` is emitted as
`0.0.0`). It exists because OCI/GHCR expose no anonymous namespace listing — a
consumer pulls this one artifact to learn what loadouts the repo offers, then
pulls each `<id>:<version>` it wants. Built by `scripts/build-index.sh` and
pushed by `scripts/publish-all.sh`.
```

- [ ] **Step 3: Commit**

```bash
git add README.md loadouts/oci-loadout-repo/skills/building-an-oci-loadout-repo/SKILL.md
git commit -m "docs: document the discovery index artifact"
```

---

## Self-review notes
- **Coverage:** index generation (Task 1), publish + dry-run (Task 2), docs/contract (Task 3). The cross-repo `parseIndex` contract (required non-empty `version`, the `{id,title,description,tags,version}` shape, the `index:latest` ref + artifactType) is honored in Task 1's defaulting and Task 2's push.
- **No placeholders:** every script + doc block is complete.
- **Consistency:** `INDEX_ARTIFACT_TYPE`/ref/env match between Task 2 and the docs; `build-index.sh`'s output shape matches the test in Task 1 and `parseIndex`'s expectations.
- **YAGNI:** no per-version index, no signing, no catalog API — just the one `index:latest`.
