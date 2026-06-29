---
name: terramate-orchestration
description: Use when planning or executing OpenTofu changes across more than one Terramate stack — scoping work to changed stacks, ordering by the stack graph, running code generation, and wiring the per-stack verification harness. Pair with using-git-worktrees and opentofu-tdd.
---

# Terramate Orchestration

## Overview

Terramate organizes infrastructure into **stacks** (independently planned/applied
units) and adds change detection, ordering, and code generation on top of
OpenTofu. The mistake to avoid is treating the whole repo as one blob: plan and
verify **per changed stack**, in dependency order.

**Core principle:** Touch the smallest set of stacks that the change requires,
and prove each one independently.

## Scope the work — change detection

Never run a blanket plan across every stack. Find what actually changed:
```bash
terramate list --changed                       # which stacks are affected
terramate run --changed -- tofu init -input=false
terramate run --changed -- tofu validate
terramate run --changed -- tofu plan -lock=false -input=false
```
`--changed` is git-aware; make sure you're on the working branch (see
`using-git-worktrees`) so detection compares against the right base.

## Order by the stack graph

Stacks declare relationships (`before`/`after`, or implicit ordering via config).
Terramate runs them in dependency order automatically — respect it; do not
hand-pick a stack to apply ahead of one it depends on.
```bash
terramate list --changed --run-order            # see the resolved order
```
If stack A consumes stack B's outputs, B plans/applies first. Cross-stack data
generally flows through remote state outputs or generated files, not by reaching
into another stack's resources.

## Code generation must be in sync

If the repo uses `generate_hcl` / `generate_file`, generated files are committed
artifacts. Regenerate and confirm there is no drift before planning:
```bash
terramate generate
git status --porcelain                          # generated files must be clean/committed
```
Uncommitted generation drift is a common cause of "works locally, fails in CI."

## Wire into the superpowers workflow

- **Worktree per change** (`using-git-worktrees`): a Terramate change set maps
  cleanly to one branch/worktree; change detection then scopes the blast radius.
- **Plan as the verification harness**: `terramate run --changed -- tofu plan`
  is what `verification-before-completion` runs to prove the change.
- **opentofu-tdd per stack**: the failing check → minimal HCL → clean plan loop
  happens inside each changed stack.
- **Plans, not blind applies**: applies go through `iac-state-safety`.

## Verification Checklist

Before marking multi-stack work complete:

- [ ] `terramate list --changed` matches the stacks you intended to touch (no
      surprise stacks dragged in)
- [ ] `terramate generate` run; no uncommitted generated-file drift
- [ ] `terramate run --changed -- tofu validate` clean across all changed stacks
- [ ] `terramate run --changed -- tofu plan` reviewed for **every** changed
      stack — read each diff, don't just check exit codes
- [ ] Run order respects dependencies
- [ ] `tflint` / `trivy config` clean on changed stacks

## Red Flags — STOP

- Running `tofu plan` in a single stack when the change spans several
- Applying a stack before one it depends on
- Generated files differ from committed versions
- Claiming "all stacks pass" after reading only the last stack's output
- `--changed` reports stacks you didn't expect — investigate before proceeding
