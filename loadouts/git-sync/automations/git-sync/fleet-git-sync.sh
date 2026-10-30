#!/usr/bin/env bash
# fleet-git-sync: keep the git-backed folders configured in $GIT_SYNC_CONF/*.json
# in sync under $GIT_SYNC_ROOT. Runs as a claude-fleet automation script step:
# stdout JSON lines {"todo":…} {"notify":…} {"state":…}; exit 10 = nothing to do,
# 0 = something changed or a problem was reported, 2 = invalid config.
set -uo pipefail

ROOT="${GIT_SYNC_ROOT:-/shared}"
CONF="${GIT_SYNC_CONF:-$ROOT/.git-sync.d}"
AUTHOR="${FLEET_NODE_ID:-}"
HOLD_MAX_AGE="${GIT_SYNC_HOLD_MAX_AGE:-7200}"
NOTIFY_AFTER=3
export GIT_TERMINAL_PROMPT=0

changed=0       # something was cloned, pulled or pushed
reported=0      # a todo, notify or failure was recorded
need_node_id=0  # an auto-sync folder was skipped for want of FLEET_NODE_ID
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT

say() { printf '%s\n' "$*"; }
config_error() { printf 'git-sync: %s\n' "$*" >&2; exit 2; }
last_err() { tail -n 1 "$ERR" | cut -c1-300; }
todo() { # key title body
  reported=1
  jq -cn --arg key "$1" --arg title "$2" --arg body "$3" \
    '{todo: {key: $key, title: $title, body: $body, tags: ["git-sync"]}}'
}
notify() { # key title body
  reported=1
  jq -cn --arg key "$1" --arg title "$2" --arg body "$3" '{notify: {key: $key, title: $title, body: $body}}'
}
upstream() { git -C "$1" rev-parse -q --verify '@{u}' 2>/dev/null || true; }
count() { git -C "$1" rev-list --count "$2" 2>/dev/null || echo 0; }
rebase_in_progress() { [ -d "$1/.git/rebase-merge" ] || [ -d "$1/.git/rebase-apply" ]; }
unmerged_paths() { git -C "$1" diff --name-only --diff-filter=U 2>/dev/null; }
stash_conflict_todo() { # name dir
  todo "git-sync:$1:conflict" "git-sync: conflict in $1" \
    "Local edits conflicted with the remote while reapplying the autostash. They are preserved in \`git stash list\` inside $2 (not lost). Resolve with: cd $2 && git status (fix the conflicted files), then git add -A && git stash drop."
  say "$1: conflict; local edits are in git stash list"
}

# GH_TOKEN reaches git through run-scoped env config only; nothing is written to disk.
if [ -n "${GH_TOKEN:-}" ]; then
  export GIT_CONFIG_COUNT=2 \
    GIT_CONFIG_KEY_0='credential.https://github.com.helper' GIT_CONFIG_VALUE_0='' \
    GIT_CONFIG_KEY_1='credential.https://github.com.helper' \
    GIT_CONFIG_VALUE_1='!f() { test "$1" = get && echo username=x-access-token && echo "password=$GH_TOKEN"; }; f'
fi

# One sync per root: several containers may mount the same /shared.
mkdir -p "$ROOT" || config_error "cannot create $ROOT"
exec 9>"$ROOT/.git-sync.lock" || config_error "cannot open $ROOT/.git-sync.lock"
if ! flock -n 9; then say "another git-sync run holds $ROOT/.git-sync.lock; skipping"; exit 10; fi

