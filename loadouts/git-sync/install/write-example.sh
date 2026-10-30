# git-sync loadout install step: write an example config. *.sample is never loaded.
set -e
mkdir -p /shared/.git-sync.d
cat >/shared/.git-sync.d/example.json.sample <<'EOF'
{
  "folders": [
    { "name": "reviews", "remote": "https://git.example.com/acme/reviews.git",
      "branch": "main", "mode": "auto-sync", "author_scoped": true },
    { "name": "knowledge", "remote": "https://git.example.com/acme/knowledge.git",
      "mode": "mirror" }
  ]
}
EOF
