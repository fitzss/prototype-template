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

TIMEOUT_BIN=$(command -v timeout || true)

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

write_telemetry_files() {
  if [[ -z "$REPORT_DIR" ]]; then
    return
  fi

  local telemetry_json
  telemetry_json=$(printf '{"commands_discovered":%d,"commands_executed":%d,"flaky_commands_executed":%d,"total_retry_attempts":%d,"retries_used":%d}\n' \
    "$commands_discovered" "$commands_executed" "$flaky_commands_executed" "$total_retry_attempts" "$retries_used")
  printf '%s' "$telemetry_json" > "$REPORT_DIR/telemetry.json"

  local summary_file="$REPORT_DIR/summary.md"
  if [[ -f "$summary_file" ]]; then
    {
      printf '\nAcceptance Telemetry:\n'
      printf -- '- commands_discovered: %s\n' "$commands_discovered"
      printf -- '- commands_executed: %s\n' "$commands_executed"
      printf -- '- flaky_commands_executed: %s\n' "$flaky_commands_executed"
      printf -- '- total_retry_attempts: %s\n' "$total_retry_attempts"
      printf -- '- retries_used: %s\n' "$retries_used"
    } >> "$summary_file"
  fi
}

set_deterministic_directive() {
  CURRENT_MODE="deterministic"
  CURRENT_RETRIES=1
  CURRENT_TIMEOUT=""
  CURRENT_ALLOW_EXIT_CODES="0"
  CURRENT_ALLOW_OUTPUT_REGEX=""
}

set_flaky_defaults() {
  CURRENT_MODE="flaky"
  CURRENT_RETRIES=3
  CURRENT_TIMEOUT=""
  CURRENT_ALLOW_EXIT_CODES="0"
  CURRENT_ALLOW_OUTPUT_REGEX=""
}

apply_directive_line() {
  local content="$1"
  content=$(printf '%s' "$content" | sed -E 's/^[[:space:]]+//')
  [ -z "$content" ] && { set_deterministic_directive; return; }

  local directive rest
  read -r directive rest <<< "$content"
  case "$directive" in
    deterministic)
      set_deterministic_directive
      ;;
    flaky)
      set_flaky_defaults
      if [[ -n "$rest" ]]; then
        read -ra tokens <<< "$rest"
        for token in "${tokens[@]}"; do
          case "$token" in
            retries=*)
              local value="${token#retries=}"
              if [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1 ]]; then
                CURRENT_RETRIES="$value"
              fi
              ;;
            timeout=*)
              local value="${token#timeout=}"
              if [[ "$value" =~ ^[0-9]+$ && "$value" -ge 1 ]]; then
                CURRENT_TIMEOUT="$value"
              fi
              ;;
            allow_exit_codes=*)
              CURRENT_ALLOW_EXIT_CODES="${token#allow_exit_codes=}"
              ;;
            allow_output_regex=*)
              CURRENT_ALLOW_OUTPUT_REGEX="${token#allow_output_regex=}"
              ;;
          esac
        done
      fi
      ;;
    *)
      echo "Warning: Unknown directive '$directive'. Falling back to deterministic." >&2
      set_deterministic_directive
      ;;
  esac
}

exit_code_allowed() {
  local exit_code="$1"
  local allow_list="$2"
  local normalized="${allow_list//[[:space:]]/}"
  IFS=',' read -ra codes <<< "$normalized"
  for allowed in "${codes[@]}"; do
    [[ -z "$allowed" ]] && continue
    if [[ "$allowed" == "$exit_code" ]]; then
      return 0
    fi
  done
  return 1
}

