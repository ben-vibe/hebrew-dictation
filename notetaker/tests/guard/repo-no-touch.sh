#!/usr/bin/env bash
# Fail if this branch changes a protected dictation path in the repo.
# Usage: repo-no-touch.sh [base=main]   (run inside the repo)
set -euo pipefail

base="${1:-main}"

# --no-renames so a renamed or deleted protected file still shows its old path.
changed="$(git diff --name-only --no-renames "$base"...HEAD)"

offending=()
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    dictation.lua|install.sh|LICENSE|bin/*) offending+=("$path") ;;
  esac
done <<< "$changed"

if [ ${#offending[@]} -gt 0 ]; then
  echo "FAIL: protected dictation paths changed vs $base:" >&2
  printf '  %s\n' "${offending[@]}" >&2
  exit 1
fi
echo "PASS: no protected dictation path changed vs $base"
