#!/usr/bin/env bash
#
# Publish theme/discourse/ to the orphan `theme` branch, which Discourse
# imports as a REMOTE THEME.
#
# Discourse requires about.json at the ROOT of the repo it clones and does
# not support a subdirectory, so the theme cannot simply live at
# theme/discourse/ on main. An orphan branch keeps one repository — the
# alternative is a second repo whose history has nothing to do with this
# one and which would drift out of step with the chart that deploys it.
#
# Orphan, not a normal branch: the theme's history is the theme's, and
# mixing it with the deployment's makes both harder to read.
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="theme/discourse"
BRANCH="theme"
WT="$(mktemp -d)"
trap 'git worktree remove --force "$WT" 2>/dev/null || true; rm -rf "$WT"' EXIT

if git ls-remote --exit-code origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
  git fetch -q origin "$BRANCH"
  git worktree add -q -B "$BRANCH" "$WT" "origin/$BRANCH"
else
  git worktree add -q --detach "$WT"
  git -C "$WT" checkout -q --orphan "$BRANCH"
  git -C "$WT" rm -rq --cached . 2>/dev/null || true
fi

# Mirror exactly: a file deleted from theme/discourse must disappear from
# the branch, or Discourse keeps importing something no longer in source.
find "$WT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -r "$SRC"/. "$WT"/

git -C "$WT" add -A
if git -C "$WT" diff --cached --quiet; then
  echo "theme: no change"
  exit 0
fi

git -C "$WT" commit -q -m "theme: $(git rev-parse --short HEAD)"
git -C "$WT" push -q origin "$BRANCH"
echo "theme: published $BRANCH from $(git rev-parse --short HEAD)"
