#!/usr/bin/env bash
# fleet-git-sync: keep the git-backed folders configured in $GIT_SYNC_CONF/*.json
# in sync under $GIT_SYNC_ROOT. Runs as a claude-fleet automation script step:
# stdout JSON lines {"todo":…} {"notify":…} {"state":…}; exit 10 = nothing to do,
# 0 = something changed or a problem was reported, 2 = invalid config, 1 = lock error.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

ROOT="${GIT_SYNC_ROOT:-/shared}"
CONF="${GIT_SYNC_CONF:-$ROOT/.git-sync.d}"
AUTHOR="${FLEET_NODE_ID:-}"
HOLD_MAX_AGE="${GIT_SYNC_HOLD_MAX_AGE:-7200}"
DEADLINE="${GIT_SYNC_DEADLINE:-200}"             # seconds; no new folder starts after this
MAX_BYTES="${GIT_SYNC_MAX_FILE_BYTES:-52428800}" # auto-sync never commits files over this
export GIT_TERMINAL_PROMPT=0
[ -n "${GIT_SSH_COMMAND:-}" ] || export GIT_SSH_COMMAND="$(git config --global core.sshCommand || echo ssh) -o BatchMode=yes -o ConnectTimeout=20"
# Clones live in /shared, which every workspace can write: never run their hooks or fsmonitor.
safe=(-c core.hooksPath=/dev/null -c core.fsmonitor=false)
netc=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30)

changed=0       # something was cloned, pulled or pushed
reported=0      # a todo, notify or failure was emitted
need_node_id=0  # an auto-sync folder was skipped for want of FLEET_NODE_ID
carry=""        # folders not evaluated this run: keep their seen todos
ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT

say() { printf '%s\n' "$*"; }
config_error() { printf 'git-sync: %s\n' "$*" >&2; exit 2; }
die() { printf 'git-sync: %s\n' "$*" >&2; exit 1; }
last_err() { { grep -E '^(fatal|error|remote): ' "$ERR" || grep -v '^hint:' "$ERR"; } | tail -n 1 | cut -c1-300; }
g() { local d=$1; shift; git -C "$d" "${safe[@]}" "$@"; }
net() { # dir args…: a network git call, bounded so the run can always print its state
  local d=$1 t=$((DEADLINE + 30 - SECONDS)) rc cap=${NET_CAP:-60}; shift
  [ "$t" -le "$cap" ] || t=$cap; [ "$t" -ge 1 ] || t=1
  timeout -k 5 "$t" git -C "$d" "${safe[@]}" "${netc[@]}" "$@"; rc=$?
  [ "$rc" -ne 124 ] || echo "fatal: timed out after ${t}s" >&2
  return "$rc"
}
upstream() { g "$1" rev-parse -q --verify '@{u}' 2>/dev/null || true; }
count() { g "$1" rev-list --count "$2" 2>/dev/null || echo 0; }
rebase_in_progress() { [ -d "$1/.git/rebase-merge" ] || [ -d "$1/.git/rebase-apply" ]; }
unmerged_paths() { g "$1" diff --name-only --diff-filter=U 2>/dev/null; }

# ── state carried between runs: failures {name:n}, seen {todo key:fingerprint}, next ──
state=$(jq -c 'if type == "object" then . else {} end' <<<"${FLEET_STATE:-}" 2>/dev/null)
[ -n "$state" ] || state='{}'
failures=$(jq -c '(.failures | objects | with_entries(select(.value | type == "number"))) // {}' <<<"$state")
seen_in=$(jq -c '(.seen | objects) // {}' <<<"$state")
next_in=$(jq -r '(.next | strings) // ""' <<<"$state")
seen='{}'

