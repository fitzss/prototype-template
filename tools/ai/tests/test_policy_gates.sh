#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT_DIR/tools/ai/run_acceptance.sh"

if ! command -v sudo >/dev/null 2>&1; then
  echo "SKIP: sudo not available"
  exit 0
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

spec_path="$tmp_dir/spec_policy.md"
cat > "$spec_path" <<'EOF_SPEC'
# Policy Spec

## Acceptance checks

```bash
echo ok
sudo -n echo hi
```
EOF_SPEC

reports="$tmp_dir/reports"
set +e
"$RUNNER" --report-dir "$reports" "$spec_path" >/dev/null
status=$?
set -e
if [[ $status -eq 0 ]]; then
  echo "FAIL: policy enforcement expected to fail" >&2
  exit 1
fi

run_dir="$(find "$reports" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ -z "$run_dir" ]]; then
  echo "FAIL: no run directory created" >&2
  exit 1
fi

result_json="$run_dir/result.json"
if [[ ! -f "$result_json" ]]; then
  echo "FAIL: missing result.json"
  exit 1
fi

python3 - <<'PY' "$result_json"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
assert data["pass"] is False
assert data["failing_command"] == "sudo -n echo hi"
assert any(step["status"] == "policy_denied" for step in data["steps"])
PY

policy_step="$(python3 - <<'PY' "$result_json"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
for step in data["steps"]:
    if step["status"] == "policy_denied":
        print(step["index"])
        break
else:
    raise SystemExit("no policy-denied step")
PY
)"
stderr_path="$run_dir/steps/$(printf '%03d' "$policy_step").stderr.log"
if [[ ! -f "$stderr_path" ]]; then
  echo "FAIL: missing policy stderr log" >&2
  exit 1
fi
if ! grep -q "policy denied: sudo" "$stderr_path"; then
  echo "FAIL: stderr missing policy denied message" >&2
  exit 1
fi

off_reports="$tmp_dir/reports_off"
set +e
"$RUNNER" --policy-mode=off --report-dir "$off_reports" "$spec_path" >/dev/null
status_off=$?
set -e
if [[ $status_off -eq 0 ]]; then
  echo "NOTE: policy off run exited 0"
fi
run_dir_off="$(find "$off_reports" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ -z "$run_dir_off" ]]; then
  echo "FAIL: no run dir for policy-mode=off" >&2
  exit 1
fi
result_json_off="$run_dir_off/result.json"
python3 - <<'PY' "$result_json_off"
import json, sys
path = sys.argv[1]
data = json.load(open(path))
assert all(step["status"] != "policy_denied" for step in data["steps"])
PY

echo "Policy gate tests OK"
