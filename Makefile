# Convenience targets around scripts/. Override the registry destination with
# env vars, e.g.  make publish OWNER=imioimi REGISTRY=ghcr.io
.PHONY: dry-run publish publish-one

# Validate + preview every loadout without pushing.
dry-run:
	./scripts/publish-all.sh --dry-run

# Package + push every loadout (requires `oras login` first).
publish:
	./scripts/publish-all.sh

# Package + push a single loadout: make publish-one DIR=loadouts/spec-driven
publish-one:
	@test -n "$(DIR)" || { echo "usage: make publish-one DIR=loadouts/<id>" >&2; exit 1; }
	./scripts/publish-loadout.sh "$(DIR)"