# ── config ──
shopt -s nullglob
files=("$CONF"/*.json)
if [ ${#files[@]} -eq 0 ]; then say "no git-sync config in $CONF"; exit 10; fi
for f in "${files[@]}"; do
  jq -e 'type == "object" and ((.folders // []) | type == "array") and all(.folders[]?; type == "object")' "$f" >/dev/null 2>&1 \
    || config_error "$f: expected a JSON object with a \"folders\" array of objects"
done
folders=$(jq -cs '[.[] | (.folders // [])[]]' "${files[@]}")
errors=$(jq -r '
  (.[] | select((.name | type) != "string" or (.name | test("^[a-z0-9][a-z0-9._-]*$") | not))
       | "bad folder name: \(.name | tostring)"),
  (.[] | select((.remote | type) != "string" or .remote == "") | "folder \(.name): missing remote"),
  (.[] | select((.mode // "mirror") | IN("auto-sync", "mirror") | not)
       | "folder \(.name): mode must be auto-sync or mirror, got \(.mode | tostring)"),
  (group_by(.name | tostring)[] | select(length > 1) | "duplicate folder name: \(.[0].name)")
' <<<"$folders") || config_error "could not validate folder config"
[ -z "$errors" ] || config_error "$errors"

if [ -n "$AUTHOR" ] && ! [[ "$AUTHOR" =~ ^[a-z0-9-]+@[a-z0-9-]+$ ]]; then
  say "FLEET_NODE_ID '$AUTHOR' is not <name>@<team>; auto-sync folders skipped"
  AUTHOR=""
fi

# ── failure counters (state carried between runs) ──
state_in=${FLEET_STATE:-}
[ -n "$state_in" ] || state_in='{}'
failures=$(jq -c 'if type == "object" and (.failures | type) == "object"
  then (.failures | with_entries(select(.value | type == "number")))
  else {} end' <<<"$state_in" 2>/dev/null)
[ -n "$failures" ] || failures='{}'

record_failure() { # name message
  local n
  reported=1
  n=$(jq -r --arg k "$1" '((.[$k] | numbers) // 0) + 1' <<<"$failures")
  failures=$(jq -c --arg k "$1" --argjson n "$n" '.[$k] = $n' <<<"$failures")
  say "$1: failed ($n in a row): $2"
  if [ "$n" -eq "$NOTIFY_AFTER" ]; then
    notify "git-sync:$1:failing" "git-sync can't sync $ROOT/$1" \
      "$NOTIFY_AFTER runs in a row failed. Last error: $2"
  fi
}
record_ok() { failures=$(jq -c --arg k "$1" 'del(.[$k])' <<<"$failures"); }

# ── per-folder operations ──
clone_folder() { # name remote branch
  local name=$1 remote=$2 branch=$3 dir="$ROOT/$1"
  if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    todo "git-sync:$name:not-a-repo" "git-sync: $dir isn't a git clone" \
      "git-sync won't overwrite it. Move it aside so $remote can be cloned there."
    say "$name: $dir exists and is not a git clone; skipped"
    return
  fi
  if git clone -q --branch "$branch" -- "$remote" "$dir" 2>"$ERR"; then
    git -C "$dir" config core.autocrlf false
    git -C "$dir" config core.fileMode false
    git -C "$dir" config core.untrackedCache false
    git -C "$dir" config core.preloadIndex true
    record_ok "$name"; changed=1
    say "$name: cloned $remote"
  else
    record_failure "$name" "clone: $(last_err)"
  fi
}

pull_rebase() { # name dir → 0 ok; 1 conflict or failure (already reported)
  if git -C "$2" -c gc.autoDetach=false pull -q --rebase --autostash 2>"$ERR"; then
    if [ -n "$(unmerged_paths "$2")" ]; then stash_conflict_todo "$1" "$2"; return 1; fi
    return 0
  fi
  if rebase_in_progress "$2"; then
    git -C "$2" rebase --abort 2>/dev/null
    todo "git-sync:$1:conflict" "git-sync: rebase conflict in $1" \
      "Local commits are kept and not pushed. Resolve with: cd $2 && git pull --rebase"
    say "$1: rebase conflict; local commits kept"
    return 1
  fi
  record_failure "$1" "pull: $(last_err)"
  return 1
}

sync_auto() { # name scoped
  local name=$1 scoped=$2 dir="$ROOT/$1" scope hold n up_before up_mid pulled ahead outside
  if [ -n "$(unmerged_paths "$dir")" ]; then stash_conflict_todo "$name" "$dir"; return; fi
  if [ -z "$AUTHOR" ]; then need_node_id=1; say "$name: skipped (FLEET_NODE_ID is not set)"; return; fi
  if [ "$scoped" = true ]; then scope="$AUTHOR"; hold="$dir/$AUTHOR/.sync-hold"; else scope="."; hold="$dir/.sync-hold"; fi
  if [ -e "$hold" ]; then
    if [ $(( $(date +%s) - $(stat -c %Y "$hold") )) -lt "$HOLD_MAX_AGE" ]; then
      say "$name: held by ${hold#"$ROOT"/}; skipped"
      return
    fi
    todo "git-sync:$name:stale-hold" "git-sync: stale hold in $name" \
      "$hold is older than $((HOLD_MAX_AGE / 3600))h, so git-sync ignored it. Delete it if no writer is running."
  fi
  if [ "$scoped" = true ]; then
    outside=$(git -C "$dir" status --porcelain -- . ":(exclude)$AUTHOR" ':(exclude,glob)**/.sync-hold' | head -n 20)
    if [ -n "$outside" ]; then
      todo "git-sync:$name:outside-edits" "git-sync: edits outside $AUTHOR/ in $name" \
        "These stay local and are never pushed by this node:"$'\n'"$outside"
    fi
  fi
  if [ "$scope" = . ] || [ -e "$dir/$scope" ]; then
    git -C "$dir" add -A -- "$scope" ':(exclude,glob)**/.sync-hold' 2>"$ERR" \
      || { record_failure "$name" "add: $(last_err)"; return; }
  fi
  n=$(git -C "$dir" diff --cached --name-only -- "$scope" | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    git -C "$dir" -c user.name="$AUTHOR" -c user.email="$AUTHOR@fleet.invalid" \
      commit -q -m "sync: $n files from $AUTHOR" -- "$scope" 2>"$ERR" || { record_failure "$name" "commit: $(last_err)"; return; }
  fi
  up_before=$(upstream "$dir")
  if [ -z "$up_before" ]; then
    record_failure "$name" "no upstream branch for $(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)"
    return
  fi
  pull_rebase "$name" "$dir" || return
  up_mid=$(upstream "$dir")
  pulled=0
  if [ -n "$up_before" ] && [ "$up_before" != "$up_mid" ]; then pulled=$(count "$dir" "$up_before..$up_mid"); fi
  ahead=$(count "$dir" '@{u}..HEAD')
  if [ "$ahead" -gt 0 ]; then
    if ! git -C "$dir" push -q 2>"$ERR"; then
      pull_rebase "$name" "$dir" || return
      ahead=$(count "$dir" '@{u}..HEAD')
      if ! git -C "$dir" push -q 2>"$ERR"; then record_failure "$name" "push: $(last_err)"; return; fi
    fi
    changed=1
  fi
  [ "$pulled" -gt 0 ] && changed=1
  record_ok "$name"
  if [ "$ahead" -gt 0 ] || [ "$pulled" -gt 0 ]; then
    say "$name: pushed $ahead commit(s), pulled $pulled commit(s)"
  else
    say "$name: up to date"
  fi
}

sync_mirror() { # name
  local name=$1 dir="$ROOT/$1" dirty ahead behind
  if [ -n "$(unmerged_paths "$dir")" ]; then stash_conflict_todo "$name" "$dir"; return; fi
  dirty=$(git -C "$dir" status --porcelain | head -n 20)
  if [ -n "$dirty" ]; then
    todo "git-sync:$name:local-edits" "git-sync: local edits in mirror $name" \
      "Pulls into $dir are paused until these are proposed upstream or discarded:"$'\n'"$dirty"
    say "$name: local edits in a mirror; skipped"
    return
  fi
  if ! git -C "$dir" -c gc.autoDetach=false fetch -q 2>"$ERR"; then record_failure "$name" "fetch: $(last_err)"; return; fi
  if [ -z "$(upstream "$dir")" ]; then
    record_failure "$name" "no upstream branch for $(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)"
    return
  fi
  ahead=$(count "$dir" '@{u}..HEAD')
  if [ "$ahead" -gt 0 ]; then
    todo "git-sync:$name:local-edits" "git-sync: local commits in mirror $name" \
      "$dir has $ahead local commit(s) that aren't on the remote. Pulls are paused until they're proposed upstream or dropped."
    say "$name: local commits in a mirror; skipped"
    return
  fi
  behind=$(count "$dir" 'HEAD..@{u}')
  if [ "$behind" -gt 0 ]; then
    if ! git -C "$dir" -c gc.autoDetach=false merge -q --ff-only '@{u}' 2>"$ERR"; then record_failure "$name" "merge: $(last_err)"; return; fi
    changed=1
    say "$name: pulled $behind commit(s)"
  else
    say "$name: up to date"
  fi
  record_ok "$name"
}

# ── main ──
tsv=$(jq -r '.[] | [.name, .remote, (.branch // "main"), (.mode // "mirror"),
                     ((if .author_scoped == false then false else true end) | tostring)] | @tsv' <<<"$folders") \
  || config_error "could not build folder list"
if [ -n "$tsv" ]; then
  while IFS=$'\t' read -r -u 3 name remote branch mode scoped; do
    if [ ! -d "$ROOT/$name/.git" ]; then clone_folder "$name" "$remote" "$branch"; continue; fi
    if [ "$mode" = auto-sync ]; then sync_auto "$name" "$scoped"; else sync_mirror "$name"; fi
  done 3<<<"$tsv"
fi

if [ "$need_node_id" = 1 ]; then
  todo "git-sync:node-id" "git-sync: set FLEET_NODE_ID to sync auto-sync folders" \
    "Auto-sync folders commit as the node id (<name>@<team>, or agent-<name>@<team> for agents). Set FLEET_NODE_ID as an env var on the workspace that runs the git-sync automation. Mirror folders still sync."
fi
jq -cn --argjson f "$failures" '{state: {failures: $f}}'
if [ "$changed" = 1 ] || [ "$reported" = 1 ]; then exit 0; fi
exit 10
