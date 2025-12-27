#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "Preflight check failed: $*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  local description="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "$description ('$cmd') is required but not installed."
  fi
}

PORT="${PREFLIGHT_PORT:-8080}"
if [[ -z "$PORT" ]]; then
  fail "PREFLIGHT_PORT cannot be empty when set."
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  fail "Port value '$PORT' is not a valid number."
fi
if (( PORT < 1 || PORT > 65535 )); then
  fail "Port $PORT is outside the allowed range 1-65535."
fi

require_cmd docker "Docker CLI"
require_cmd curl "curl"

if ! docker info >/dev/null 2>&1; then
  if ! docker version >/dev/null 2>&1; then
    fail "Docker daemon is not reachable. Ensure Docker Desktop or dockerd is running."
  fi
fi

COMPOSE_CMD=
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  if ! docker-compose version >/dev/null 2>&1; then
    fail "docker-compose command exists but failed to run 'docker-compose version'."
  fi
  COMPOSE_CMD="docker-compose"
else
  fail "Docker Compose is required (either 'docker compose' or 'docker-compose')."
fi

check_port() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      fail "Port $port is already in use. Set PREFLIGHT_PORT to override."
    fi
    return
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -E "[.:]${port}$" >/dev/null 2>&1; then
      fail "Port $port is already in use. Set PREFLIGHT_PORT to override."
    fi
    return
  fi

  local python_cmd=""
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
      python_cmd="$candidate"
      break
    fi
  done

  if [[ -z "$python_cmd" ]]; then
    fail "Cannot verify port $port: install lsof, ss, or python."
  fi

  if ! "$python_cmd" - <<PY
import socket
import sys
port = int("$port")
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", port))
    except OSError:
        sys.exit(1)
sys.exit(0)
PY
  then
    fail "Port $port is already in use. Set PREFLIGHT_PORT to override."
  fi
}

check_port "$PORT"

echo "Preflight OK: Docker, Docker Compose (${COMPOSE_CMD}), curl, and port $PORT are ready."
