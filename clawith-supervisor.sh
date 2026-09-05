#!/usr/bin/env bash
#
# Clawith supervisor lifecycle script.
#
# Run as a foreground program from Supervisor. Supervisor tracks this process
# and delivers SIGTERM when the service is stopped.
#
#   clawith-supervisor.sh            backend + frontend
#   clawith-supervisor.sh backend    backend only
#   clawith-supervisor.sh frontend   frontend only
#
# Do not daemonize, nohup, or fork into the background from this script.
#
set -euo pipefail

CLAWITH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_child_pids=()

log() {
    printf '[clawith-supervisor] %s\n' "$*"
}

load_env() {
    if [[ -f "$CLAWITH_ROOT/.env" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$CLAWITH_ROOT/.env"
        set +a
    fi

    : "${DATABASE_URL:=postgresql+asyncpg://clawith:clawith@localhost:5432/clawith?ssl=disable}"
    export DATABASE_URL
    : "${BACKEND_PORT:=8008}"
    export BACKEND_PORT
    : "${FRONTEND_PORT:=3008}"
    export FRONTEND_PORT
    : "${PUBLIC_BASE_URL:=}"
    export PUBLIC_BASE_URL
    : "${AGENT_RUNTIME_V2_ENABLED:=true}"
    export AGENT_RUNTIME_V2_ENABLED
    : "${AGENT_RUNTIME_V2_AGENT_IDS:=}"
    export AGENT_RUNTIME_V2_AGENT_IDS
    : "${AGENT_RUNTIME_V2_SOURCE_TYPES:=}"
    export AGENT_RUNTIME_V2_SOURCE_TYPES
}

stop_children() {
    local pid
    for pid in "${_child_pids[@]}"; do
        if [[ -n "$pid" ]]; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    for pid in "${_child_pids[@]}"; do
        if [[ -n "$pid" ]]; then
            wait "$pid" 2>/dev/null || true
        fi
    done
}

cleanup() {
    trap - TERM INT
    stop_children
    exit 0
}

trap cleanup TERM INT

run_backend() {
    load_env

    cd "$CLAWITH_ROOT/backend"
    if [[ ! -x .venv/bin/alembic ]]; then
        log "backend/.venv is not ready; run bash setup.sh first" >&2
        exit 1
    fi

    log "running Alembic migrations"
    .venv/bin/alembic upgrade head

    log "running LangGraph checkpoint setup"
    .venv/bin/python -m app.scripts.setup_langgraph_checkpoints

    log "starting uvicorn on 0.0.0.0:${BACKEND_PORT}"
    exec env \
        PYTHONUNBUFFERED=1 \
        AGENT_RUNTIME_V2_ENABLED="$AGENT_RUNTIME_V2_ENABLED" \
        AGENT_RUNTIME_V2_AGENT_IDS="$AGENT_RUNTIME_V2_AGENT_IDS" \
        AGENT_RUNTIME_V2_SOURCE_TYPES="$AGENT_RUNTIME_V2_SOURCE_TYPES" \
        PUBLIC_BASE_URL="$PUBLIC_BASE_URL" \
        DATABASE_URL="$DATABASE_URL" \
        .venv/bin/uvicorn app.main:app --host 0.0.0.0 --port "$BACKEND_PORT"
}

run_frontend() {
    load_env

    cd "$CLAWITH_ROOT/frontend"
    if [[ ! -x node_modules/.bin/vite ]]; then
        log "frontend/node_modules is not ready; run bash setup.sh first" >&2
        exit 1
    fi

    export CI=true
    export BACKEND_PORT
    log "starting Vite dev server on 0.0.0.0:${FRONTEND_PORT}"
    exec node_modules/.bin/vite --host 0.0.0.0 --port "$FRONTEND_PORT" --strictPort
}

run_backend_wrapper() {
    local child rc=0
    set -m
    run_backend &
    child=$!
    trap 'kill -TERM -- "-$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 0' TERM INT
    if wait "$child"; then
        rc=0
    else
        rc=$?
    fi
    printf 'backend\n' >&3 2>/dev/null || true
    exit "$rc"
}

run_frontend_wrapper() {
    local child rc=0
    set -m
    run_frontend &
    child=$!
    trap 'kill -TERM -- "-$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 0' TERM INT
    if wait "$child"; then
        rc=0
    else
        rc=$?
    fi
    printf 'frontend\n' >&3 2>/dev/null || true
    exit "$rc"
}

run_all() {
    local tmp_dir fifo exited
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/clawith-supervisor.XXXXXX")"
    fifo="$tmp_dir/child-exit.fifo"
    mkfifo "$fifo"
    trap 'rm -rf "$tmp_dir"' EXIT

    exec 3<> "$fifo"
    run_backend_wrapper &
    _child_pids+=("$!")
    run_frontend_wrapper &
    _child_pids+=("$!")

    # Any service exit is unexpected; SIGTERM is handled by cleanup() first.
    read -r exited <&3 || true
    exec 3>&-
    stop_children
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  clawith-supervisor.sh            Start backend and frontend
  clawith-supervisor.sh backend    Start backend only
  clawith-supervisor.sh frontend   Start frontend only
EOF
}

case "${1:-}" in
    ""|all) run_all ;;
    backend) run_backend ;;
    frontend) run_frontend ;;
    *) usage >&2; exit 2 ;;
esac
