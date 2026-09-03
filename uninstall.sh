#!/usr/bin/env bash
# Removes the `cpg` command installed by install.sh (the ~/.local/bin wrapper only -
# doesn't touch this repo, your containers, or your volumes/data).
set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"
removed=0

for f in cpg cpg.cmd; do
  if [ -f "$INSTALL_DIR/$f" ]; then
    rm "$INSTALL_DIR/$f"
    echo "Removed $INSTALL_DIR/$f"
    removed=1
  fi
done

if [ "$removed" -eq 0 ]; then
  echo "Nothing to remove - cpg isn't installed at $INSTALL_DIR."
else
  echo "cpg uninstalled."
fi

echo
echo "This repo (and any running containers/volumes) are untouched. To fully remove"
echo "the stack too: cpg stop <group> for each group, then delete this folder."
