#!/usr/bin/env bash
# Sync this fork with upstream (manaflow-ai/cmux).
#
# Strategy:
#   - `main` mirrors upstream/main exactly (fast-forward only, never commit here)
#   - `godsenal` is the personal dev branch (default); upstream lands via merge
#
# Usage: scripts/sync-upstream.sh [--push]
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
PUSH=${1:-}

current_branch=$(git rev-parse --abbrev-ref HEAD)
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "✗ Working tree not clean — commit or stash first." >&2
  exit 1
fi

echo "→ Fetching upstream..."
git fetch upstream main

echo "→ Fast-forwarding local main to upstream/main..."
git checkout -q main
git merge --ff-only upstream/main

echo "→ Merging main into godsenal..."
git checkout -q godsenal
if git merge --no-edit main; then
  echo "✓ Merged cleanly."
else
  echo "✗ Merge conflicts — resolve them, then 'git commit' and push." >&2
  exit 2
fi

if [[ "$PUSH" == "--push" ]]; then
  echo "→ Pushing main + godsenal to origin..."
  git push origin main godsenal
fi

git checkout -q "$current_branch" 2>/dev/null || true
echo "✓ Sync complete. upstream/main = $(git rev-parse --short upstream/main)"
