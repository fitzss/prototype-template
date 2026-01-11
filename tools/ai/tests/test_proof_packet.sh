#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT_DIR/tools/ai/run_acceptance.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Expected file missing: $1" >&2
    exit 1
  fi
}

# --- Success case ---
spec_success="$tmp_dir/spec_success.md"
cat > "$spec_success" <<'EOF_SPEC1'
# Spec Success

## Acceptance checks

```bash
echo alpha
echo beta
```
EOF_SPEC1

reports_success="$tmp_dir/reports_success"
"$RUNNER" --report-dir "$reports_success" "$spec_success" >/dev/null

run_dir_success="$(find "$reports_success" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ -z "$run_dir_success" ]]; then
  echo "No proof packet directory created for success case" >&2
  exit 1
fi

require_file "$run_dir_success/result.json"
require_file "$run_dir_success/steps/001.cmd.txt"
require_file "$run_dir_success/steps/001.stdout.log"
require_file "$run_dir_success/steps/001.stderr.log"
require_file "$run_dir_success/steps/002.cmd.txt"

python3 - <<'PY' "$run_dir_success/result.json" "$run_dir_success"
import json, sys, pathlib
result_path, run_dir = sys.argv[1:3]
data = json.load(open(result_path))
run_id = pathlib.Path(run_dir).name
assert data["pass"] is True
assert data["run_id"] == run_id
assert len(data["steps"]) == 2
for idx, step in enumerate(data["steps"], start=1):
    assert step["index"] == idx
    assert step["status"] == "pass"
    for key, suffix in ("cmd_path", f"{idx:03d}.cmd.txt"), ("stdout_path", f"{idx:03d}.stdout.log"), ("stderr_path", f"{idx:03d}.stderr.log"):
        val = step[key]
        assert val.startswith("steps/")
        assert not val.startswith(run_dir)
        assert val.endswith(suffix)
PY

# --- Failure case ---
spec_fail="$tmp_dir/spec_fail.md"
cat > "$spec_fail" <<'EOF_SPEC2'
# Spec Failure

## Acceptance checks

```bash
echo start
bash -c "echo FAIL >&2; exit 7"
echo unreachable
```
EOF_SPEC2

reports_fail="$tmp_dir/reports_fail"
set +e
"$RUNNER" --report-dir "$reports_fail" "$spec_fail" >/dev/null
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
  echo "Failure case unexpectedly passed" >&2
  exit 1
fi

run_dir_fail="$(find "$reports_fail" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
require_file "$run_dir_fail/result.json"
python3 - <<'PY' "$run_dir_fail/result.json"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
assert data["pass"] is False
assert data["exit_code"] == 7
assert data["failing_step"] == 2
assert data["failing_command"] == 'bash -c "echo FAIL >&2; exit 7"'
assert len(data["steps"]) == 2
assert data["steps"][1]["status"] == "fail"
assert data["steps"][0]["status"] == "pass"
PY

# --- Timeout case (if timeout available) ---
if command -v timeout >/dev/null 2>&1; then
  spec_timeout="$tmp_dir/spec_timeout.md"
  cat > "$spec_timeout" <<'EOF_SPEC3'
# Spec Timeout

## Acceptance checks

```bash
sleep 2
```
EOF_SPEC3
  reports_timeout="$tmp_dir/reports_timeout"
  set +e
  "$RUNNER" --report-dir "$reports_timeout" --step-timeout-seconds 1 "$spec_timeout" >/dev/null
  timeout_rc=$?
  set -e
  if [[ $timeout_rc -ne 124 ]]; then
    echo "Timeout test expected exit 124, got $timeout_rc" >&2
    exit 1
  fi
  run_dir_timeout="$(find "$reports_timeout" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  require_file "$run_dir_timeout/result.json"
  python3 - <<'PY' "$run_dir_timeout/result.json"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
assert data["pass"] is False
assert data["exit_code"] == 124
assert data["steps"][0]["status"] == "timeout"
PY
else
  echo "SKIP timeout classification test: 'timeout' binary not available"
fi

# --- Forced termination case ---
spec_early="$tmp_dir/spec_early_exit.md"
cat > "$spec_early" <<'EOF_SPEC4'
# Spec Early Exit

## Acceptance checks

```bash
bash -c "kill -TERM $PPID; sleep 0.1"
echo should_not_run
```
EOF_SPEC4

reports_early="$tmp_dir/reports_early"
set +e
"$RUNNER" --report-dir "$reports_early" "$spec_early" >/dev/null
early_rc=$?
set -e
if [[ $early_rc -eq 0 ]]; then
  echo "Early-exit case unexpectedly passed" >&2
  exit 1
fi
run_dir_early="$(find "$reports_early" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
require_file "$run_dir_early/result.json"
python3 - <<'PY' "$run_dir_early/result.json"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
assert data["pass"] is False
assert data["failing_step"] == 1
assert data["failing_command"] == 'bash -c "kill -TERM $PPID; sleep 0.1"'
PY

echo "Proof packet tests OK"
