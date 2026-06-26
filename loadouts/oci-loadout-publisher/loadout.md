---
title: OCI Loadout Publisher
version: 1.0.0
description: Teaches Claude to build and maintain an OCI registry repo that publishes claude-fleet loadouts as OCI artifacts (one per loadout) to GHCR via ORAS. Install in a workspace where you set up or extend a loadout distribution pipeline.
tags: [skill, oci, oras, ghcr, publishing, ci, meta]
---
Adds a "publishing-loadouts-via-oci" skill so Claude in this workspace knows the
exact process for distributing claude-fleet loadouts over OCI: the per-loadout
registry layout, the artifact format (artifactType + per-file layers + metadata
annotations), the ORAS push command, the GitHub Actions workflow, and the
push→pull round-trip verification — including the manifest-title gotcha that
would otherwise leave a stray file in every pulled loadout.