# A todo is emitted only when its key is new or its body changed since the last run.
todo() { # key title body
  local fp; fp=$(printf '%s' "$3" | cksum | cut -d' ' -f1)
  seen=$(jq -c --arg k "$1" --arg v "$fp" '.[$k] = $v' <<<"$seen")
  [ "$(jq -r --arg k "$1" '.[$k] // ""' <<<"$seen_in")" != "$fp" ] || return 0
  reported=1
  jq -cn --arg key "$1" --arg title "$2" --arg body "$3" \
    '{todo: {key: $key, title: $title, body: $body, tags: ["git-sync"]}}'
}
notify() { # key title body
  reported=1
  jq -cn --arg key "$1" --arg title "$2" --arg body "$3" '{notify: {key: $key, title: $title, body: $body}}'
}
stash_conflict_todo() { # name dir
  todo "git-sync:$1:conflict" "git-sync: conflict in $1" \
    "Local edits conflicted with the remote while reapplying the autostash. They are preserved in \`git stash list\` inside $2 (not lost). Resolve with: cd $2 && git status (fix the conflicted files), then git restore --staged . && git stash drop."
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
mkdir -p "$ROOT" || die "cannot create $ROOT"
exec 9>"$ROOT/.git-sync.lock" || die "cannot open $ROOT/.git-sync.lock"
flock -n -E 75 9; rc=$?
if [ "$rc" -eq 75 ]; then say "another git-sync run holds $ROOT/.git-sync.lock; skipping"; exit 10; fi
[ "$rc" -eq 0 ] || die "cannot lock $ROOT/.git-sync.lock (flock exit $rc)"

# ── config ──
shopt -s nullglob
files=("$CONF"/*.json)
if [ ${#files[@]} -eq 0 ]; then say "no git-sync config in $CONF"; exit 10; fi
for f in "${files[@]}"; do
  jq -e 'type == "object" and ((.folders // []) | type == "array") and all(.folders[]?; type == "object")' "$f" >/dev/null 2>&1 \
    || config_error "$f: expected a JSON object with a \"folders\" array of objects"
done
folders=$(jq -cn '[inputs as $d | input_filename as $f | ($d.folders // [])[] | . + {_file: $f}]' "${files[@]}")
errors=$(jq -r '
  (.[] | "\(._file): folder \(.name | tostring)" as $w |
    (select((.name | type) != "string" or (.name | test("^[a-z0-9][a-z0-9._-]*$") | not)) | "\($w): bad folder name"),
    (select((.remote | type) != "string" or .remote == "") | "\($w): missing remote"),
    (select(has("branch") and ((.branch | type) != "string" or .branch == "")) | "\($w): branch must be a non-empty string"),
    (select((.mode // "mirror") | IN("auto-sync", "mirror") | not)
       | "\($w): mode must be auto-sync or mirror, got \(.mode | tostring)"),
    (select(has("author_scoped") and (.author_scoped | type) != "boolean") | "\($w): author_scoped must be true or false")),
  (group_by(.name | tostring)[] | select(length > 1)
     | "duplicate folder name: \(.[0].name) (in \(map(._file) | unique | join(", ")))")
' <<<"$folders") || config_error "could not validate folder config"
[ -z "$errors" ] || config_error "$errors"

if [ -n "$AUTHOR" ] && ! [[ "$AUTHOR" =~ ^[a-z0-9-]+@[a-z0-9-]+$ ]]; then
  say "FLEET_NODE_ID '$AUTHOR' is not <name>@<team>; auto-sync folders skipped"
  AUTHOR=""
fi
gitid=(-c "user.name=$AUTHOR" -c "user.email=$AUTHOR@fleet.invalid")

record_failure() { # name message
  local n
  reported=1
  n=$(jq -r --arg k "$1" '((.[$k] | numbers) // 0) + 1' <<<"$failures")
  failures=$(jq -c --arg k "$1" --argjson n "$n" '.[$k] = $n' <<<"$failures")
  say "$1: failed ($n in a row): $2"
  if [ $((n % 288)) -eq 3 ]; then # the 3rd failure in a row, then about once a day
    notify "git-sync:$1:failing" "git-sync can't sync $ROOT/$1" \
      "$n runs in a row failed. Last error: $2"
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
  if NET_CAP=$((DEADLINE + 30)) net "$ROOT" clone -q --branch "$branch" -- "$remote" "$dir" 2>"$ERR"; then
    g "$dir" config core.autocrlf false
    g "$dir" config core.fileMode false
    g "$dir" config core.untrackedCache false
    g "$dir" config core.preloadIndex true
    record_ok "$name"; changed=1
    say "$name: cloned $remote"
  else
    record_failure "$name" "clone: $(last_err)"
  fi
}

# Anyone who can write /shared can edit a clone's .git/config, so before touching an existing
# clone: origin and branch must match the config, and only allowlisted keys may be set locally.
check_clone() { # name remote branch → 0 safe; 1 skipped (todo raised)
  local name=$1 dir="$ROOT/$1" keys url head merge bad
  keys=$(g "$dir" config --local --no-includes --name-only --list 2>/dev/null) || keys="(unreadable .git/config)"
  url=$(g "$dir" config --local --no-includes --get-all remote.origin.url 2>/dev/null)
  head=$(g "$dir" symbolic-ref -q --short HEAD 2>/dev/null || sed 's|^refs/heads/||' "$dir"/.git/rebase-*/head-name 2>/dev/null)
  if [ -z "$head" ] && ! rebase_in_progress "$dir"; then
    todo "git-sync:$name:detached" "git-sync: $name is on a detached HEAD" \
      "$dir is on a detached HEAD, so git-sync leaves it alone. Check out $3 to resume syncing: cd $dir && git checkout $3."
    say "$name: is on a detached HEAD; check out $3 to resume syncing"
    return 1
  fi
  merge=$(g "$dir" config --local --no-includes --get "branch.$3.merge" 2>/dev/null)
  if [ "$url" != "$2" ] || [ "$head" != "$3" ] || { [ -n "$merge" ] && [ "$merge" != "refs/heads/$3" ]; }; then
    todo "git-sync:$name:remote-changed" "git-sync: $name no longer matches its config" \
      "The clone at $dir doesn't track $2 (branch $3) as configured, so git-sync leaves it alone. To re-clone, move it aside (mv $dir $dir.old); the next run clones it again. If nobody changed the config, its .git/config was edited: don't trust that clone."
    say "$name: origin or branch differs from the config; skipped"
    return 1
  fi
  bad=$(awk -v b="branch.$3." '!(/^core\.(repositoryformatversion|filemode|bare|logallrefupdates|autocrlf|untrackedcache|preloadindex|ignorecase|symlinks|precomposeunicode)$/ ||
    /^user\.(name|email)$/ || /^remote\.origin\.(url|fetch)$/ || $0 == b "remote" || $0 == b "merge")' <<<"$keys" | sort -u)
  if [ -n "$bad" ]; then
    todo "git-sync:$name:unsafe-config" "git-sync: unexpected git config in $name" \
      "$dir/.git/config sets keys git-sync doesn't allow (they can run commands or redirect pushes), so it skips this folder. Check who set them, then remove them or move the folder aside to re-clone:"$'\n'"$bad"
    say "$name: unexpected keys in .git/config; skipped"
    return 1
  fi
}

