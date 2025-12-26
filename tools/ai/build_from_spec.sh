#!/usr/bin/env bash
set -euo pipefail

if [ -n "$(git status --porcelain)" ]; then
  echo "Error: You have uncommitted changes. Please commit or stash them before running the AI builder." >&2
  exit 1
fi

SPEC="SPEC.md"
if [ ! -f "$SPEC" ]; then
  echo "SPEC.md not found. Run ./tools/ai/plan.sh first." >&2
  exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "Codex CLI not found. Install it (e.g., npm install -g @openai/codex) and try again." >&2
  exit 1
fi

prompt="Read SPEC.md, implement the listed steps exactly, run the acceptance checks, fix any failures, rerun until everything passes, then summarize the changes."

cmd=(codex exec --full-auto "$prompt")
if ! "${cmd[@]}"; then
  echo "Codex execution failed." >&2
  exit 1
fi
