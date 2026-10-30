#!/usr/bin/env bash
# Tests for loadouts/git-sync/automations/git-sync/fleet-git-sync.sh, run against
# throwaway bare repos. Needs bash, git (>= 2.32), jq, flock.
# Usage: tests/git-sync/run.sh
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../../loadouts/git-sync/automations/git-sync/fleet-git-sync.sh"
T=""; OUT=""; RC=0

setup() {
  T=$(mktemp -d)
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  git config --global init.defaultBranch main
  git config --global user.name seed
  git config --global user.email seed@example.invalid
  : >"$T/script-gitconfig"
  export GIT_SYNC_ROOT="$T/shared" GIT_SYNC_CONF="$T/shared/.git-sync.d"
  mkdir -p "$GIT_SYNC_CONF"
  export FLEET_NODE_ID=alice@team FLEET_STATE='{}'
  unset GH_TOKEN GIT_SYNC_HOLD_MAX_AGE
}

# A bare repo seeded with README and bob@team/r.md; prints its path.
remote() {
  local bare="$T/remotes/$1.git" work="$T/seed/$1"
  mkdir -p "$T/remotes" "$T/seed"
  git init -q --bare "$bare"
  git clone -q "$bare" "$work" 2>/dev/null
  mkdir -p "$work/bob@team"
  echo seed >"$work/README"
  echo review >"$work/bob@team/r.md"
  git -C "$work" add -A
  git -C "$work" commit -qm seed
  git -C "$work" push -q origin main
  echo "$bare"
}

# Commit <path>=<content> to <bare> from another clone.
push_from_other() {
  local w; w=$(mktemp -d "$T/other.XXXX")
  git clone -q "$1" "$w"
  mkdir -p "$w/$(dirname "$2")"
  echo "$3" >"$w/$2"
  git -C "$w" add -A
  git -C "$w" commit -qm "other: $2"
  git -C "$w" push -q origin main
}

# conf <file> <name> <remote> <mode> [extra-json-merged-into-the-folder]
conf() {
  local extra=${5:-}; [ -n "$extra" ] || extra='{}'
  jq -n --arg n "$2" --arg r "$3" --arg m "$4" --argjson x "$extra" \
    '{folders: [{name: $n, remote: $r, mode: $m} + $x]}' >"$GIT_SYNC_CONF/$1"
}

sync() { OUT=$(GIT_CONFIG_GLOBAL="$T/script-gitconfig" bash "$SCRIPT" 2>"$T/stderr") && RC=0 || RC=$?; }
json_lines() { grep '^{' <<<"$OUT" || true; }
next_state() {
  FLEET_STATE=$(json_lines | jq -c 'select(has("state")) | .state' | tail -n 1)
  [ -n "$FLEET_STATE" ] || FLEET_STATE='{}'
  export FLEET_STATE
}
fail() { echo "    $*"; return 1; }
expect_rc() { [ "$RC" = "$1" ] || fail "exit $RC, want $1; stdout: $OUT; stderr: $(cat "$T/stderr")"; }
expect_out() { grep -qF -- "$1" <<<"$OUT" || fail "stdout lacks '$1': $OUT"; }
expect_todo() { json_lines | jq -r 'select(has("todo")) | .todo.key' | grep -qx -- "$1" || fail "no todo $1 in: $OUT"; }
notify_keys() { json_lines | jq -r 'select(has("notify")) | .notify.key'; }
remote_file() { git --git-dir="$1" show "main:$2" 2>/dev/null || true; }
local_dir() { echo "$GIT_SYNC_ROOT/$1"; }