pull_rebase() { # name dir → 0 ok; 1 conflict or failure (already reported)
  if net "$2" "${gitid[@]}" -c gc.autoDetach=false pull -q --rebase --autostash 2>"$ERR"; then
    if [ -n "$(unmerged_paths "$2")" ]; then stash_conflict_todo "$1" "$2"; return 1; fi
    return 0
  fi
  if rebase_in_progress "$2"; then
    local was_unmerged; was_unmerged=$(unmerged_paths "$2")
    g "$2" "${gitid[@]}" rebase --abort 2>/dev/null
    if [ -n "$was_unmerged" ]; then
      todo "git-sync:$1:conflict" "git-sync: rebase conflict in $1" \
        "Local commits are kept and not pushed. Resolve with: cd $2 && git pull --rebase"
      say "$1: rebase conflict; local commits kept"
      return 1
    fi
  fi
  record_failure "$1" "pull: $(last_err)"
  return 1
}

outside_commits_ok() { # name dir → 0 ok to push; 1 blocked (todo raised)
  # Per-commit, not a tree diff: an add-then-revert of an outside path still shows up here,
  # so forged commits that cancel out in the tree can't sneak past this check.
  local paths; paths=$(g "$2" log --format= --name-only '@{u}..HEAD' -- . ":(exclude)$AUTHOR" 2>/dev/null | sort -u | head -n 20)
  [ -z "$paths" ] && return 0
  todo "git-sync:$1:outside-commits" "git-sync: commit(s) outside $AUTHOR/ in $1" \
    "HEAD has local commit(s) touching paths outside $AUTHOR/ (someone else committed in this clone), so nothing is pushed:"$'\n'"$paths"$'\n'"Drop them with: git -C $2 reset --soft @{u}, then review before re-adding your own changes."
  say "$1: commit(s) outside $AUTHOR/; not pushed"
  return 1
}

