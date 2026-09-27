#!/usr/bin/env bash
# Manage the local Desired State research UI from any working directory.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SESSION_DIR="$ROOT/sessions"
PID_FILE="$SESSION_DIR/web.pid"
LOG_FILE="$SESSION_DIR/web.log"
SERVER="$ROOT/.venv/bin/desired-state-web"
HOST="0.0.0.0"
PORT="5051"
URL="http://127.0.0.1:$PORT/"

server_pid() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid
    pid="$(cat "$PID_FILE")"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # Do not signal an unrelated process if the PID was recycled.
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq "$SERVER" || return 1
    printf '%s\n' "$pid"
}

start() {
    mkdir -p "$SESSION_DIR"
    local pid
    if pid="$(server_pid)"; then
        echo "Desired State already running (PID $pid): $URL"
        return
    fi
    if [[ ! -x "$SERVER" ]]; then
        echo "Missing $SERVER. Run: python3 -m venv .venv && .venv/bin/python -m pip install -e ." >&2
        exit 1
    fi
    if curl --silent --fail --output /dev/null "$URL"; then
        echo "Port $PORT already serves an app. Check it before starting another instance." >&2
        exit 1
    fi
    cd "$ROOT"
    nohup "$SERVER" --host "$HOST" --port "$PORT" > "$LOG_FILE" 2>&1 < /dev/null &
    pid=$!
    printf '%s\n' "$pid" > "$PID_FILE"
    for ((attempt=0; attempt<30; attempt++)); do
        if curl --silent --fail --output /dev/null "$URL"; then
            echo "Desired State ready (PID $pid): $URL"
            return
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            echo "Desired State exited. Recent log:" >&2
            tail -n 30 "$LOG_FILE" >&2
            exit 1
        fi
        sleep 0.5
    done
    echo "Server has not responded yet; check $LOG_FILE" >&2
    exit 1
}

stop() {
    local pid
    if ! pid="$(server_pid)"; then
        rm -f "$PID_FILE"
        echo "Desired State is not running from this launcher."
        return
    fi
    kill "$pid"
    for ((attempt=0; attempt<20; attempt++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            echo "Desired State stopped."
            return
        fi
        sleep 0.25
    done
    echo "Stop requested; process $pid is still exiting."
}

case "${1:-start}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status)
        if pid="$(server_pid)"; then echo "Running (PID $pid): $URL";
        else echo "Not running from this launcher."; fi ;;
    logs) mkdir -p "$SESSION_DIR"; touch "$LOG_FILE"; tail -n 50 "$LOG_FILE" ;;
    *) echo "Usage: $0 {start|stop|restart|status|logs}" >&2; exit 2 ;;
esac
