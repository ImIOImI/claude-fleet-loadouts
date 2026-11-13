---
description: Use before running any AWS CLI/SDK command in a claude-fleet remote workspace pod. Lists the view-only profiles (one per account), how to pick one, and what is denied by design.
---

# AWS view-only profiles

This workspace has **view-only** AWS access. Each profile assumes that account's
`platform-ops-fleet-agent-workspace-<env>` role from the pod's own credentials
(`credential_source = EcsContainer`, EKS Pod Identity).

## Pick a profile

Always name the account explicitly; there is no default profile.

```sh
aws sts get-caller-identity --profile dev
aws ec2 describe-vpcs --profile prd
AWS_PROFILE=data aws s3 ls
```

| Profile | Account |
|---|---|
| `infra` | 567639518918 |
| `dev` | 267933243332 |
| `stg` | 162296318744 |
| `prd` | 511893001344 |
| `b2c-dev` | 715841360793 |
| `b2c-stg` | 084828581597 |
| `b2c-prd` | 054037097233 |
| `data` | 533267385636 |

All profiles default to `us-east-1`; pass `--region` for anything else.

The profiles live in `aws-config` beside this file. `AWS_CONFIG_FILE` points at it
through the workspace `.claude/settings.json`. If `aws configure list-profiles`
doesn't show them, that key was skipped at install; prefix the command instead:

```sh
AWS_CONFIG_FILE=/workspace/.claude/skills/aws-view-only/aws-config aws sts get-caller-identity --profile infra
```

## What is denied, by design

The roles are `ViewOnlyAccess` (list/describe/get-metadata) plus an explicit deny on:

- `secretsmanager:GetSecretValue` / `BatchGetSecretValue`
- `ssm:GetParameter`, `GetParameters`, `GetParametersByPath`
- `kms:Decrypt`
- `lambda:ListFunctions`, `ListVersionsByFunction` (expose env vars)
- `ecs:DescribeTaskDefinition` (exposes env vars)
- `ec2:DescribeInstanceAttribute`, `DescribeLaunchTemplateVersions` (expose userData)

An `AccessDenied` on these is expected. Do not work around it: no other roles,
profiles, access keys, or reading the values from another source. No writes are
possible either. If a task needs a secret value or a change, say what you need
and stop; a human does it.
