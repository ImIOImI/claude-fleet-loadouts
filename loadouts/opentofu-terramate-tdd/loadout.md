---
title: OpenTofu + Terramate Platform Engineering
version: 1.0.0
description: >-
  Scopes a workspace to OpenTofu/Terramate infrastructure-as-code and adapts the
  superpowers methodology to it. Installs the superpowers plugin, redirects its
  app-code TDD to a test-first IaC loop (tofu test / policy / plan-diff), gates
  state-changing operations behind plan review, and adds multi-stack Terramate
  orchestration. Use on any OpenTofu/Terraform + Terramate repo where you want
  superpowers discipline without app-programming assumptions.
tags: [skill, rules, opentofu, terraform, terramate, iac, platform-engineering, tdd, superpowers]
dependencies:
  tools:
    - { cmd: tofu }
    - { cmd: terramate }
    - { cmd: tflint }
    - { cmd: trivy }
    - { cmd: opa }
scripts:
  - label: install superpowers plugin
    run: claude plugin install superpowers@claude-plugins-official
    unless: claude plugin list 2>/dev/null | grep -q superpowers
---

# OpenTofu + Terramate Platform Engineering

This loadout makes the [superpowers](https://github.com/obra/superpowers)
methodology work for infrastructure-as-code instead of application code. It does
**not** edit superpowers — it layers on top of it, using superpowers' own
priority rule that `CLAUDE.md` and project skills outrank plugin skills.

## What it installs

- **superpowers plugin** (via the official marketplace) — left pristine and
  upgradeable.
- **A CLAUDE.md block** that scopes the workspace to `tofu`/`terramate`,
  declares application programming out of scope, and wires the precedence:
  superpowers' brainstorming, planning, worktrees, debugging, code review, and
  `verification-before-completion` all apply as-is; TDD is redirected; state ops
  are gated.
- **Three project skills:**
  - `opentofu-tdd` — the IaC analog of `test-driven-development`. Define the
    check first (`tofu test` plan-mode run blocks, `tflint`/`trivy config`/`opa`
    policy, or a written plan-diff contract), watch it fail, write minimal HCL
    to pass. Supersedes the generic TDD skill for infra changes.
  - `terramate-orchestration` — scope work to changed stacks
    (`terramate list/run --changed`), order by the stack graph, keep code
    generation in sync, and wire the per-stack plan as the verification harness.
  - `iac-state-safety` — plan review, apply-from-saved-plan, and explicit human
    approval before any `apply`/destroy/`-target`/`-replace`/state mutation.

## Why this shape

The generic `test-driven-development` skill assumes RED-GREEN on functions,
which doesn't map to declarative HCL. Rather than disabling or forking
superpowers, this loadout preserves the *discipline* (define the check first,
watch it fail, minimal change to pass) and swaps only the *mechanics* to native
OpenTofu testing and policy tooling. `verification-before-completion` is kept
verbatim — the CLAUDE.md block just tells it which commands prove IaC work
(`tofu validate`, `tofu test`, `tofu plan`, `tflint`, `trivy config`,
`terramate run --changed`).

## Requirements

Expects `tofu`, `terramate`, `tflint`, `trivy`, and `opa` on PATH (checked
before install). `conftest`/`checkov` are intentionally not required — the
skills prefer the tools above. The install script adds the superpowers plugin if
it isn't already present.

## After install

Skills and the CLAUDE.md block load on the next Claude session in the workspace.
Start a fresh session (or `/clear`) so superpowers' SessionStart hook and these
overrides come up together.
