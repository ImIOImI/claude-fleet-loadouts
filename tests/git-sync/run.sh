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
  export GIT_SYNC_IDENTITY='alice <alice@example.invalid>' FLEET_STATE='{}'
  gh_user fail # never reach a real gh
  unset GH_TOKEN GIT_SYNC_HOLD_MAX_AGE GIT_SYNC_DEADLINE GIT_SYNC_MAX_FILE_BYTES
}

# A bare repo seeded with README and bob/r.md; prints its path.
remote() {
  local bare="$T/remotes/$1.git" work="$T/seed/$1"
  mkdir -p "$T/remotes" "$T/seed"
  git init -q --bare "$bare"
  git clone -q "$bare" "$work" 2>/dev/null
  mkdir -p "$work/bob"
  echo seed >"$work/README"
  echo review >"$work/bob/r.md"
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

sync() { OUT=$(PATH="$T/bin:$PATH" GIT_CONFIG_GLOBAL="$T/script-gitconfig" bash "$SCRIPT" 2>"$T/stderr") && RC=0 || RC=$?; }
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
todo_keys() { json_lines | jq -r 'select(has("todo")) | .todo.key'; }
todo_body() { json_lines | jq -r --arg k "$1" 'select(has("todo")) | .todo | select(.key == $k) | .body'; }
# shim <cmd> <bash>: a PATH wrapper that runs <bash> (with $REAL = the real command) then execs it.
shim() {
  mkdir -p "$T/bin"
  printf '#!/usr/bin/env bash\nREAL=%q\n%s\nexec "$REAL" "$@"\n' "$(command -v "$1")" "$2" >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}
shim_sync() { sync; }
# gh_user <json>|fail|403: a PATH gh whose `gh api user` prints <json>, fails, or prints
# the 403 body an App installation token gets (and exits 1, like gh does).
gh_user() {
  mkdir -p "$T/bin"
  if [ "$1" = fail ]; then printf '#!/bin/sh\nexit 1\n'
  elif [ "$1" = 403 ]; then
    printf '#!/bin/sh\necho %s\necho "gh: Resource not accessible by integration (HTTP 403)" >&2\nexit 1\n' \
      "'{\"message\":\"Resource not accessible by integration\",\"login\":\"x\",\"id\":1,\"status\":\"403\"}'"
  else printf '#!/bin/sh\n[ "$*" = "api user" ] || exit 1\ncat <<"EOF"\n%s\nEOF\n' "$1"; fi >"$T/bin/gh"
  chmod +x "$T/bin/gh"
}

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
  grep -q "a.json: folder a: mode must be auto-sync or mirror" "$T/stderr"
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
test_empty_branch_exits_2() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror '{"branch": ""}'
  sync; expect_rc 2
  grep -q "a.json: folder a: branch must be a non-empty string" "$T/stderr"
  [ ! -e "$(local_dir a)" ]
}
test_string_author_scoped_exits_2() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync '{"author_scoped": "false"}'
  sync; expect_rc 2
  grep -q "a.json: folder a: author_scoped must be true or false" "$T/stderr"
}
test_confd_files_merge() {
  local ra rb; ra=$(remote a); rb=$(remote b)
  conf 1.json a "$ra" mirror
  conf 2.json b "$rb" mirror
  sync; expect_rc 0
  [ -f "$(local_dir a)/README" ]
  [ -f "$(local_dir b)/README" ]
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
test_clone_uses_full_run_budget() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  export GIT_SYNC_DEADLINE=500
  shim timeout "case \" \$* \" in *' clone '*) echo \"\$3\" >'$T/clone-timeout' ;; esac"
  shim_sync; expect_rc 0
  expect_out "a: cloned"
  [ -f "$T/clone-timeout" ] || fail "timeout was never shimmed for the clone"
  [ "$(cat "$T/clone-timeout")" -gt 60 ] || fail "clone timeout was capped at $(cat "$T/clone-timeout")s, not given the full run budget"
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
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  [ "$(remote_file "$r" alice/x.md)" = mine ]
  [ "$(git --git-dir="$r" log -1 --format='%an <%ae>' main)" = "alice <alice@example.invalid>" ]
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
  push_from_other "$r" bob/new.md fresh
  sync; expect_rc 0
  grep -qx fresh "$(local_dir a)/bob/new.md"
}
test_autosync_keeps_outside_edits_local() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  echo changed >"$(local_dir a)/bob/r.md"
  sync; expect_rc 0
  expect_todo git-sync:a:outside-edits
  [ "$(remote_file "$r" bob/r.md)" = review ]
  grep -qx changed "$(local_dir a)/bob/r.md"
}
test_autosync_never_commits_prestaged_outside_files() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  echo changed >"$(local_dir a)/bob/r.md"
  git -C "$(local_dir a)" add bob/r.md
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  [ "$(remote_file "$r" alice/x.md)" = mine ]
  [ "$(remote_file "$r" bob/r.md)" = review ]
  expect_todo git-sync:a:outside-edits
}
test_outside_commit_is_never_pushed() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  ( cd "$(local_dir a)" && echo HACK >bob/r.md &&
    git -c user.name=mallory -c user.email=m@x commit -qam inject )
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  expect_todo git-sync:a:outside-commits
  [ "$(remote_file "$r" bob/r.md)" = review ]
  [ -z "$(remote_file "$r" alice/x.md)" ]
}
test_reverted_outside_commit_is_never_pushed() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  ( cd "$(local_dir a)" && mkdir -p .github && echo evil >.github/w.yml && git add -A &&
    git -c user.name=mallory -c user.email=m@x commit -qm add &&
    git -c user.name=mallory -c user.email=m@x rm -q .github/w.yml &&
    git -c user.name=mallory -c user.email=m@x commit -qm rm )
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  expect_todo git-sync:a:outside-commits
  [ -z "$(remote_file "$r" alice/x.md)" ]
  git --git-dir="$r" log --format=%an main | grep -qx mallory && fail "mallory's reverted commit still reached the remote"
  true
}
test_autosync_unscoped_stages_everything() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync '{"author_scoped": false}'
  sync
  echo changed >"$(local_dir a)/README"
  sync; expect_rc 0
  [ "$(remote_file "$r" README)" = changed ]
}
# ── identity ──────────────────────────────────────────────────────────────
test_identity_derived_from_gh() {
  unset GIT_SYNC_IDENTITY
  gh_user '{"login": "Alice", "id": 42, "name": "Alice Doe"}'
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  [ "$(remote_file "$r" alice/x.md)" = mine ]
  [ "$(git --git-dir="$r" log -1 --format='%an <%ae>|%cn <%ce>' main)" = \
    "Alice Doe <42+Alice@users.noreply.github.com>|Alice Doe <42+Alice@users.noreply.github.com>" ]
  [ -z "$(todo_keys)" ] || fail "unexpected todos: $(todo_keys)"
}
test_cached_identity_used_when_gh_fails() {
  unset GIT_SYNC_IDENTITY
  gh_user '{"login": "carol", "id": 7, "name": null}'
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync; next_state
  [ "$(jq -c .identity <<<"$FLEET_STATE")" = '{"login":"carol","name":"carol","email":"7+carol@users.noreply.github.com"}' ]
  gh_user fail
  mkdir -p "$(local_dir a)/carol"; echo mine >"$(local_dir a)/carol/x.md"
  sync; expect_rc 0
  [ "$(remote_file "$r" carol/x.md)" = mine ]
  [ "$(git --git-dir="$r" log -1 --format='%an <%ae>' main)" = "carol <7+carol@users.noreply.github.com>" ]
}
test_no_identity_asks_and_mirrors_still_sync() {
  unset GIT_SYNC_IDENTITY
  gh_user 403
  local r rm; r=$(remote a); rm=$(remote m)
  conf a.json a "$r" auto-sync
  conf m.json m "$rm" mirror
  sync
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  push_from_other "$rm" new.md fresh
  sync; expect_rc 0
  expect_todo git-sync:identity
  todo_body git-sync:identity | grep -q "gh auth login" || fail "todo body lacks gh auth login"
  [ -z "$(remote_file "$r" alice/x.md)" ]
  grep -qx fresh "$(local_dir m)/new.md"
}
test_bot_identity_commits_only_its_own_folder() {
  export GIT_SYNC_IDENTITY='Fleet-Agent[bot] <9+fleet-agent[bot]@users.noreply.github.com>'
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/fleet-agent[bot]"; echo mine >"$(local_dir a)/fleet-agent[bot]/x.md"
  sync; expect_rc 0
  [ "$(remote_file "$r" "fleet-agent[bot]/x.md")" = mine ]
  [ -z "$(todo_keys)" ] || fail "unexpected todos: $(todo_keys)"
  # The file fleet-agentb matches the glob fleet-agent[bot]: it must stay an outside edit.
  echo decoy >"$(local_dir a)/fleet-agentb"
  echo more >"$(local_dir a)/fleet-agent[bot]/x.md"
  sync; expect_rc 0
  expect_todo git-sync:a:outside-edits
  [ "$(remote_file "$r" "fleet-agent[bot]/x.md")" = more ]
  [ -z "$(remote_file "$r" fleet-agentb)" ]
  [ -z "$(json_lines | jq -r 'select(has("todo")) | select(.todo.key == "git-sync:a:outside-commits")')" ]
}
test_invalid_identity_counts_as_missing() {
  export GIT_SYNC_IDENTITY='Alice Smith <alice@example.invalid>' # a display name needs login|
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  expect_out "GIT_SYNC_IDENTITY isn't"
  expect_todo git-sync:identity
  [ -z "$(remote_file "$r" alice/x.md)" ]
}
test_identity_override_with_login_and_name() {
  export GIT_SYNC_IDENTITY='Alice|Alice Doe <alice@corp.example>'
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  [ "$(git --git-dir="$r" log -1 --format='%an <%ae>' main)" = "Alice Doe <alice@corp.example>" ]
}
test_push_race_is_retried_once() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  # The first push of the run lets another clone push first, so it is rejected.
  shim git "case \" \$* \" in *' push '*) [ -e '$T/raced' ] || { touch '$T/raced'
    ( \"\$REAL\" clone -q '$r' '$T/race' && cd '$T/race' && echo racer >racer.md && \"\$REAL\" add -A &&
      \"\$REAL\" -c user.name=r -c user.email=r@x commit -qm race && \"\$REAL\" push -q origin main ) >/dev/null 2>&1; } ;; esac"
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  shim_sync; expect_rc 0
  [ -e "$T/raced" ]
  [ "$(remote_file "$r" alice/x.md)" = mine ]
  [ "$(remote_file "$r" racer.md)" = racer ]
}
test_autosync_rebases_over_concurrent_push() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  push_from_other "$r" bob/new.md theirs
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  [ "$(remote_file "$r" bob/new.md)" = theirs ]
  [ "$(remote_file "$r" alice/x.md)" = mine ]
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
  [ "$(git -C "$(local_dir a)" log -1 --format=%an)" = alice ]
  [ "$(remote_file "$r" README)" = theirs ]
  [ ! -d "$(local_dir a)/.git/rebase-merge" ]
  [ ! -d "$(local_dir a)/.git/rebase-apply" ]
}
test_autostash_conflict_is_reported_not_success() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  echo mine >"$(local_dir a)/bob/r.md"
  push_from_other "$r" bob/r.md upstream
  sync; expect_rc 0
  expect_todo git-sync:a:conflict
  grep -q "a: pushed" <<<"$OUT" && fail "pushed despite the conflict"
  grep -q "up to date" <<<"$OUT" && fail "reported up to date despite the conflict"
  sync; expect_rc 0
  expect_todo git-sync:a:conflict
}
test_conflicting_outside_edit_with_local_commit() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  echo mine >"$(local_dir a)/bob/r.md"
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  push_from_other "$r" bob/r.md upstream
  sync; expect_rc 0
  expect_todo git-sync:a:conflict
  [ "$(remote_file "$r" bob/r.md)" = upstream ]
  git -C "$(local_dir a)" stash show -p | grep -qx '+mine' \
    || fail "local edit to bob/r.md is not in git stash list"
  [ ! -d "$(local_dir a)/.git/rebase-merge" ]
  [ ! -d "$(local_dir a)/.git/rebase-apply" ]
}
test_stuck_rebase_without_conflict_is_a_real_failure() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  git -C "$(local_dir a)" add -A
  git -C "$(local_dir a)" commit -qm "manual: mine"
  push_from_other "$r" bob/new.md fresh
  # Force the rebase sequencer's internal re-commit to fail for a reason that
  # has nothing to do with content conflicts (a broken signing config), so
  # git leaves .git/rebase-merge behind with a clean index (no unmerged
  # paths) -- the same shape the old "Committer identity unknown" bug left.
  # (in the script's global config: a clone's own .git/config may not set these)
  git config --file "$T/script-gitconfig" commit.gpgsign true
  git config --file "$T/script-gitconfig" gpg.program /nonexistent-gpg-binary-xyz
  sync; expect_rc 0
  expect_out "a: failed"
  [ -z "$(json_lines | jq -r 'select(has("todo")) | select(.todo.key == "git-sync:a:conflict")')" ]
  [ "$(git -C "$(local_dir a)" log -1 --format=%s)" = "manual: mine" ]
  [ "$(remote_file "$r" bob/new.md)" = fresh ]
  [ ! -d "$(local_dir a)/.git/rebase-merge" ]
  [ ! -d "$(local_dir a)/.git/rebase-apply" ]
}
test_hold_skips_folder() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice"
  touch "$(local_dir a)/alice/.sync-hold"
  echo wip >"$(local_dir a)/alice/x.md"
  sync; expect_rc 10
  expect_out "held"
  [ -z "$(remote_file "$r" alice/x.md)" ]
}
test_stale_hold_is_ignored_and_never_pushed() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice"
  touch -d '3 hours ago' "$(local_dir a)/alice/.sync-hold"
  echo done >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  expect_todo git-sync:a:stale-hold
  [ "$(remote_file "$r" alice/x.md)" = done ]
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
  local lock="$GIT_SYNC_ROOT/.git-sync.lock" i
  flock "$lock" sleep 5 &
  for i in $(seq 100); do flock -n "$lock" true || break; sleep 0.05; done
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
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync
  expect_rc 0
  [ -z "$(grep -rl tok-must-not-hit-disk "$GIT_SYNC_ROOT" "$r" || true)" ]
}
# ── untrusted clones (anyone who can write /shared can edit .git) ─────────
test_planted_fsmonitor_is_refused_and_never_runs() {
  export GH_TOKEN=secret-tok
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  git -C "$(local_dir a)" config core.fsmonitor "echo \$GH_TOKEN >$T/stolen; false"
  push_from_other "$r" new.md fresh
  sync; expect_rc 0
  expect_todo git-sync:a:unsafe-config
  [ ! -e "$T/stolen" ] || fail "fsmonitor ran"
  [ ! -e "$(local_dir a)/new.md" ]
  todo_body git-sync:a:unsafe-config | grep -qx core.fsmonitor
  todo_body git-sync:a:unsafe-config | grep -q stolen && fail "todo leaks the config value"
  [ -z "$(json_lines | jq -r 'select(has("state")) | .state.failures.a // empty')" ]
}
test_planted_hooks_never_run() {
  local r rm h d; r=$(remote a); rm=$(remote m)
  conf a.json a "$r" auto-sync
  conf m.json m "$rm" mirror
  sync
  for d in "$(local_dir a)" "$(local_dir m)"; do
    for h in post-merge post-checkout pre-commit post-commit pre-push reference-transaction post-rewrite pre-rebase pre-auto-gc; do
      printf '#!/bin/sh\ntouch %s/hook-%s\n' "$T" "$h" >"$d/.git/hooks/$h"
      chmod +x "$d/.git/hooks/$h"
    done
  done
  push_from_other "$r" bob/new.md fresh
  push_from_other "$rm" new.md fresh
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  [ "$(remote_file "$r" alice/x.md)" = mine ]
  grep -qx fresh "$(local_dir a)/bob/new.md"
  grep -qx fresh "$(local_dir m)/new.md"
  [ -z "$(ls "$T"/hook-* 2>/dev/null)" ] || fail "hooks ran: $(ls "$T"/hook-*)"
}
test_include_path_is_refused() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  printf '[core]\n\tfsmonitor = "touch %s/pwned; false"\n' "$T" >"$T/evil.cfg"
  git -C "$(local_dir a)" config include.path "$T/evil.cfg"
  push_from_other "$r" new.md fresh
  sync; expect_rc 0
  expect_todo git-sync:a:unsafe-config
  [ ! -e "$T/pwned" ]
  [ ! -e "$(local_dir a)/new.md" ]
}
test_changed_origin_url_is_refused() {
  local r r2; r=$(remote a); r2=$(remote evil)
  conf a.json a "$r" auto-sync
  sync
  git -C "$(local_dir a)" remote set-url origin "$r2"
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  expect_todo git-sync:a:remote-changed
  [ -z "$(remote_file "$r2" alice/x.md)" ]
}
test_config_remote_change_raises_remote_changed() {
  local r r2; r=$(remote a); r2=$(remote b)
  conf a.json a "$r" mirror
  sync
  conf a.json a "$r2" mirror
  push_from_other "$r2" new.md fresh
  sync; expect_rc 0
  expect_todo git-sync:a:remote-changed
  [ ! -e "$(local_dir a)/new.md" ]
  [ "$(git -C "$(local_dir a)" remote get-url origin)" = "$r" ]
}
test_config_branch_change_raises_remote_changed() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  conf a.json a "$r" mirror '{"branch": "dev"}'
  sync; expect_rc 0
  expect_todo git-sync:a:remote-changed
}
test_user_identity_config_is_allowed() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  git -C "$(local_dir a)" config user.name "Someone"
  git -C "$(local_dir a)" config user.email x@y
  push_from_other "$r" new.md fresh
  sync; expect_rc 0
  expect_out "a: pulled 1 commit(s)"
  [ -z "$(json_lines | jq -r 'select(has("todo")) | select(.todo.key == "git-sync:a:unsafe-config")')" ]
}
test_detached_head_gets_gentle_todo() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  git -C "$(local_dir a)" checkout -q --detach HEAD
  push_from_other "$r" new.md fresh
  sync; expect_rc 0
  expect_todo git-sync:a:detached
  [ ! -e "$(local_dir a)/new.md" ]
  [ -z "$(json_lines | jq -r 'select(has("todo")) | select(.todo.key == "git-sync:a:remote-changed")')" ]
}

