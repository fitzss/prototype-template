#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT_DIR/tools/ai/run_acceptance.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

# Spec A: exact-case header, top-level fence
spec_a="$tmp_dir/spec_a.md"
cat > "$spec_a" <<'EOF'
# Spec A

## Acceptance Checks

```bash
echo top_a
```
EOF

# Spec B: lowercase "checks" with indented fence inside a bullet list
spec_b="$tmp_dir/spec_b.md"
cat > "$spec_b" <<'EOF'
# Spec B

## Acceptance checks
- Steps:
  ```bash
  echo bullet_b
  ```
EOF

# Spec C: fully lowercase header + plain fence without language tag
spec_c="$tmp_dir/spec_c.md"
cat > "$spec_c" <<'EOF'
# Spec C

## acceptance checks

```
echo lowercase_c
```
EOF

run_case() {
  local label="$1"
  local spec_path="$2"
  local expected="$3"

  if ! output="$("$RUNNER" --dry-run "$spec_path" 2>&1)"; then
    echo "FAIL [$label] --dry-run exited non-zero" >&2
    echo "$output" >&2
    exit 1
  fi

  if ! grep -q "$expected" <<<"$output"; then
    echo "FAIL [$label] expected to find command '$expected' in output" >&2
    echo "$output" >&2
    exit 1
  fi

  echo "PASS [$label] parser found runnable command"
}

run_case "spec_a" "$spec_a" "echo top_a"
run_case "spec_b" "$spec_b" "echo bullet_b"
run_case "spec_c" "$spec_c" "echo lowercase_c"

echo "Parser coverage OK"
