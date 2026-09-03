#!/usr/bin/env bash
# Installs the `cpg` command globally (works from any directory) by dropping a thin
# wrapper into ~/.local/bin that always points back at this repo's docker-group.sh -
# for Git Bash / Linux / macOS. Windows PowerShell/cmd users: run install.ps1 instead.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/cpg" <<EOF
#!/usr/bin/env bash
exec "$REPO_ROOT/docker-group.sh" "\$@"
EOF
chmod +x "$INSTALL_DIR/cpg"

echo "Installed: $INSTALL_DIR/cpg -> $REPO_ROOT/docker-group.sh"

case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    echo "Done. Try: cpg status"
    ;;
  *)
    echo
    echo "$INSTALL_DIR isn't on your PATH yet. Add this line to ~/.bashrc (or ~/.zshrc):"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    echo "then restart your shell (or 'source ~/.bashrc'). After that: cpg status"
    ;;
esac
