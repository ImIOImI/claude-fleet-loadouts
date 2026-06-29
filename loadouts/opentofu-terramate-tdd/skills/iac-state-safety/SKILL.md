---
name: iac-state-safety
description: Use before ANY state-changing OpenTofu/Terramate operation — apply, destroy, taint/replace, -target, or direct state manipulation (rm, mv, import, force-unlock). Enforces plan review, apply-from-saved-plan, and explicit human approval for irreversible actions.
---

# IaC State Safety

## Overview

`tofu apply`, destroy, and state edits are **outward-facing and hard to
reverse** — they change real infrastructure and shared state. They get the same
treatment as any irreversible action: confirm with your human partner first,
and never act on something you haven't read in full.

**Core principle:** What gets applied must equal what was reviewed.

## The Iron Law

```
NO APPLY WITHOUT A HUMAN-APPROVED PLAN — AND APPLY THE SAVED PLAN, NOT A FRESH ONE
```

A plan reviewed and then re-planned at apply time is not the plan you approved.
Capture it and apply that exact artifact:
```bash
tofu plan -out=plan.tfplan -input=false        # review the FULL output
# → present the diff, get explicit approval
tofu apply -input=false plan.tfplan            # applies exactly what was reviewed
```
Under Terramate:
```bash
terramate run --changed -- tofu plan -out=plan.tfplan -input=false
terramate run --changed -- tofu apply -input=false plan.tfplan
```

## Before you apply — the gate

1. **Read the entire plan.** Count adds / changes / **destroys**. Resource
   replacement (destroy+create) on stateful resources (databases, volumes,
   buckets) is a data-loss risk — call it out explicitly.
2. **Surface destroys and replacements** to your human partner in plain words.
   Don't bury them.
3. **Get explicit approval.** "Add X" is not approval to apply. Approval is a
   yes to the specific reviewed plan.
4. **Apply the saved plan file**, not a re-plan.

## Destroys, targeting, and replacement — extra caution

`destroy`, `-target`, and `-replace`/taint bypass the normal whole-config
reconciliation and are easy to misuse:
- Always pair with `-out` + review.
- Never `-target` to "skip" unrelated diffs you don't understand — investigate
  the diff instead.
- A full `tofu destroy` requires unambiguous, explicit human authorization
  naming what is being destroyed.

## Direct state operations — last resort

`state rm`, `state mv`, `import`, `force-unlock` mutate state outside normal
flow. Before any of them:
- **Back up state first** (`tofu state pull > state.backup.json`).
- Confirm the operation with your human partner and explain why a normal
  plan/apply can't achieve it.
- `force-unlock` only after confirming no apply is actually running — breaking a
  live lock can corrupt state.

## Drift

If `tofu plan` shows drift you didn't cause, do not silently overwrite it.
Report it, determine whether the real infra or the code is correct, then
reconcile deliberately.

## Verification Checklist

Before applying:

- [ ] Plan captured with `-out` and read in full
- [ ] Adds / changes / destroys / replacements counted and reported
- [ ] Any destroy or stateful-resource replacement explicitly flagged
- [ ] Explicit human approval for THIS plan obtained
- [ ] Applying the saved plan file (not a fresh plan)
- [ ] State backed up before any direct `state`/`import`/`force-unlock` op

## Red Flags — STOP

- `tofu apply` with no `-out` / no review (auto-approve on a change you authored)
- Applying after the config changed since the reviewed plan
- A destroy or `-replace` slipping through unmentioned
- Editing or unlocking state without a backup
- "It's probably fine" about a destroy count
- Treating approval of the *idea* as approval of the *plan*

## Relationship to other skills

- `opentofu-tdd` proves the change is correct *before* you get here.
- `terramate-orchestration` scopes which stacks apply and in what order.
- `verification-before-completion` governs the final "applied successfully"
  claim — prove it with the actual apply output and a follow-up `tofu plan`
  showing no remaining diff.