# ── todo dedupe, state pruning, deadline ──────────────────────────────────
test_persistent_todo_is_emitted_once() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync; next_state
  echo changed >"$(local_dir a)/bob/r.md"
  sync; next_state; expect_todo git-sync:a:outside-edits
  sync; next_state; expect_rc 10
  [ -z "$(todo_keys)" ] || fail "re-emitted: $(todo_keys)"
  echo more >"$(local_dir a)/bob/new.md"
  sync; next_state; expect_todo git-sync:a:outside-edits
  git -C "$(local_dir a)" checkout -q -- bob/r.md; rm "$(local_dir a)/bob/new.md"
  sync; next_state
  [ "$(jq -c '.seen' <<<"$FLEET_STATE")" = '{}' ]
  echo changed >"$(local_dir a)/bob/r.md"
  sync; next_state; expect_todo git-sync:a:outside-edits
}
test_state_is_pruned_to_configured_folders() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  export FLEET_STATE='{"failures":{"gone":2},"seen":{"git-sync:gone:conflict":"1","git-sync:identity":"2"}}'
  sync; next_state
  [ "$(jq -c '[.failures, .seen]' <<<"$FLEET_STATE")" = '[{},{}]' ]
}
test_deadline_defers_and_rotates() {
  local ra rb rc; ra=$(remote a); rb=$(remote b); rc=$(remote c)
  jq -n --arg a "$ra" --arg b "$rb" --arg c "$rc" \
    '{folders: [{name: "a", remote: $a}, {name: "b", remote: $b}, {name: "c", remote: $c}]}' >"$GIT_SYNC_CONF/x.json"
  export GIT_SYNC_DEADLINE=0
  sync; next_state; expect_out "a: cloned"; expect_out "deferred to the next run: b c"
  [ ! -e "$(local_dir b)" ]
  sync; next_state; expect_out "b: cloned"; expect_out "deferred to the next run: c a"
  sync; next_state; expect_out "c: cloned"
}
test_clone_deferred_when_budget_too_small() {
  local ra rb; ra=$(remote a); rb=$(remote b)
  jq -n --arg a "$ra" --arg b "$rb" \
    '{folders: [{name: "a", remote: $a}, {name: "b", remote: $b}]}' >"$GIT_SYNC_CONF/x.json"
  export GIT_SYNC_DEADLINE=50 # b's budget (DEADLINE+30-SECONDS) is ~80s: under the 90s floor
  sync; next_state
  expect_out "a: cloned"
  expect_out "deferred to the next run: b"
  [ ! -e "$(local_dir b)" ]
}
test_hung_remote_times_out_and_state_is_printed() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  shim git "case \" \$* \" in *' fetch '*) exec sleep 30 ;; esac"
  export GIT_SYNC_DEADLINE=-28 # leaves ~2 s for each network call
  shim_sync; expect_rc 0
  expect_out "timed out"
  next_state
  [ "$(jq -r '.failures.a' <<<"$FLEET_STATE")" = 1 ]
}
test_failure_reports_the_error_line() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  mv "$r" "$r.away"
  sync; expect_rc 0
  expect_out "fetch: fatal: "
  grep -q "repository exists" <<<"$OUT" && fail "reported prose, not the error: $OUT"
  true
}
test_failing_renotifies_daily() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  sync
  mv "$r" "$r.away"
  export FLEET_STATE='{"failures":{"a":289}}'
  sync; next_state; [ -z "$(notify_keys)" ]
  sync; next_state; [ "$(notify_keys)" = git-sync:a:failing ]
}

