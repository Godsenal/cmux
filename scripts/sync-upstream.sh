#!/usr/bin/env bash
# Sync this fork with upstream (manaflow-ai/cmux).
#
# Strategy (see FORK.md):
#   - `main` mirrors upstream/main exactly (fast-forward only, never commit here)
#   - `godsenal` is the personal dev branch (default); upstream lands via merge
#   - by default we merge the LATEST RELEASE TAG (v0.x), not main tip: main
#     takes 100-270 commits/day and nightly regressions land there first.
#     `--main` merges upstream/main tip instead.
#
# Usage: scripts/sync-upstream.sh [--push] [--main]
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
PUSH=false
USE_MAIN=false
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=true ;;
    --main) USE_MAIN=true ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

current_branch=$(git rev-parse --abbrev-ref HEAD)
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "✗ Working tree not clean — commit or stash first." >&2
  exit 1
fi

echo "→ Fetching upstream (branches + tags)..."
# --force: upstream moves floating tags like `nightly`; without it the whole
# fetch fails with "would clobber existing tag" and the sync never runs.
git fetch upstream main --tags --force

echo "→ Fast-forwarding local main to upstream/main..."
git checkout -q main
git merge --ff-only upstream/main

if $USE_MAIN; then
  TARGET=main
else
  # Latest release tag by creation date. Only v0.* — the v1.x tags are
  # pre-rename (GhosttyTabs) history and are OLDER despite the version number.
  TARGET=$(git tag --sort=creatordate | grep '^v0\.' | tail -1)
  if [[ -z "$TARGET" ]]; then
    echo "✗ No v0.* release tag found; use --main." >&2
    exit 1
  fi
fi

echo "→ Merging $TARGET into godsenal..."
git checkout -q godsenal
if git merge --no-edit "$TARGET"; then
  echo "✓ Merged $TARGET cleanly."
else
  echo "✗ Merge conflicts — resolve them, then 'git commit' and push." >&2
  exit 2
fi

if $PUSH; then
  echo "→ Pushing main + godsenal to origin..."
  git push origin main godsenal
fi

git checkout -q "$current_branch" 2>/dev/null || true
echo "✓ Sync complete. merged=$TARGET upstream/main=$(git rev-parse --short upstream/main)"
