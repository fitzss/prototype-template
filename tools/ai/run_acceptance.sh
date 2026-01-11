#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/ai/run_acceptance.sh [--dry-run] [--report-dir DIR] [--step-timeout-seconds N] [SPEC_PATH]

Behavior:
  - Finds the "Acceptance checks" section (case-insensitive) in SPEC markdown.
  - Extracts fenced code blocks (```bash / ```sh / ```).
  - Discovers runnable commands (non-empty, non-comment lines).
  - --dry-run prints discovered commands and exits 0 if any exist.
  - Executes acceptance commands sequentially; fails on first failing command.

Reporting:
  --report-dir DIR creates DIR/<run_id>/ containing:
    result.json (proof packet metadata)
    steps/NNN.cmd.txt, steps/NNN.stdout.log, steps/NNN.stderr.log for each command

Notes:
  - --step-timeout-seconds defaults to 180; enforced only if 'timeout' exists.
  - Fences may be indented (e.g., inside bullet lists); this runner still detects them.
  - If a fence is opened but never closed, this runner exits with a clear error.
USAGE
}

DRY_RUN=0
REPORT_DIR=""
SPEC="SPEC.md"
STEP_TIMEOUT_SECONDS=180

section_tmp=""
blocks_dir=""
block_tmp=""
discover_tmp=""

cleanup_tmp_files() {
  [[ -n "$section_tmp" ]] && rm -f "$section_tmp"
  [[ -n "$block_tmp" ]] && rm -f "$block_tmp"
  [[ -n "$discover_tmp" ]] && rm -f "$discover_tmp"
  [[ -n "$blocks_dir" ]] && rm -rf "$blocks_dir"
}

RESULT_PASS=true
RESULT_EXIT_CODE=0
RESULT_FAILING_STEP=""
RESULT_FAILING_COMMAND=""
RESULT_WRITTEN=0
LAST_COMMAND=""
LAST_STEP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --report-dir)
      if [[ $# -lt 2 ]]; then
        echo "Error: --report-dir requires a path argument" >&2
        exit 2
      fi
      REPORT_DIR="$2"
      shift 2
      ;;
    --step-timeout-seconds)
      if [[ $# -lt 2 ]]; then
        echo "Error: --step-timeout-seconds requires a value" >&2
        exit 2
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --step-timeout-seconds expects a positive integer" >&2
        exit 2
      fi
      STEP_TIMEOUT_SECONDS="$2"
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

if [[ ! -f "$SPEC" ]]; then
  echo "Error: Spec file not found: $SPEC" >&2
  exit 2
fi

# Extract "Acceptance checks" section (case-insensitive) until next '## ' heading or EOF.
section_tmp="$(mktemp)"

in_section=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lower="${line,,}"
  if [[ $in_section -eq 0 ]]; then
    # Start when we hit "## Acceptance checks" (any casing)
    if [[ "$lower" =~ ^##[[:space:]]+acceptance[[:space:]]+checks[[:space:]]*$ ]]; then
      in_section=1
    fi
  else
    # Stop at next markdown heading
    if [[ "$line" =~ ^##[[:space:]]+ ]]; then
      break
    fi
    printf '%s\n' "$line" >> "$section_tmp"
  fi
done < "$SPEC"

if [[ $in_section -eq 0 ]]; then
  echo "No acceptance checks found in $SPEC. (Missing '## Acceptance checks' section.)" >&2
  exit 1
fi

# Parse fenced blocks from the acceptance section.
# Fences can be indented; accept ```bash, ```sh, or plain ```.
blocks_dir="$(mktemp -d)"
block_idx=0
in_fence=0
block_tmp="$(mktemp)"
: > "$block_tmp"
block_files=()

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
  echo "Error: Unclosed code fence in Acceptance Checks section of $SPEC." >&2
  echo '       Make sure every opening ```bash has a closing ``` line.' >&2
  exit 1
fi

# Discover runnable command lines across all blocks
discover_tmp="$(mktemp)"
: > "$discover_tmp"

# Normalize indentation inside each block by removing the minimum common leading whitespace
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

trim() {
  # shell-safe trim via awk
  awk '{ sub(/^[ \t]+/, "", $0); sub(/[ \t]+$/, "", $0); print }'
}

for f in "${block_files[@]}"; do
  normalize_block < "$f" | while IFS= read -r raw || [[ -n "$raw" ]]; do
    t="$(printf '%s\n' "$raw" | trim)"
    [[ -z "$t" ]] && continue
    [[ "$t" == \#* ]] && continue
    printf '%s\n' "$t" >> "$discover_tmp"
  done
done

if [[ ! -s "$discover_tmp" ]]; then
  echo "No runnable acceptance commands found in $SPEC." >&2
  echo "Hint: Put runnable commands inside a fenced code block under the Acceptance checks section." >&2
  exit 1
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Discovered acceptance commands (in order):"
  nl -ba "$discover_tmp"
  exit 0
fi

mapfile -t COMMANDS < "$discover_tmp"

generate_run_id() {
  date -u +'%Y%m%dT%H%M%SZ'
}

now_ms() {
  if date +%s%3N >/dev/null 2>&1; then
    date +%s%3N
  else
    echo "$(($(date +%s) * 1000))"
  fi
}

json_escape() {
  local input="$1"
  input="${input//\\/\\\\}"
  input="${input//\"/\\\"}"
  input="${input//$'\n'/\\n}"
  input="${input//$'\r'/\\r}"
  input="${input//$'\t'/\\t}"
  printf '%s' "$input"
}

rel_path_for_json() {
  local path="$1"
  if [[ -z "$path" ]]; then
    printf ''
    return
  fi
  if [[ -n "$RUN_DIR" && "$path" == "$RUN_DIR"/* ]]; then
    printf '%s' "${path#"$RUN_DIR/"}"
    return
  fi
  printf '%s' "$path"
}

RUN_ID="$(generate_run_id)"
RUN_DIR=""
RESULT_PATH=""
STEPS_DIR=""
LATEST_FILE=""

if [[ -n "$REPORT_DIR" ]]; then
  mkdir -p "$REPORT_DIR"
  RUN_DIR="$REPORT_DIR/$RUN_ID"
  while [[ -e "$RUN_DIR" ]]; do
    sleep 1
    RUN_ID="$(generate_run_id)"
    RUN_DIR="$REPORT_DIR/$RUN_ID"
  done
  STEPS_DIR="$RUN_DIR/steps"
  mkdir -p "$STEPS_DIR"
  RESULT_PATH="$RUN_DIR/result.json"
  LATEST_FILE="$REPORT_DIR/latest_run"
  printf '%s\n' "$RUN_ID" > "$LATEST_FILE"
fi

HAS_TIMEOUT=0
if command -v timeout >/dev/null 2>&1; then
  HAS_TIMEOUT=1
fi

declare -a STEP_INDEXES=()
declare -a STEP_COMMANDS=()
declare -a STEP_STATUSES=()
declare -a STEP_EXIT_CODES=()
declare -a STEP_DURATIONS=()
declare -a STEP_CMD_PATHS=()
declare -a STEP_STDOUT_PATHS=()
declare -a STEP_STDERR_PATHS=()

write_result_json() {
  local pass_bool="$1"
  local exit_code="$2"
  local failing_step="$3"
  local failing_command="$4"
  if [[ -z "$RESULT_PATH" ]]; then
    return 0
  fi

  RESULT_WRITTEN=1

  local failing_step_json="null"
  if [[ -n "$failing_step" ]]; then
    failing_step_json="$failing_step"
  fi

  local failing_command_json="null"
  if [[ -n "$failing_command" ]]; then
    failing_command_json="\"$(json_escape "$failing_command")\""
  fi

  local status_text="PASS"
  if [[ "$pass_bool" != "true" ]]; then
    status_text="FAIL"
  fi

  {
    printf '{\n'
    printf '  "pass": %s,\n' "$pass_bool"
    printf '  "status": "%s",\n' "$status_text"
    printf '  "exit_code": %s,\n' "$exit_code"
    printf '  "run_id": "%s",\n' "$RUN_ID"
    printf '  "spec_path": "%s",\n' "$(json_escape "$SPEC")"
    printf '  "failing_step": %s,\n' "$failing_step_json"
    printf '  "failing_command": %s,\n' "$failing_command_json"
    printf '  "failed_command": %s,\n' "$failing_command_json"
    printf '  "steps": [\n'
    local total=${#STEP_INDEXES[@]}
    for ((i = 0; i < total; i++)); do
      local comma=','
      if (( i == total - 1 )); then
        comma=''
      fi
      local cmd="$(json_escape "${STEP_COMMANDS[$i]}")"
      local status="${STEP_STATUSES[$i]}"
      local exitc="${STEP_EXIT_CODES[$i]}"
      local duration="${STEP_DURATIONS[$i]}"
      local cmd_path="${STEP_CMD_PATHS[$i]}"
      local stdout_path="${STEP_STDOUT_PATHS[$i]}"
      local stderr_path="${STEP_STDERR_PATHS[$i]}"

      if [[ -z "$cmd_path" ]]; then
        cmd_path_json="null"
      else
        cmd_path_json="\"$(json_escape "$cmd_path")\""
      fi
      if [[ -z "$stdout_path" ]]; then
        stdout_path_json="null"
      else
        stdout_path_json="\"$(json_escape "$stdout_path")\""
      fi
      if [[ -z "$stderr_path" ]]; then
        stderr_path_json="null"
      else
        stderr_path_json="\"$(json_escape "$stderr_path")\""
      fi

      printf '    {"index": %s, "command": "%s", "status": "%s", "exit_code": %s, "duration_ms": %s, "cmd_path": %s, "stdout_path": %s, "stderr_path": %s}%s\n' \
        "${STEP_INDEXES[$i]}" "$cmd" "$status" "$exitc" "$duration" \
        "$cmd_path_json" "$stdout_path_json" "$stderr_path_json" "$comma"
    done
    printf '  ]\n'
    printf '}\n'
  } > "$RESULT_PATH"
}

on_exit() {
  local exit_status=$?
  trap - EXIT
  if [[ "$RESULT_PASS" == "true" && $exit_status -ne 0 ]]; then
    RESULT_PASS=false
    RESULT_EXIT_CODE=$exit_status
    if [[ -z "$RESULT_FAILING_STEP" && -n "$LAST_STEP" && "$LAST_STEP" -ne 0 ]]; then
      RESULT_FAILING_STEP="$LAST_STEP"
    fi
    if [[ -z "$RESULT_FAILING_COMMAND" && -n "$LAST_COMMAND" ]]; then
      RESULT_FAILING_COMMAND="$LAST_COMMAND"
    fi
  fi
  if [[ $RESULT_WRITTEN -eq 0 ]]; then
    write_result_json "$RESULT_PASS" "$RESULT_EXIT_CODE" "$RESULT_FAILING_STEP" "$RESULT_FAILING_COMMAND"
  fi
  cleanup_tmp_files
  exit $exit_status
}

trap on_exit EXIT

step_idx=0

for cmd in "${COMMANDS[@]}"; do
  step_idx=$((step_idx + 1))
  echo "running step $step_idx: $cmd"
  LAST_COMMAND="$cmd"
  LAST_STEP="$step_idx"
  local_label=$(printf '%03d' "$step_idx")

  cmd_path=""
  stdout_path=""
  stderr_path=""
  if [[ -n "$STEPS_DIR" ]]; then
    cmd_path="$STEPS_DIR/${local_label}.cmd.txt"
    stdout_path="$STEPS_DIR/${local_label}.stdout.log"
    stderr_path="$STEPS_DIR/${local_label}.stderr.log"
    printf '%s\n' "$cmd" > "$cmd_path"
  fi

  script_tmp="$(mktemp)"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -Eeuo pipefail'
    printf '%s\n' "$cmd"
  } > "$script_tmp"
  chmod +x "$script_tmp"

  start_ms=$(now_ms)
  if [[ -n "$stdout_path" ]]; then
    set +e
    if [[ $HAS_TIMEOUT -eq 1 ]]; then
      timeout "$STEP_TIMEOUT_SECONDS" "$script_tmp" > >(tee "$stdout_path") 2> >(tee "$stderr_path" >&2)
    else
      "$script_tmp" > >(tee "$stdout_path") 2> >(tee "$stderr_path" >&2)
    fi
    rc=${PIPESTATUS[0]}
    set -e
  else
    set +e
    if [[ $HAS_TIMEOUT -eq 1 ]]; then
      timeout "$STEP_TIMEOUT_SECONDS" "$script_tmp"
    else
      "$script_tmp"
    fi
    rc=$?
    set -e
  fi
  end_ms=$(now_ms)
  duration_ms=$((end_ms - start_ms))
  rm -f "$script_tmp"

  # status may be pass/fail/timeout; policy_denied reserved for future enforcement.
  status="pass"
  if [[ $rc -ne 0 ]]; then
    if [[ $HAS_TIMEOUT -eq 1 && $rc -eq 124 ]]; then
      status="timeout"
    else
      status="fail"
    fi
  fi

  rel_cmd_path="$(rel_path_for_json "$cmd_path")"
  rel_stdout_path="$(rel_path_for_json "$stdout_path")"
  rel_stderr_path="$(rel_path_for_json "$stderr_path")"

  STEP_INDEXES+=("$step_idx")
  STEP_COMMANDS+=("$cmd")
  STEP_STATUSES+=("$status")
  STEP_EXIT_CODES+=("$rc")
  STEP_DURATIONS+=("$duration_ms")
  STEP_CMD_PATHS+=("$rel_cmd_path")
  STEP_STDOUT_PATHS+=("$rel_stdout_path")
  STEP_STDERR_PATHS+=("$rel_stderr_path")

  if [[ $rc -ne 0 ]]; then
    RESULT_PASS=false
    RESULT_EXIT_CODE=$rc
    RESULT_FAILING_STEP="$step_idx"
    RESULT_FAILING_COMMAND="$cmd"
    echo "step $step_idx failed: $cmd (exit $rc)" >&2
    if [[ -n "$stdout_path" ]]; then
      echo "Logs: STDOUT=$stdout_path STDERR=$stderr_path" >&2
    fi
    break
  fi
done

if [[ "$RESULT_PASS" == "true" ]]; then
  write_result_json true 0 "" ""
  if [[ -n "$RUN_DIR" ]]; then
    echo "Proof packet saved to $RUN_DIR"
  fi
  echo "Acceptance: PASS"
  exit 0
else
  write_result_json false "$RESULT_EXIT_CODE" "$RESULT_FAILING_STEP" "$RESULT_FAILING_COMMAND"
  if [[ -n "$RUN_DIR" ]]; then
    echo "Proof packet saved to $RUN_DIR" >&2
  fi
  echo "Acceptance: FAIL" >&2
  echo "Failing command: $RESULT_FAILING_COMMAND" >&2
  exit "$RESULT_EXIT_CODE"
fi