# ── config ────────────────────────────────────────────────────────────────
test_no_config_exits_10() {
  sync; expect_rc 10
}
test_sample_files_are_ignored() {
  echo '{"folders":[{"name":"x","remote":"/nope"}]}' >"$GIT_SYNC_CONF/example.json.sample"
  sync; expect_rc 10
  [ ! -e "$(local_dir x)" ]
}
test_bad_mode_exits_2_and_touches_nothing() {
  local r; r=$(remote a)
  conf a.json a "$r" sideways
  sync; expect_rc 2
  grep -q "mode must be auto-sync or mirror" "$T/stderr"
  [ ! -e "$(local_dir a)" ]
}
test_duplicate_name_across_files_exits_2() {
  local r; r=$(remote a)
  conf 1.json dup "$r" mirror
  conf 2.json dup "$r" mirror
  sync; expect_rc 2
  grep -q "duplicate folder name: dup" "$T/stderr"
}
test_invalid_json_exits_2() {
  echo '{' >"$GIT_SYNC_CONF/bad.json"
  sync; expect_rc 2
  grep -q "bad.json" "$T/stderr"
}
test_bad_folder_name_exits_2() {
  local r; r=$(remote a)
  conf a.json ../escape "$r" mirror
  sync; expect_rc 2
  grep -q "bad folder name" "$T/stderr"
}
test_non_object_folder_entry_exits_2() {
  echo '{"folders":["x"]}' >"$GIT_SYNC_CONF/a.json"
  sync; expect_rc 2
  [ ! -e "$(local_dir x)" ]
}

# ── clone ─────────────────────────────────────────────────────────────────
test_clones_missing_folder() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync; expect_rc 0
  [ -f "$(local_dir a)/README" ]
  [ "$(git -C "$(local_dir a)" config core.autocrlf)" = false ]
  [ "$(git -C "$(local_dir a)" config core.fileMode)" = false ]
  expect_out "a: cloned"
}
test_refuses_non_git_directory() {
  local r; r=$(remote a)
  mkdir -p "$(local_dir a)"; echo keep >"$(local_dir a)/notes"
  conf a.json a "$r" mirror
  sync; expect_rc 0
  expect_todo git-sync:a:not-a-repo
  grep -qx keep "$(local_dir a)/notes"
  [ ! -d "$(local_dir a)/.git" ]
}

# ── mirror ────────────────────────────────────────────────────────────────
test_mirror_fast_forwards() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  push_from_other "$r" new.md fresh
  sync; expect_rc 0
  grep -qx fresh "$(local_dir a)/new.md"
  expect_out "a: pulled 1 commit(s)"
}
test_mirror_up_to_date_exits_10() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  sync; expect_rc 10
  expect_out "a: up to date"
}
test_mirror_keeps_local_edits() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  echo mine >"$(local_dir a)/README"
  push_from_other "$r" new.md fresh
  sync; expect_rc 0
  expect_todo git-sync:a:local-edits
  grep -qx mine "$(local_dir a)/README"
  [ ! -e "$(local_dir a)/new.md" ]
}
test_mirror_skips_divergence() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  echo local >"$(local_dir a)/local.md"
  git -C "$(local_dir a)" add -A
  git -C "$(local_dir a)" commit -qm local
  sync; expect_rc 0
  expect_todo git-sync:a:local-edits
}