execute_command() {
  local command="$1"
  local mode="$2"
  local retries="$3"
  local timeout="$4"
  local allow_codes="$5"
  local output_regex="$6"

  local max_attempts=1
  local warn_timeout_once=0
  if [[ "$mode" == "flaky" ]]; then
    max_attempts="$retries"
    ((flaky_commands_executed++))
  fi

  local attempt=1
  while [[ $attempt -le $max_attempts ]]; do
    if [[ "$mode" == "flaky" ]]; then
      ((total_retry_attempts++))
      if [[ $attempt -gt 1 ]]; then
        ((retries_used++))
      fi
    fi

    local tmp_file
    tmp_file=$(mktemp)

    local exit_code=0
    local cmd=("bash" "-lc" "$command")
    if [[ "$mode" == "flaky" && -n "$timeout" ]]; then
      if [[ -n "$TIMEOUT_BIN" ]]; then
        cmd=("$TIMEOUT_BIN" "${timeout}s" "bash" "-lc" "$command")
      else
        if [[ $warn_timeout_once -eq 0 ]]; then
          echo "Warning: 'timeout' command not available; running without timeout for: $command" >&2
          warn_timeout_once=1
        fi
      fi
    fi

    if [[ -n "$LOG_FILE" ]]; then
      if ! "${cmd[@]}" 2>&1 | tee >(cat >> "$LOG_FILE") | tee "$tmp_file"; then
        exit_code=$?
      else
        exit_code=0
      fi
    else
      if ! "${cmd[@]}" 2>&1 | tee "$tmp_file"; then
        exit_code=$?
      else
        exit_code=0
      fi
    fi

    local output
    output=$(cat "$tmp_file")
    rm -f "$tmp_file"

    local exit_ok=0
    if exit_code_allowed "$exit_code" "$allow_codes"; then
      exit_ok=1
    fi

    local regex_ok=1
    if [[ -n "$output_regex" ]]; then
      if ! grep -Eq "$output_regex" <<< "$output"; then
        regex_ok=0
      fi
    fi

    if [[ $exit_ok -eq 1 && $regex_ok -eq 1 ]]; then
      return 0
    fi

    if [[ $exit_ok -eq 0 ]]; then
      echo "Command exited with disallowed code $exit_code" >&2
    elif [[ $regex_ok -eq 0 ]]; then
      echo "Command output did not match regex: $output_regex" >&2
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      log_running "Retrying ($((attempt + 1))/$max_attempts): $command"
    fi

    attempt=$((attempt + 1))
  done

  return 1
}

DRY_RUN=0
SPEC="SPEC.md"
REPORT_DIR=""
LOG_FILE=""
RESULT_JSON=""

commands_discovered=0
commands_executed=0
flaky_commands_executed=0
total_retry_attempts=0
retries_used=0

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
  write_telemetry_files
  exit 1
fi

commands=$(awk '/^##[[:space:]]+Acceptance[[:space:]]+checks$/{flag=1;next}/^##[[:space:]]+/{if(flag)exit}flag' "$SPEC")
if [ -z "$commands" ]; then
  echo "No acceptance checks found in $SPEC." >&2
  write_result_file "fail" ""
  write_telemetry_files
  exit 1
fi

STATUS=0
FAILED_COMMAND=""
in_code_block=0
set_deterministic_directive
while IFS= read -r line; do
  clean_line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//')

  if [[ ${clean_line:0:3} == '```' ]]; then
    if [ "$in_code_block" -eq 0 ]; then
      in_code_block=1
      set_deterministic_directive
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

  if [[ "$trimmed" == \#@* ]]; then
    directive_line="${trimmed#\#@}"
    apply_directive_line "$directive_line"
    continue
  fi

  commands_discovered=$((commands_discovered + 1))
  log_running "Running: $trimmed"
  if [ "$DRY_RUN" -eq 1 ]; then
    continue
  fi

  commands_executed=$((commands_executed + 1))
  if ! execute_command "$trimmed" "$CURRENT_MODE" "$CURRENT_RETRIES" "$CURRENT_TIMEOUT" "$CURRENT_ALLOW_EXIT_CODES" "$CURRENT_ALLOW_OUTPUT_REGEX"; then
    echo "Acceptance check failed: $trimmed" >&2
    STATUS=1
    FAILED_COMMAND="$trimmed"
    break
  fi

done <<< "$commands"

if [ "$commands_discovered" -eq 0 ]; then
  echo 'Error: No acceptance commands found. Check SPEC.md formatting.' >&2
  write_result_file "fail" ""
  write_telemetry_files
  exit 1
fi

if [ "$STATUS" -eq 0 ]; then
  write_result_file "pass" ""
else
  write_result_file "fail" "$FAILED_COMMAND"
fi

write_telemetry_files

exit $STATUS
