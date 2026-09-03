#!/usr/bin/env bash
# One-liner installer - no `git clone` needed first:
#   curl -fsSL https://raw.githubusercontent.com/ndri-nr/compose-playground/main/install-remote.sh | bash
#
# Clones the repo (or pulls latest if already cloned) into $COMPOSE_PLAYGROUND_DIR
# (default ~/compose-playground), then runs its install.sh to wire up `cpg`.
set -euo pipefail

REPO_URL="https://github.com/ndri-nr/compose-playground.git"
TARGET_DIR="${COMPOSE_PLAYGROUND_DIR:-$HOME/compose-playground}"

if ! command -v git >/dev/null 2>&1; then
  echo "git is required but not found on PATH. Install git first." >&2
  exit 1
fi

if [ -d "$TARGET_DIR/.git" ]; then
  echo "Already cloned at $TARGET_DIR - pulling latest..."
  git -C "$TARGET_DIR" pull --ff-only
else
  echo "Cloning into $TARGET_DIR..."
  git clone "$REPO_URL" "$TARGET_DIR"
fi

exec "$TARGET_DIR/install.sh"
