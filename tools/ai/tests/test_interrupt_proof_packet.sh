#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT_DIR/tools/ai/run_acceptance.sh"

tmp_spec="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_spec"
}
trap cleanup EXIT

spec_path="$tmp_spec/spec.md"
cat > "$spec_path" <<'EOF_SPEC'
## Acceptance Checks
```bash
sleep 20
echo should_not_run
```
EOF_SPEC

reports="$(mktemp -d)"
trap 'cleanup; rm -rf "$reports"' EXIT

rm -rf "$reports" && mkdir -p "$reports"
"$RUNNER" --report-dir "$reports" --allow-exe sleep "$spec_path" &
runner_pid=$!

run_id=""
for _ in {1..20}; do
  if [[ -f "$reports/latest_run" ]]; then
    run_id=$(cat "$reports/latest_run")
    if [[ -n "$run_id" && -d "$reports/$run_id" ]]; then
      break
    fi
  fi
  sleep 0.2
done
if [[ -z "$run_id" ]]; then
  echo "FAIL: runner did not create latest_run in time" >&2
  kill "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || true
  exit 1
fi

for _ in {1..20}; do
  if [[ -f "$reports/$run_id/steps/001.cmd.txt" ]]; then
    break
  fi
  sleep 0.2
  if ! kill -0 "$runner_pid" 2>/dev/null; then
    echo "FAIL: runner exited before step registration" >&2
    exit 1
  fi
done

kill -TERM "$runner_pid" 2>/dev/null || true
wait "$runner_pid" 2>/dev/null || true

result_json="$reports/$run_id/result.json"
if [[ ! -f "$result_json" ]]; then
  echo "FAIL: result.json missing after SIGTERM" >&2
  exit 1
fi

python3 - <<'PY' "$result_json"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
assert data["pass"] is False
steps = data["steps"]
assert len(steps) == 1
step = steps[0]
assert step["index"] == 1
assert step["command"] == "sleep 20"
assert step["status"] == "fail"
assert step["exit_code"] in (143, "143")
assert data["failing_command"] == "sleep 20"
PY

if grep -q "should_not_run" "$reports/$run_id/steps"/001.stdout.log; then
  echo "FAIL: second command appears to have run" >&2
  exit 1
fi

echo "Interrupt proof packet test OK"
