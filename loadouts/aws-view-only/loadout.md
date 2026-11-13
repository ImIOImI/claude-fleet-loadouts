---
title: AWS View-Only Profiles
version: 1.0.0
description: >-
  AWS CLI/SDK profiles for the claude-fleet remote workspace pod: one view-only profile per
  SumerSports account, chained from the pod's EKS Pod Identity credentials. Sets AWS_CONFIG_FILE
  and tells sessions what is denied (secrets, SSM parameters, KMS decrypt). Install only in the
  remote workspace pod (SA fleet-agent-workspace); elsewhere the profiles have no credentials.
tags: [aws, cloud, iam, view-only, remote]
---

# AWS View-Only Profiles

Gives sessions in the remote workspace pod a profile per account. The pod runs as SA
`fleet-agent-workspace` with the Pod Identity role `platform-ops-fleet-agent-workspace`, which can
only `sts:AssumeRole` into each account's `platform-ops-fleet-agent-workspace-<env>` role:
`ViewOnlyAccess` plus an explicit deny on secret, parameter, KMS, Lambda/ECS env-var and EC2
userData reads.

## What it installs

- `.claude/skills/aws-view-only/aws-config` — the profiles (`role_arn` + `credential_source =
  EcsContainer`, `us-east-1`).
- `.claude/skills/aws-view-only/SKILL.md` — how to pick a profile and what is denied.
- `.claude/settings.json` `env.AWS_CONFIG_FILE` → `/workspace/.claude/skills/aws-view-only/aws-config`.
  The path assumes the workspace root is `/workspace` (true for container workspaces and the
  remote pod). If the workspace already has an `env` key the merge skips it; the skill gives
  the per-command fallback.
- A `CLAUDE.md` block summarising the above.

It does not touch `~/.aws/config`.

## Account map

Account ids and role names come from SumerSports/platform-ops
`infra/tofu/fleet-agent/infra/workload-identity/` (provider aliases + `aws_iam_role` names).
When an account is added there, add a profile to `aws-config`, a row to the skill table, and bump
`version`.

## Verify

```sh
aws configure list-profiles
aws sts get-caller-identity --profile infra   # Arn: ...assumed-role/platform-ops-fleet-agent-workspace-infra/...
aws secretsmanager get-secret-value --profile infra --secret-id x   # AccessDenied, by design
```
