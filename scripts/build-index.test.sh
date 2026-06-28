#!/usr/bin/env bash
# Verify build-index.sh emits a valid index for the repo's loadouts.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"

json="$("$here/build-index.sh")"

# Is valid JSON array, non-empty.
echo "$json" | jq -e 'type == "array" and length > 0' >/dev/null \
  || { echo "FAIL: not a non-empty JSON array" >&2; exit 1; }

# One entry per loadout folder.
want=$(find "$root"/loadouts -maxdepth 2 -name loadout.md | wc -l | tr -d ' ')
got=$(echo "$json" | jq 'length')
[ "$want" = "$got" ] || { echo "FAIL: expected $want entries, got $got" >&2; exit 1; }

# Every entry has the required fields with the right types and a non-empty version.
echo "$json" | jq -e 'all(.[]; (.id|type=="string" and length>0)
  and (.title|type=="string" and length>0)
  and (.description|type=="string")
  and (.tags|type=="array")
  and (.version|type=="string" and length>0))' >/dev/null \
  || { echo "FAIL: an entry is missing a required field / non-empty version" >&2; exit 1; }

# Sorted by id.
echo "$json" | jq -e '. == (sort_by(.id))' >/dev/null \
  || { echo "FAIL: entries not sorted by id" >&2; exit 1; }

echo "PASS: $(echo "$json" | jq 'length') loadouts indexed"
