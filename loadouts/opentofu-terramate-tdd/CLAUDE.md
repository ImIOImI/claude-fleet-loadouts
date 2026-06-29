# Workspace: OpenTofu + Terramate Platform Engineering

This workspace is scoped for **infrastructure-as-code platform engineering** with
OpenTofu (`tofu`) and Terramate (`terramate`). General application programming
(building app features, web frontends, services, libraries) is **out of scope**
here. If a request is application programming rather than infrastructure, say so
and ask before proceeding.

Installed and available: `tofu`, `terraform`, `terramate`, `tflint`, `trivy`,
`opa`. (`conftest`/`checkov` are NOT installed — prefer the tools listed.)

## Superpowers precedence (read this)

The `superpowers` plugin is installed and its methodology applies here —
brainstorming, planning, worktrees, subagent-driven development, systematic
debugging, code review, and `verification-before-completion` all work as-is for
IaC and should be used.

Per superpowers' own `using-superpowers` priority rules, **this CLAUDE.md
outranks superpowers skills**. Two deliberate adaptations:

1. **TDD is redirected, not skipped.** The generic `test-driven-development`
   skill assumes application code with unit tests (RED-GREEN on functions).
   That does not map to declarative HCL. When TDD would trigger for an
   infrastructure change, use the **`opentofu-tdd`** skill instead. The
   discipline is preserved (define the check first, watch it fail, write
   minimal HCL to pass); only the mechanics change.

2. **State-changing operations are gated.** Before any `tofu apply`, destroy,
   or state mutation, use the **`iac-state-safety`** skill. Never apply an
   unreviewed plan.

For any multi-stack work, use the **`terramate-orchestration`** skill to scope
and order changes.

`verification-before-completion` stays in force — the commands that prove IaC
work are `tofu validate`, `tofu test`, `tofu plan`, `tflint`, `trivy config`,
and `terramate run --changed`. Run them fresh and read the output before
claiming anything passes.
