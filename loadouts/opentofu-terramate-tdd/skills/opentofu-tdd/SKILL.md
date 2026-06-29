---
name: opentofu-tdd
description: Use when changing OpenTofu/Terraform configuration (resources, modules, variables, outputs) — the IaC analog of test-driven-development. Define the check first, watch it fail, then write minimal HCL to pass. Supersedes the generic test-driven-development skill for infrastructure work.
---

# OpenTofu TDD (Test-First Infrastructure)

## Overview

The generic `test-driven-development` skill assumes application code with
RED-GREEN on functions. Declarative HCL has no "function to call," so the
mechanics differ — but the **discipline is identical**: write the check that
expresses the desired outcome FIRST, watch it fail, then write the minimal
configuration to make it pass.

**Core principle:** If you didn't watch the check fail, you don't know it
proves anything. A plan that "looks right" or a policy that was written after
the resource proves nothing.

**Violating the letter of this rule is violating the spirit of this rule.**

## The Iron Law

```
NO RESOURCE/MODULE CHANGE WITHOUT A CHECK THAT FAILED FIRST
```

Wrote the HCL before the check? You can't trust the check anymore. Revert the
HCL, write the check, watch it fail, reimplement.

## What counts as "the check"

Pick the **fastest layer that captures the intent.** Prefer earlier layers.

| Layer | Tool | Use for | Cost |
|-------|------|---------|------|
| **1. Unit (plan)** | `tofu test` with `command = plan` run blocks (`*.tftest.hcl`) | Asserting computed values, conditionals, module wiring, counts | Fast, no real infra |
| **2. Policy** | `tflint`, `trivy config`, `opa eval` over plan JSON | Security/compliance/standards invariants | Fast, no real infra |
| **3. Plan-diff contract** | `tofu plan` reviewed against a written expectation | "This change adds exactly these N resources / changes these attributes" | Fast |
| **4. Integration (apply)** | `tofu test` with `command = apply` run blocks | Behavior only provable against real infra | Slow + costs money — gate it |

Layers 1–3 require no real infrastructure and should cover most changes. Only
reach for layer 4 when an assertion genuinely cannot be evaluated from a plan,
and treat it like a state-changing operation (see `iac-state-safety`).

## RED → GREEN → REFACTOR

### RED — Write the failing check

Write one check expressing the single behavior you want. Examples:

`*.tftest.hcl` (unit, plan-mode):
```hcl
run "bucket_is_versioned_and_private" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "Bucket versioning must be enabled"
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.this.block_public_acls == true
    error_message = "Public ACLs must be blocked"
  }
}
```

Or a written plan-diff contract (layer 3): "This change must add exactly
`aws_s3_bucket.logs` and `aws_s3_bucket_versioning.logs`, and change nothing
else."

### Verify RED — watch it fail

**MANDATORY. Never skip.**
```bash
tofu test            # the run block fails: resource/attribute missing
# or, for a plan-diff contract:
tofu plan            # confirm the desired resources are ABSENT today
```
Confirm it fails for the **right reason** (the thing you're adding is missing),
not because of a typo, missing provider, or uninitialized backend.

Check passes already? You're describing existing behavior — fix the check.

### GREEN — Minimal HCL

Write the simplest configuration that satisfies the check. No speculative
variables, no "while I'm here" extras (YAGNI applies to HCL too).
```bash
tofu validate        # syntactically + internally valid
tofu test            # the run block now passes
tofu plan            # diff is EXACTLY the intended change, nothing extra
```
All three must be clean. A plan with unexpected extra changes means GREEN is
not done.

### REFACTOR — Clean up, stay green

Only after green: extract modules, hoist `locals`, parameterize with
`variables`, DRY repeated blocks. Re-run `tofu test` + `tofu plan` and confirm
the diff is unchanged.

## Config-only changes (the narrow exception)

Pure variable rewiring, provider/version bumps, comment/format changes, and
generated files don't always admit a meaningful test-first assertion — this is
the IaC equivalent of the generic TDD skill's "configuration files" carve-out.
Even then you are NOT exempt from verification:
- `tofu validate` + `tofu plan` and read the full diff
- `tflint` and `trivy config` clean

If you find yourself calling a *resource* change "just config" to skip the
check — stop. That's rationalization.

## Red Flags — STOP and start over

- HCL written before the check existed
- `tofu test` / policy added after the resource "to document it"
- Plan shows changes you didn't intend and you proceed anyway
- "The plan looks right" without a written expectation to compare against
- Skipping `tofu test` because "validate passed" (validate ≠ behavior)
- "Too simple to test" on a resource change

## Verification Checklist

Before marking an infra change complete:

- [ ] A check existed and **failed first** (tftest / policy / written plan-diff)
- [ ] The failure was for the expected reason
- [ ] `tofu validate` clean
- [ ] `tofu test` passes (and any layer-4 apply run, if used)
- [ ] `tofu plan` diff is exactly the intended change — nothing extra
- [ ] `tflint` and `trivy config` clean
- [ ] Refactors left the plan diff unchanged

Can't check every box? You skipped the discipline. Start over.

## Relationship to other skills

- Hand off to `iac-state-safety` before any `apply`/destroy/state op.
- Use `terramate-orchestration` to run these commands across changed stacks.
- `verification-before-completion` still governs final claims — these are the
  commands it requires.
