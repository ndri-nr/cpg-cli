#!/usr/bin/env bash
# One-liner installer - no `git clone` needed first:
#   curl -fsSL https://raw.githubusercontent.com/ndri-nr/cpg-cli/main/install-remote.sh | bash
#
# Clones the repo (or pulls latest if already cloned) into $CPG_CLI_DIR
# (default ~/cpg-cli), then runs its install.sh to wire up `cpg`.
set -euo pipefail

REPO_URL="https://github.com/ndri-nr/cpg-cli.git"
TARGET_DIR="${CPG_CLI_DIR:-$HOME/cpg-cli}"

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

# `bash <script>` instead of executing it directly: a fresh clone's install.sh only
# has the exec bit if git recorded one, and this same one-liner runs on noexec
# mounts and Windows checkouts where it never survives.
exec bash "$TARGET_DIR/install.sh"