# ── auto-sync ─────────────────────────────────────────────────────────────
test_autosync_pushes_own_folder_as_author() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice@team"; echo mine >"$(local_dir a)/alice@team/x.md"
  sync; expect_rc 0
  [ "$(remote_file "$r" alice@team/x.md)" = mine ]
  [ "$(git --git-dir="$r" log -1 --format='%an <%ae>' main)" = "alice@team <alice@team@fleet.invalid>" ]
  expect_out "a: pushed 1 commit(s)"
}
test_autosync_up_to_date_exits_10() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  sync; expect_rc 10
  expect_out "a: up to date"
}
test_autosync_pulls_others_work() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  push_from_other "$r" bob@team/new.md fresh
  sync; expect_rc 0
  grep -qx fresh "$(local_dir a)/bob@team/new.md"
}
test_autosync_keeps_outside_edits_local() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  echo changed >"$(local_dir a)/bob@team/r.md"
  sync; expect_rc 0
  expect_todo git-sync:a:outside-edits
  [ "$(remote_file "$r" bob@team/r.md)" = review ]
  grep -qx changed "$(local_dir a)/bob@team/r.md"
}
test_autosync_never_commits_prestaged_outside_files() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  echo changed >"$(local_dir a)/bob@team/r.md"
  git -C "$(local_dir a)" add bob@team/r.md
  mkdir -p "$(local_dir a)/alice@team"; echo mine >"$(local_dir a)/alice@team/x.md"
  sync; expect_rc 0
  [ "$(remote_file "$r" alice@team/x.md)" = mine ]
  [ "$(remote_file "$r" bob@team/r.md)" = review ]
  expect_todo git-sync:a:outside-edits
}
test_autosync_unscoped_stages_everything() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync '{"author_scoped": false}'
  sync
  echo changed >"$(local_dir a)/README"
  sync; expect_rc 0
  [ "$(remote_file "$r" README)" = changed ]
}
test_autosync_without_node_id_skips_and_asks() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice@team"; echo mine >"$(local_dir a)/alice@team/x.md"
  unset FLEET_NODE_ID
  sync; expect_rc 0
  expect_todo git-sync:node-id
  [ -z "$(remote_file "$r" alice@team/x.md)" ]
}
test_invalid_node_id_counts_as_missing() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  export FLEET_NODE_ID="Alice Smith"
  sync; expect_rc 0
  expect_todo git-sync:node-id
}
test_push_race_is_retried_once() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  cat >"$(local_dir a)/.git/hooks/pre-push" <<EOF
#!/bin/sh
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL="$T/gitconfig"
[ -e "$T/raced" ] && exit 0
touch "$T/raced"
git clone -q "$r" "$T/race" && cd "$T/race" && echo racer >racer.md && git add -A && git commit -qm race && git push -q origin main
EOF
  chmod +x "$(local_dir a)/.git/hooks/pre-push"
  mkdir -p "$(local_dir a)/alice@team"; echo mine >"$(local_dir a)/alice@team/x.md"
  sync; expect_rc 0
  [ "$(remote_file "$r" alice@team/x.md)" = mine ]
  [ "$(remote_file "$r" racer.md)" = racer ]
}
test_autosync_rebases_over_concurrent_push() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  push_from_other "$r" bob@team/new.md theirs
  mkdir -p "$(local_dir a)/alice@team"; echo mine >"$(local_dir a)/alice@team/x.md"
  sync; expect_rc 0
  [ "$(remote_file "$r" bob@team/new.md)" = theirs ]
  [ "$(remote_file "$r" alice@team/x.md)" = mine ]
  [ -z "$(json_lines | jq -r 'select(has("todo")) | select(.todo.key == "git-sync:a:conflict")')" ]
  expect_out "a: pushed 1 commit(s)"
}
test_rebase_conflict_keeps_local_commit() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync '{"author_scoped": false}'
  sync
  push_from_other "$r" README theirs
  echo ours >"$(local_dir a)/README"
  sync; expect_rc 0
  expect_todo git-sync:a:conflict
  [ "$(git -C "$(local_dir a)" log -1 --format=%an)" = alice@team ]
  [ "$(remote_file "$r" README)" = theirs ]
  [ ! -d "$(local_dir a)/.git/rebase-merge" ]
  [ ! -d "$(local_dir a)/.git/rebase-apply" ]
}
test_autostash_conflict_is_reported_not_success() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  echo mine >"$(local_dir a)/bob@team/r.md"
  push_from_other "$r" bob@team/r.md upstream
  sync; expect_rc 0
  expect_todo git-sync:a:conflict
  ! grep -q "a: pushed" <<<"$OUT"
  ! grep -q "up to date" <<<"$OUT"
  sync; expect_rc 0
  expect_todo git-sync:a:conflict
}
test_conflicting_outside_edit_with_local_commit() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  echo mine >"$(local_dir a)/bob@team/r.md"
  mkdir -p "$(local_dir a)/alice@team"; echo mine >"$(local_dir a)/alice@team/x.md"
  push_from_other "$r" bob@team/r.md upstream
  sync; expect_rc 0
  expect_todo git-sync:a:conflict
  [ "$(remote_file "$r" bob@team/r.md)" = upstream ]
  local kept=0
  grep -q mine "$(local_dir a)/bob@team/r.md" 2>/dev/null && kept=1
  [ -n "$(git -C "$(local_dir a)" stash list)" ] && kept=1
  [ "$kept" = 1 ] || fail "local edit to bob@team/r.md was lost (not in working tree or stash)"
  [ ! -d "$(local_dir a)/.git/rebase-merge" ]
  [ ! -d "$(local_dir a)/.git/rebase-apply" ]
}
test_stuck_rebase_without_conflict_is_a_real_failure() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice@team"; echo mine >"$(local_dir a)/alice@team/x.md"
  git -C "$(local_dir a)" add -A
  git -C "$(local_dir a)" commit -qm "manual: mine"
  push_from_other "$r" bob@team/new.md fresh
  # Force the rebase sequencer's internal re-commit to fail for a reason that
  # has nothing to do with content conflicts (a broken signing config), so
  # git leaves .git/rebase-merge behind with a clean index (no unmerged
  # paths) -- the same shape the old "Committer identity unknown" bug left.
  git -C "$(local_dir a)" config commit.gpgsign true
  git -C "$(local_dir a)" config gpg.program /nonexistent-gpg-binary-xyz
  sync; expect_rc 0
  expect_out "a: failed"
  [ -z "$(json_lines | jq -r 'select(has("todo")) | select(.todo.key == "git-sync:a:conflict")')" ]
  [ "$(git -C "$(local_dir a)" log -1 --format=%s)" = "manual: mine" ]
  [ "$(remote_file "$r" bob@team/new.md)" = fresh ]
  [ ! -d "$(local_dir a)/.git/rebase-merge" ]
  [ ! -d "$(local_dir a)/.git/rebase-apply" ]
}
test_hold_skips_folder() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice@team"
  touch "$(local_dir a)/alice@team/.sync-hold"
  echo wip >"$(local_dir a)/alice@team/x.md"
  sync; expect_rc 10
  expect_out "held"
  [ -z "$(remote_file "$r" alice@team/x.md)" ]
}
test_stale_hold_is_ignored_and_never_pushed() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice@team"
  touch -d '3 hours ago' "$(local_dir a)/alice@team/.sync-hold"
  echo done >"$(local_dir a)/alice@team/x.md"
  sync; expect_rc 0
  expect_todo git-sync:a:stale-hold
  [ "$(remote_file "$r" alice@team/x.md)" = done ]
  [ -z "$(git --git-dir="$r" ls-tree -r --name-only main | grep sync-hold || true)" ]
}

