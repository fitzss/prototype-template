#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tools/ai/plan.sh "Task description"

Generate SPEC.md by prompting the Gemini CLI. Requires the CLI to be installed
(npm install -g @google/gemini-cli).
EOF
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  usage
  exit 0
fi

desc="$*"

if ! command -v gemini >/dev/null 2>&1; then
  echo "Gemini CLI not found. Install it with: npm install -g @google/gemini-cli" >&2
  exit 1
fi

prompt=$(cat <<EOF
IMPORTANT: You are a text generator. Do NOT use any tools. Do NOT try to write files. Print the Markdown content directly to standard output.
You are Gemini, generating SPEC.md for Codex. Output only Markdown with the
sections Goal, Files to touch, Steps, and Acceptance checks (commands). Use
checklists/bullets where reasonable. Acceptance commands must be runnable as-is.

Task description:
$desc
EOF
)

ai_dir=".ai"
out_file="$ai_dir/gemini.out"
err_file="$ai_dir/gemini.err"
mkdir -p "$ai_dir"

print_err_tail() {
  if [[ -f "$err_file" ]]; then
    tail -n 20 "$err_file" >&2 || true
  fi
}

if ! gemini "$prompt" >"$out_file" 2>"$err_file"; then
  echo "Gemini planning failed." >&2
  print_err_tail
  exit 1
fi

tmpfile=$(mktemp)
python3 - <<'PY' "$out_file" "$tmpfile"
import sys
from pathlib import Path

src, dst = sys.argv[1:3]
lines = Path(src).read_text().splitlines()
filtered = []
for line in lines:
    if line == 'Loaded cached credentials.':
        continue
    if line.startswith('(node:'):
        continue
    if 'DeprecationWarning' in line:
        continue
    filtered.append(line)

text = '\n'.join(filtered)
Path(dst).write_text((text + '\n') if text else '')
PY

if ! [ -s "$tmpfile" ]; then
  echo "Gemini returned empty output after filtering; SPEC.md not updated." >&2
  print_err_tail
  rm -f "$tmpfile"
  exit 1
fi

if ! grep -Fxq '## Acceptance checks' "$tmpfile"; then
  echo "SPEC.md missing required Acceptance checks header." >&2
  print_err_tail
  rm -f "$tmpfile"
  exit 1
fi

mv "$tmpfile" SPEC.md
echo "SPEC.md updated."