sync_auto() { # name scoped
  local name=$1 scoped=$2 dir="$ROOT/$1" scope hold m n e p up_before up_mid pulled ahead outside big=() ex=()
  if [ -n "$(unmerged_paths "$dir")" ]; then stash_conflict_todo "$name" "$dir"; return; fi
  if [ -z "$AUTHOR" ]; then need_node_id=1; say "$name: skipped (FLEET_NODE_ID is not set)"; return; fi
  if [ "$scoped" = true ]; then scope="$AUTHOR"; hold="$dir/$AUTHOR/.sync-hold"; else scope="."; hold="$dir/.sync-hold"; fi
  if [ -e "$hold" ]; then
    m=$(stat -c %Y "$hold" 2>/dev/null) || m=$(date +%s)
    if [ $(($(date +%s) - m)) -lt "$HOLD_MAX_AGE" ]; then
      carry+=" $name"
      say "$name: held by ${hold#"$ROOT"/}; skipped"
      return
    fi
    todo "git-sync:$name:stale-hold" "git-sync: stale hold in $name" \
      "$hold is older than $((HOLD_MAX_AGE / 3600))h, so git-sync ignored it. Delete it if no writer is running."
  fi
  if [ "$scoped" = true ]; then
    outside=$(g "$dir" status --porcelain -- . ":(exclude)$AUTHOR" ':(exclude,glob)**/.sync-hold' | head -n 20)
    if [ -n "$outside" ]; then
      todo "git-sync:$name:outside-edits" "git-sync: edits outside $AUTHOR/ in $name" \
        "These stay local and are never pushed by this node:"$'\n'"$outside"
    fi
  fi
  while IFS= read -r -d '' e; do
    p=${e:3}
    if [ -f "$dir/$p" ] && [ "$(stat -c %s "$dir/$p" 2>/dev/null || echo 0)" -gt "$MAX_BYTES" ]; then
      big+=("$p"); ex+=(":(exclude,literal)$p")
      g "$dir" reset -q -- ":(literal)$p" 2>/dev/null
    fi
  done < <(g "$dir" status --porcelain=v1 -z -uall --no-renames -- "$scope" 2>/dev/null)
  if [ ${#big[@]} -gt 0 ]; then
    todo "git-sync:$name:large-file" "git-sync: large files in $name" \
      "These are over $MAX_BYTES bytes, so they stay local and aren't committed:"$'\n'"$(printf '%s\n' "${big[@]}" | head -n 20)"
  fi
  if [ "$scope" = . ] || [ -e "$dir/$scope" ] || [ -n "$(g "$dir" ls-files -- "$scope" | head -n 1)" ]; then
    g "$dir" add -A -- "$scope" ':(exclude,glob)**/.sync-hold' "${ex[@]}" 2>"$ERR" \
      || { record_failure "$name" "add: $(last_err)"; return; }
  fi
  n=$(g "$dir" diff --cached --name-only -- "$scope" "${ex[@]}" | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    g "$dir" "${gitid[@]}" -c gc.autoDetach=false \
      commit -q -m "sync: $n files from $AUTHOR" -- "$scope" "${ex[@]}" 2>"$ERR" || { record_failure "$name" "commit: $(last_err)"; return; }
  fi
  up_before=$(upstream "$dir")
  if [ -z "$up_before" ]; then
    record_failure "$name" "no upstream branch for $(g "$dir" symbolic-ref --short HEAD 2>/dev/null)"
    return
  fi
  pull_rebase "$name" "$dir" || return
  up_mid=$(upstream "$dir")
  pulled=0
  if [ "$up_before" != "$up_mid" ]; then pulled=$(count "$dir" "$up_before..$up_mid"); fi
  ahead=$(count "$dir" '@{u}..HEAD')
  if [ "$ahead" -gt 0 ]; then
    [ "$scoped" != true ] || outside_commits_ok "$name" "$dir" || return
    if ! net "$dir" push -q 2>"$ERR"; then
      pull_rebase "$name" "$dir" || return
      ahead=$(count "$dir" '@{u}..HEAD')
      [ "$scoped" != true ] || outside_commits_ok "$name" "$dir" || return
      if ! net "$dir" push -q 2>"$ERR"; then record_failure "$name" "push: $(last_err)"; return; fi
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
  dirty=$(g "$dir" status --porcelain | head -n 20)
  if [ -n "$dirty" ]; then
    todo "git-sync:$name:local-edits" "git-sync: local edits in mirror $name" \
      "Pulls into $dir are paused until these are proposed upstream or discarded:"$'\n'"$dirty"
    say "$name: local edits in a mirror; skipped"
    return
  fi
  if ! net "$dir" -c gc.autoDetach=false fetch -q 2>"$ERR"; then record_failure "$name" "fetch: $(last_err)"; return; fi
  if [ -z "$(upstream "$dir")" ]; then
    record_failure "$name" "no upstream branch for $(g "$dir" symbolic-ref --short HEAD 2>/dev/null)"
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
    if ! g "$dir" -c gc.autoDetach=false merge -q --ff-only '@{u}' 2>"$ERR"; then record_failure "$name" "merge: $(last_err)"; return; fi
    changed=1
    say "$name: pulled $behind commit(s)"
  else
    say "$name: up to date"
  fi
  record_ok "$name"
}

sync_folder() { # name remote branch mode scoped
  local dir="$ROOT/$1"
  if [ ! -d "$dir/.git" ]; then clone_folder "$1" "$2" "$3"; return; fi
  check_clone "$1" "$2" "$3" || return
  # We hold the root lock, so an index.lock this old was left by a killed git.
  if [ -n "$(find "$dir/.git/index.lock" -mmin +10 -print -delete 2>/dev/null)" ]; then say "$1: removed a stale .git/index.lock"; fi
  if [ "$4" = auto-sync ]; then sync_auto "$1" "$5"; else sync_mirror "$1"; fi
}

# ── main: start where the last run left off; stop starting folders after the deadline ──
tsv=$(jq -r '.[] | [.name, .remote, (.branch // "main"), (.mode // "mirror"),
                     ((if .author_scoped == false then false else true end) | tostring)] | @tsv' <<<"$folders") \
  || config_error "could not build folder list"
rows=(); [ -z "$tsv" ] || mapfile -t rows <<<"$tsv"
total=${#rows[@]}; start=0; next=""; deferred=()
for i in "${!rows[@]}"; do [ "${rows[i]%%$'\t'*}" != "$next_in" ] || start=$i; done
for ((k = 0; k < total; k++)); do
  IFS=$'\t' read -r name remote branch mode scoped <<<"${rows[(start + k) % total]}"
  if [ "$k" -gt 0 ]; then
    if [ "$SECONDS" -ge "$DEADLINE" ] ||
      { [ ! -d "$ROOT/$name/.git" ] && [ $((DEADLINE + 30 - SECONDS)) -lt 90 ]; }; then
      deferred+=("$name"); continue
    fi
  fi
  sync_folder "$name" "$remote" "$branch" "$mode" "$scoped"
done
if [ ${#deferred[@]} -gt 0 ]; then
  next=${deferred[0]}; carry+=" ${deferred[*]} node-id"
  say "time limit reached; deferred to the next run: ${deferred[*]}"
elif [ "$total" -gt 0 ]; then
  next=${rows[(start + 1) % total]%%$'\t'*}
fi

if [ "$need_node_id" = 1 ]; then
  todo "git-sync:node-id" "git-sync: set FLEET_NODE_ID to sync auto-sync folders" \
    "Auto-sync folders commit as the node id, unique per node (<name>@<team>, e.g. troy-laptop@platform, or agent-<name>@<team> for agents). Set FLEET_NODE_ID as an env var on the workspace that runs the git-sync automation. Mirror folders still sync."
fi
jq -cn --argjson f "$failures" --argjson s "$seen" --argjson o "$seen_in" --arg c "$carry" --arg n "$next" \
  --argjson names "$(jq -c 'map(.name)' <<<"$folders")" '
  def folder: split(":")[1];
  ($c | split(" ")) as $c |
  {state: {failures: ($f | with_entries(select(.key | IN($names[])))),
           seen: (($o | with_entries(select(.key | folder | IN($c[])))) + $s
                  | with_entries(select(.key | folder | IN($names[], "node-id")))),
           next: $n}}'
if [ "$changed" = 1 ] || [ "$reported" = 1 ]; then exit 0; fi
exit 10
