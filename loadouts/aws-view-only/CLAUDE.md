## AWS access (view-only)

AWS access here is **view-only**, one profile per account (`infra`, `dev`, `stg`,
`prd`, `b2c-dev`, `b2c-stg`, `b2c-prd`, `data`). Always pass `--profile <account>`.
Secret values, SSM parameters, KMS decrypt and env-var/userData reads are denied
by design; don't try to work around a denial. Details: the `aws-view-only` skill.
