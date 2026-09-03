#!/usr/bin/env bash
# Installs the `cpg` command globally (works from any directory) by dropping a thin
# wrapper into ~/.local/bin that always points back at this repo's cpg-cli.sh -
# for Git Bash / Linux / macOS. Windows PowerShell/cmd users: run install.ps1 instead.
set -euo pipefail

# Everything cpg drives is docker compose - no point wiring up the command if either
# piece is missing. Offers a best-effort install per OS, but always leaves the final
# call (and any sudo/winget/brew prompt) to the user.
check_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  echo "Docker (or the 'docker compose' plugin) isn't available on this machine."

  local install_cmd=""
  case "$(uname -s)" in
    Linux)
      # Official convenience script - covers Ubuntu/Debian/Fedora/CentOS/etc and
      # already bundles the compose plugin, no separate install needed.
      install_cmd="curl -fsSL https://get.docker.com | sh"
      ;;
    Darwin)
      command -v brew >/dev/null 2>&1 && install_cmd="brew install --cask docker"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      command -v winget >/dev/null 2>&1 && install_cmd="winget install -e --id Docker.DockerDesktop"
      ;;
  esac

  if [ -n "$install_cmd" ]; then
    read -rp "Install it now with: $install_cmd ? (y/n) " yn
    if [[ "$yn" =~ ^[Yy] ]]; then
      eval "$install_cmd"
      echo
      echo "Installed (or install started). On Windows/Mac, open Docker Desktop once"
      echo "from the Start Menu/Applications and wait for it to say \"running\", then"
      echo "re-run this installer (./install.sh)."
      exit 0
    fi
  fi

  echo "Install Docker yourself: https://docs.docker.com/get-docker/"
  echo "(the compose plugin comes bundled with any current Docker install)"
  exit 1
}

check_docker

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/cpg" <<EOF
#!/usr/bin/env bash
exec "$REPO_ROOT/cpg-cli.sh" "\$@"
EOF
chmod +x "$INSTALL_DIR/cpg"

echo "Installed: $INSTALL_DIR/cpg -> $REPO_ROOT/cpg-cli.sh"

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
