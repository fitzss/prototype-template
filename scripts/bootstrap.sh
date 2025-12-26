#!/usr/bin/env bash
set -euo pipefail

INSTALL_CLIS=0
if [ "${1:-}" = "--install-clis" ]; then
  INSTALL_CLIS=1
fi

check_tool() {
  local tool="$1"
  local msg="$2"
  if command -v "$tool" >/dev/null 2>&1; then
    echo "[ok] $tool detected"
    return 0
  else
    echo "[missing] $tool not found. $msg"
    return 1
  fi
}

echo "Checking prerequisites..."
check_tool git "Install from https://git-scm.com/downloads"
check_tool make "Install via build-essential or Xcode Command Line Tools."
check_tool node "Install from https://nodejs.org/"
check_tool npm "Ships with Node.js; reinstall Node if missing."
check_tool docker "Install from https://docs.docker.com/get-docker/ (optional but recommended)."

if [ "$INSTALL_CLIS" -eq 1 ]; then
  if command -v npm >/dev/null 2>&1; then
    echo "Installing Codex and Gemini CLIs via npm..."
    npm install -g @openai/codex @google/gemini-cli
  else
    echo "npm is required to install the CLIs. Skipping install." >&2
  fi
else
  echo "(Skip CLI install; rerun with --install-clis to auto-install Codex/Gemini.)"
fi

echo "Next steps:"
echo "1. Copy .env.example to .env and fill in secrets."
echo "2. Run 'make help' to explore available commands."
echo "3. Use ./tools/ai/plan.sh and ./tools/ai/build_from_spec.sh to drive changes."
