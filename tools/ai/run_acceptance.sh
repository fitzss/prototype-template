#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tools/ai/run_acceptance.sh [--dry-run] [--report-dir <path>] [SPEC.md]

Parses the "## Acceptance checks" section of the spec and runs each command
line-by-line, stopping at the first failure. Use --dry-run to print commands
without executing them. Use --report-dir to tee command output into
<path>/acceptance.log and write <path>/result.json.
EOF
}

json_escape() {
  local str="$1"
  str=${str//\\/\\\\}
  str=${str//\"/\\\"}
  str=${str//$'\b'/\\b}
  str=${str//$'\f'/\\f}
  str=${str//$'\n'/\\n}
  str=${str//$'\r'/\\r}
  str=${str//$'\t'/\\t}
  printf '%s' "$str"
}

write_result_file() {
  local status="$1"
  local failed_command="$2"
  if [[ -z "$RESULT_JSON" ]]; then
    return
  fi

  local failed_value="null"
  if [[ -n "$failed_command" ]]; then
    local escaped
    escaped=$(json_escape "$failed_command")
    failed_value="\"$escaped\""
  fi

  printf '{"status":"%s","failed_command":%s}\n' "$status" "$failed_value" > "$RESULT_JSON"
}

log_running() {
  local message="$1"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$message" | tee -a "$LOG_FILE"
  else
    printf '%s\n' "$message"
  fi
}

DRY_RUN=0
SPEC="SPEC.md"
REPORT_DIR=""
LOG_FILE=""
RESULT_JSON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --report-dir)
      if [[ $# -lt 2 ]]; then
        echo "--report-dir requires a path argument" >&2
        exit 1
      fi
      REPORT_DIR="$2"
      shift 2
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

if [[ -n "$REPORT_DIR" ]]; then
  mkdir -p "$REPORT_DIR"
  LOG_FILE="$REPORT_DIR/acceptance.log"
  RESULT_JSON="$REPORT_DIR/result.json"
fi

if [ ! -f "$SPEC" ]; then
  echo "Spec file '$SPEC' not found." >&2
  write_result_file "fail" ""
  exit 1
fi

commands=$(awk '/^##[[:space:]]+Acceptance[[:space:]]+checks$/{flag=1;next}/^##[[:space:]]+/{if(flag)exit}flag' "$SPEC")
if [ -z "$commands" ]; then
  echo "No acceptance checks found in $SPEC." >&2
  write_result_file "fail" ""
  exit 1
fi

STATUS=0
FAILED_COMMAND=""
in_code_block=0
discovered_count=0
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

  discovered_count=$((discovered_count + 1))
  log_running "Running: $trimmed"
  if [ "$DRY_RUN" -eq 1 ]; then
    continue
  fi

  if [[ -n "$LOG_FILE" ]]; then
    if ! bash -lc "$trimmed" 2>&1 | tee -a "$LOG_FILE"; then
      echo "Acceptance check failed: $trimmed" >&2
      STATUS=1
      FAILED_COMMAND="$trimmed"
      break
    fi
  else
    if ! bash -lc "$trimmed"; then
      echo "Acceptance check failed: $trimmed" >&2
      STATUS=1
      FAILED_COMMAND="$trimmed"
      break
    fi
  fi

done <<< "$commands"

if [ "$discovered_count" -eq 0 ]; then
  echo 'Error: No acceptance commands found. Check SPEC.md formatting.' >&2
  write_result_file "fail" ""
  exit 1
fi

if [ "$STATUS" -eq 0 ]; then
  write_result_file "pass" ""
else
  write_result_file "fail" "$FAILED_COMMAND"
fi

exit $STATUS