# ── failures, lock, secrets, size ─────────────────────────────────────────
test_failures_notify_on_third_and_reset() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  mv "$r" "$r.away"
  sync; next_state; [ -z "$(notify_keys)" ]
  sync; next_state; [ -z "$(notify_keys)" ]
  sync; next_state; [ "$(notify_keys)" = git-sync:a:failing ]
  sync; next_state; [ -z "$(notify_keys)" ]
  mv "$r.away" "$r"
  sync; next_state
  [ "$(jq -c '.failures' <<<"$FLEET_STATE")" = '{}' ]
}
test_concurrent_run_exits_10() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  flock "$GIT_SYNC_ROOT/.git-sync.lock" sleep 3 &
  sleep 0.5
  sync; expect_rc 10
  [ ! -e "$(local_dir a)" ]
  wait
}
test_missing_upstream_is_a_failure() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  git -C "$(local_dir a)" branch --unset-upstream
  sync
  expect_out "failed"
}
test_gh_token_never_written_to_disk() {
  export GH_TOKEN=tok-must-not-hit-disk
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  expect_rc 0
  mkdir -p "$(local_dir a)/alice@team"; echo mine >"$(local_dir a)/alice@team/x.md"
  sync
  expect_rc 0
  [ -z "$(grep -rl tok-must-not-hit-disk "$GIT_SYNC_ROOT" "$r" || true)" ]
}
test_script_fits_inline_limit() {
  [ "$(wc -c <"$SCRIPT")" -lt 20000 ]
}

# ── runner ────────────────────────────────────────────────────────────────
pass=0; failed=()
for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  ( set -e; setup; trap 'rm -rf "$T"' EXIT; "$t" )
  if [ $? -eq 0 ]; then pass=$((pass + 1)); echo "ok   $t"; else failed+=("$t"); echo "FAIL $t"; fi
done
echo "$pass passed, ${#failed[@]} failed"
[ ${#failed[@]} -eq 0 ]
