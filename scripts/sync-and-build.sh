#!/bin/bash
# RTK upstream sync + build + deploy
# Usage: ./scripts/sync-and-build.sh [--force]
#
# Flow:
#   1. Fetch upstream (rtk-ai/rtk)
#   2. Merge upstream/master into local master
#   3. Docker build (GLIBC 2.35 compatible)
#   4. Deploy binary to ~/.local/bin/rtk
#   5. Verify
#
# Hook (rtk-rewrite.sh) is managed via symlink:
#   ~/.claude/hooks/rtk-rewrite.sh → <repo>/hooks/rtk-rewrite.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_DEST="$HOME/.local/bin/rtk"
FORCE="${1:-}"

cd "$REPO_DIR"

echo "=== RTK Sync & Build ==="

# 1. Fetch upstream
echo "[1/5] Fetching upstream..."
git fetch upstream

# 2. Check if merge needed
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse upstream/master)

if [ "$LOCAL" = "$REMOTE" ] && [ "$FORCE" != "--force" ]; then
  echo "Already up-to-date ($(rtk --version 2>/dev/null || echo 'unknown'))"
  echo "Use --force to rebuild anyway."
  exit 0
fi

# 3. Merge upstream
echo "[2/5] Merging upstream/master..."
if ! git merge upstream/master -m "sync: upstream $(date +%Y-%m-%d)"; then
  echo "ERROR: Merge conflict detected. Resolve manually:"
  echo "  cd $REPO_DIR"
  echo "  git status"
  echo "  # resolve conflicts, then: git add . && git commit"
  exit 1
fi

# 4. Docker build
echo "[3/5] Building (Docker rust:1.85-slim)..."
docker run --rm -v "$REPO_DIR":/src -w /src rust:1.85-slim \
  sh -c "apt-get update -qq && apt-get install -y -qq pkg-config > /dev/null 2>&1 && cargo build --release 2>&1"

# 5. Deploy
echo "[4/5] Deploying to $BINARY_DEST..."
cp target/release/rtk "$BINARY_DEST"

# 6. Verify
echo "[5/5] Verifying..."
NEW_VER=$("$BINARY_DEST" --version 2>&1)
echo "Deployed: $NEW_VER"
echo "Hook symlink: $(readlink -f ~/.claude/hooks/rtk-rewrite.sh 2>/dev/null || echo 'NOT SET')"
echo "=== Done ==="
