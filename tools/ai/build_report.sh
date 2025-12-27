#!/usr/bin/env bash
set -euo pipefail

SPEC_PATH="${1:-SPEC.md}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
cd "$REPO_ROOT"

if [ ! -f "$SPEC_PATH" ]; then
  echo "Spec file '$SPEC_PATH' not found." >&2
  exit 1
fi

TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
REPORT_DIR="$REPO_ROOT/build_reports/$TIMESTAMP"
mkdir -p "$REPORT_DIR"

printf '%s\n' "$SPEC_PATH" > "$REPORT_DIR/spec_path.txt"
sha256sum "$SPEC_PATH" | awk '{print $1}' > "$REPORT_DIR/spec_sha256.txt"
git rev-parse HEAD > "$REPORT_DIR/git_head.txt"
git status --porcelain > "$REPORT_DIR/git_status.txt"
git diff > "$REPORT_DIR/git_diff.patch"

{
  echo "uname -a"
  if ! uname -a; then
    echo "uname command failed"
  fi
  echo

  echo "docker version"
  if command -v docker >/dev/null 2>&1; then
    if ! docker version; then
      echo "docker version command failed"
    fi
  else
    echo "docker command not found"
  fi
  echo

  echo "docker compose version"
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      docker compose version || true
    else
      echo "docker compose command not available"
    fi
  else
    echo "docker command not found"
  fi
  echo

  echo "docker-compose version"
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose version || true
  else
    echo "docker-compose command not found"
  fi
  echo

  echo "date"
  date -u
} > "$REPORT_DIR/env.txt"

ACCEPTANCE_STATUS=0
if ! "$SCRIPT_DIR/run_acceptance.sh" --report-dir "$REPORT_DIR" "$SPEC_PATH"; then
  ACCEPTANCE_STATUS=$?
fi

RESULT_JSON="$REPORT_DIR/result.json"
SUMMARY_STATUS="UNKNOWN"
FAILED_COMMAND_TEXT=""
if [ -f "$RESULT_JSON" ]; then
  STATUS_VALUE=$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$RESULT_JSON")
  if [ -n "$STATUS_VALUE" ]; then
    SUMMARY_STATUS=${STATUS_VALUE^^}
  fi
  FAILED_RAW=$(sed -n 's/.*"failed_command":\(null\|".*"\).*/\1/p' "$RESULT_JSON")
  if [ -n "$FAILED_RAW" ] && [ "$FAILED_RAW" != "null" ]; then
    FAILED_TRIM="${FAILED_RAW#\"}"
    FAILED_TRIM="${FAILED_TRIM%\"}"
    FAILED_TRIM="${FAILED_TRIM//\\\"/\"}"
    SAFE_TRIM="${FAILED_TRIM//%/%%}"
    printf -v FAILED_COMMAND_TEXT '%b' "$SAFE_TRIM"
  fi
else
  SUMMARY_STATUS=$([ "$ACCEPTANCE_STATUS" -eq 0 ] && echo PASS || echo FAIL)
fi

SUMMARY_FILE="$REPORT_DIR/summary.md"
{
  printf 'Spec: %s\n' "$SPEC_PATH"
  printf 'Status: %s\n' "$SUMMARY_STATUS"
  if [ -n "$FAILED_COMMAND_TEXT" ]; then
    printf 'Failed command:\n'
    printf '```\n%s\n```\n' "$FAILED_COMMAND_TEXT"
  fi
} > "$SUMMARY_FILE"

exit $ACCEPTANCE_STATUS
