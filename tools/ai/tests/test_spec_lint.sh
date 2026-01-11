#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LINTER="$ROOT_DIR/tools/ai/spec_lint.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

expect_fail() {
  local label="$1"
  local spec_path="$2"
  local needle="$3"

  set +e
  output="$("$LINTER" "$spec_path" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    echo "FAIL [$label] expected linter to fail" >&2
    echo "$output" >&2
    exit 1
  fi
  if [[ -n "$needle" ]] && ! grep -qi "$needle" <<<"$output"; then
    echo "FAIL [$label] expected message containing '$needle'" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "PASS [$label] failed as expected"
}

expect_pass() {
  local label="$1"
  local spec_path="$2"
  if ! "$LINTER" "$spec_path" >/dev/null; then
    echo "FAIL [$label] expected lint to pass" >&2
    exit 1
  fi
  echo "PASS [$label] lint succeeded"
}

# Missing acceptance section
spec_missing="$tmp_dir/spec_missing.md"
cat > "$spec_missing" <<'EOF_MISSING'
# Sample Spec

## Overview
Nothing to lint.
EOF_MISSING
expect_fail "missing_section" "$spec_missing" "missing '## acceptance checks'"

# Acceptance section but no runnable commands
spec_empty="$tmp_dir/spec_empty.md"
cat > "$spec_empty" <<'EOF_EMPTY'
# Spec Empty

## Acceptance checks

```bash
# comment describing steps
   # another comment
```
EOF_EMPTY
expect_fail "no_commands" "$spec_empty" "No runnable commands"

# Valid spec
spec_valid="$tmp_dir/spec_valid.md"
cat > "$spec_valid" <<'EOF_VALID'
# Spec Valid

## acceptance CHECKS

```sh
 echo ok
```
EOF_VALID
expect_pass "valid_spec" "$spec_valid"

echo "Spec lint tests OK"