# ── auto-sync edge cases ──────────────────────────────────────────────────
test_large_file_stays_local() {
  export GIT_SYNC_MAX_FILE_BYTES=100
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice"; echo small >"$(local_dir a)/alice/s.md"
  head -c 200 /dev/zero >"$(local_dir a)/alice/big.bin"
  sync; expect_rc 0
  expect_todo git-sync:a:large-file
  todo_body git-sync:a:large-file | grep -qx alice/big.bin
  [ "$(remote_file "$r" alice/s.md)" = small ]
  [ -z "$(git --git-dir="$r" ls-tree -r --name-only main | grep big.bin || true)" ]
  [ "$(git -C "$(local_dir a)" status --porcelain -- alice/big.bin)" = "?? alice/big.bin" ]
}
test_deleting_own_folder_is_pushed() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; [ "$(remote_file "$r" alice/x.md)" = mine ]
  rm -rf "$(local_dir a)/alice"
  sync; expect_rc 0
  [ -z "$(remote_file "$r" alice/x.md)" ]
}
test_hold_vanishing_mid_check_is_safe() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  mkdir -p "$(local_dir a)/alice"; touch "$(local_dir a)/alice/.sync-hold"
  shim stat "case \"\$*\" in *.sync-hold*) exit 1 ;; esac" # deleted between -e and stat
  shim_sync; expect_rc 10
  expect_out "held"
  json_lines | jq -e 'select(has("state"))' >/dev/null
}
test_stale_index_lock_is_removed() {
  local r; r=$(remote a)
  conf a.json a "$r" auto-sync
  sync
  touch -d '20 minutes ago' "$(local_dir a)/.git/index.lock"
  mkdir -p "$(local_dir a)/alice"; echo mine >"$(local_dir a)/alice/x.md"
  sync; expect_rc 0
  expect_out "stale .git/index.lock"
  [ "$(remote_file "$r" alice/x.md)" = mine ]
}
test_lock_error_exits_1() {
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  mkdir -p "$GIT_SYNC_ROOT/.git-sync.lock"
  sync; expect_rc 1
  grep -q "git-sync.lock" "$T/stderr"
}
test_gh_token_reaches_git_credential_fill() {
  export GH_TOKEN=tok-123
  local r; r=$(remote a)
  conf a.json a "$r" mirror
  shim git "case \" \$* \" in *' clone '*)
    printf 'protocol=https\nhost=github.com\n\n' | \"\$REAL\" credential fill >'$T/cred' 2>&1
    printf 'protocol=https\nhost=example.com\n\n' | \"\$REAL\" credential fill >'$T/cred-other' 2>&1 ;; esac"
  shim_sync; expect_rc 0
  grep -qx username=x-access-token "$T/cred"
  grep -qx password=tok-123 "$T/cred"
  grep -q tok-123 "$T/cred-other" && fail "token offered to a non-github host"
  true
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
