#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/ai/spec_lint.sh [SPEC.md]

Validates that SPEC.md contains a runnable Acceptance checks section:
  1. SPEC file exists and is readable
  2. SPEC has a "## Acceptance checks" section (case-insensitive)
  3. Section exposes at least one runnable command inside fenced code blocks
  4. No empty commands (blank/comment lines are ignored)
USAGE
}

SPEC_PATH="SPEC.md"
if [[ $# -gt 1 ]]; then
  echo "Error: spec_lint accepts at most one argument" >&2
  usage
  exit 2
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      SPEC_PATH="$1"
      ;;
  esac
fi

if [[ ! -r "$SPEC_PATH" ]]; then
  echo "Spec lint failed: file not readable: $SPEC_PATH" >&2
  exit 2
fi

section_tmp=""
blocks_dir=""
block_tmp=""
cleanup() {
  [[ -n "$section_tmp" ]] && rm -f "$section_tmp"
  [[ -n "$block_tmp" ]] && rm -f "$block_tmp"
  [[ -n "$blocks_dir" ]] && rm -rf "$blocks_dir"
}
trap cleanup EXIT

section_tmp="$(mktemp)"

in_section=0
found_section=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lower="${line,,}"
  if [[ $in_section -eq 0 ]]; then
    if [[ "$lower" =~ ^##[[:space:]]+acceptance[[:space:]]+checks[[:space:]]*$ ]]; then
      in_section=1
      found_section=1
    fi
  else
    if [[ "$line" =~ ^##[[:space:]]+ ]]; then
      break
    fi
    printf '%s\n' "$line" >> "$section_tmp"
  fi
done < "$SPEC_PATH"

if [[ $found_section -eq 0 ]]; then
  echo "Spec lint failed: Missing '## Acceptance checks' section in $SPEC_PATH" >&2
  exit 1
fi

blocks_dir="$(mktemp -d)"
block_tmp="$(mktemp)"
: > "$block_tmp"
block_idx=0
block_files=()
in_fence=0

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ $in_fence -eq 0 ]]; then
    if [[ "$line" =~ ^[[:space:]]*\`\`\`([[:space:]]*(bash|sh))?[[:space:]]*$ ]]; then
      in_fence=1
      : > "$block_tmp"
    fi
  else
    if [[ "$line" =~ ^[[:space:]]*\`\`\`[[:space:]]*$ ]]; then
      in_fence=0
      block_idx=$((block_idx + 1))
      printf -v block_path "%s/block_%05d.txt" "$blocks_dir" "$block_idx"
      cp "$block_tmp" "$block_path"
      block_files+=("$block_path")
      : > "$block_tmp"
    else
      printf '%s\n' "$line" >> "$block_tmp"
    fi
  fi
done < "$section_tmp"

if [[ $in_fence -eq 1 ]]; then
  echo "Spec lint failed: Acceptance section contains an unclosed code fence" >&2
  exit 1
fi

normalize_block() {
  awk '
    BEGIN { min = -1 }
    { lines[NR] = $0 }
    $0 ~ /^[ \t]*$/ { next }
    {
      match($0, /^[ \t]*/)
      ind = RLENGTH
      if (min == -1 || ind < min) min = ind
    }
    END {
      for (i = 1; i <= NR; i++) {
        l = lines[i]
        if (min > 0) l = substr(l, min + 1)
        print l
      }
    }
  '
}

trim_line() {
  awk '{ sub(/^[ \t]+/, "", $0); sub(/[ \t]+$/, "", $0); print }'
}

commands_found=0

for block in "${block_files[@]}"; do
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    trimmed="$(printf '%s\n' "$raw" | trim_line)"
    if [[ -z "$trimmed" ]]; then
      continue
    fi
    if [[ "${trimmed:0:1}" == "#" ]]; then
      continue
    fi
    commands_found=$((commands_found + 1))
  done < <(normalize_block < "$block")
done

if [[ $commands_found -eq 0 ]]; then
  echo "Spec lint failed: No runnable commands found under Acceptance checks in $SPEC_PATH" >&2
  echo "Hint: add bash/sh fenced blocks with executable commands." >&2
  exit 1
fi

echo "Spec lint OK: $SPEC_PATH"
