#!/usr/bin/env bash
# Release script — bumps versions, commits, and tags.
#
# Usage:
#   ./scripts/release.sh <version>    # e.g. 0.2.0
#   ./scripts/release.sh patch        # auto-bump patch (0.1.12 → 0.1.13)
#   ./scripts/release.sh minor        # auto-bump minor (0.1.12 → 0.2.0)
#   ./scripts/release.sh major        # auto-bump major (0.1.12 → 1.0.0)
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <version|patch|minor|major>"
  exit 1
fi

# Read current version from package.json (single source of truth)
CURRENT=$(node -e "process.stdout.write(require('./cli/package.json').version)")

bump_version() {
  local cur="$1" level="$2"
  IFS='.' read -r major minor patch <<< "$cur"
  case "$level" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
    *)     echo "$level" ;;  # explicit version
  esac
}

VERSION=$(bump_version "$CURRENT" "$1")

# Validate semver format
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: invalid version '$VERSION'. Expected semver (e.g. 0.2.0)"
  exit 1
fi

echo "Releasing: $CURRENT → $VERSION"

# Ensure clean working tree
if [ -n "$(git status --porcelain)" ]; then
  echo "Error: working tree is dirty. Commit or stash changes first."
  exit 1
fi

# Ensure on main branch
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
  echo "Warning: releasing from '$BRANCH' (not main). Continue? [y/N]"
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

# 1. Update mix.exs
sed -i '' "s/@version \".*\"/@version \"$VERSION\"/" mix.exs

# 2. Update cli/package.json
cd cli && npm version "$VERSION" --no-git-tag-version --allow-same-version && cd ..

# 3. Commit and tag
git add mix.exs cli/package.json
git commit -m "release: v${VERSION}"
git tag -a "v${VERSION}" -m "v${VERSION}"

echo ""
echo "✓ Tagged v${VERSION}"
echo ""
echo "Push to trigger CI release:"
echo "  git push && git push --tags"
