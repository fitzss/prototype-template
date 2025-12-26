#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tools/ai/run_acceptance.sh [--dry-run] [SPEC.md]

Parses the "## Acceptance checks" section of the spec and runs each command
line-by-line, stopping at the first failure. Use --dry-run to print commands
without executing them.
EOF
}

DRY_RUN=0
SPEC="SPEC.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      SPEC="$1"
      shift
      ;;
  esac
done

if [ ! -f "$SPEC" ]; then
  echo "Spec file '$SPEC' not found." >&2
  exit 1
fi

commands=$(awk '/^##[[:space:]]+Acceptance[[:space:]]+checks$/{flag=1;next}/^##[[:space:]]+/{if(flag)exit}flag' "$SPEC")
if [ -z "$commands" ]; then
  echo "No acceptance checks found in $SPEC." >&2
  exit 1
fi

STATUS=0
in_code_block=0
command_count=0
while IFS= read -r line; do
  clean_line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//')

  if [[ ${clean_line:0:3} == '```' ]]; then
    if [ "$in_code_block" -eq 0 ]; then
      in_code_block=1
    else
      in_code_block=0
    fi
    continue
  fi

  if [ "$in_code_block" -eq 0 ]; then
    continue
  fi

  trimmed=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  [ -z "$trimmed" ] && continue

  echo "Running: $trimmed"
  command_count=$((command_count + 1))
  if [ "$DRY_RUN" -eq 1 ]; then
    continue
  fi
  if ! bash -lc "$trimmed"; then
    echo "Acceptance check failed: $trimmed" >&2
    STATUS=1
    break
  fi

done <<< "$commands"

if [ "$command_count" -eq 0 ]; then
  echo 'Error: No acceptance commands found. Check SPEC.md formatting.' >&2
  exit 1
fi

exit $STATUS
