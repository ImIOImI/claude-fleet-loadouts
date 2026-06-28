---
title: OCI Loadout Repo
version: 1.1.0
description: Teaches Claude to build a standalone OCI repository that distributes claude-fleet loadouts as OCI artifacts on GHCR. Install in a workspace where you set up or scaffold a loadout distribution repo. Covers layout, artifact format, ORAS publish scripts, the CI workflow, and GitHub repo creation — not just pushing to an existing one.
tags: [skill, oci, oras, ghcr, distribution, ci, meta]
---
Adds a "building-an-oci-loadout-repo" skill so Claude in this workspace knows
the end-to-end process for standing up a loadout distribution repo over OCI: the
source-tree layout, the artifact-format contract (artifactType + per-file layers
+ metadata annotations, including the manifest-title gotcha), the ORAS publish
scripts, the GitHub Actions workflow, the repo-creation steps (workflow scope,
git auth, default branch), and the push→pull round-trip verification.
