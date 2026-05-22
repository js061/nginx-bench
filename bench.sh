#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
WRK="$DIST_DIR/wrk"
NGINX="$DIST_DIR/nginx/sbin/nginx"
PID_FILE="$DIST_DIR/nginx/logs/nginx.pid"

# -- Defaults (match PTS profile)
THREADS="$(nproc)"
CONNECTIONS="100"
DURATION="90s"
URL="https://127.0.0.1:8089/test.html"
LATENCY=""
TIMEOUT=""
LUA_SCRIPT=""
EXTRA_HEADERS=()
KEEP_SERVER=""   # if set, don't start/stop nginx — assume it's already running
TARGET_RPS=""    # if set, inject a delay() Lua hook to throttle per-connection rate
WRK_TASKSET=()   # taskset prefix for wrk, populated if WRK_CORES is set

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -t THREADS      number of threads        (default: nproc = $(nproc))
  -c CONNECTIONS  concurrent connections   (default: 100)
  -d DURATION     test duration            (default: 90s)
  -u URL          target URL               (default: https://127.0.0.1:8089/test.html)
  -s SCRIPT       LuaJIT script for wrk
  -H HEADER       add HTTP header (repeatable)
  --rps RPS       throttle to target requests/sec (approximate)
  --latency       print detailed latency percentiles
  --timeout SEC   mark request failed after SEC seconds
  --keep-server   skip nginx start/stop (use if nginx is already running)
  -h              show this help

Environment:
  WRK_CORES       pin wrk threads to CPU cores, e.g. 0-3 or 0,2,4,6
                  (core count must equal -t THREADS)
EOF
    exit 0
}

# -- Argument parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t) THREADS="$2";     shift 2 ;;
        -c) CONNECTIONS="$2"; shift 2 ;;
        -d) DURATION="$2";    shift 2 ;;
        -u) URL="$2";         shift 2 ;;
        -s) LUA_SCRIPT="$2";  shift 2 ;;
        -H) EXTRA_HEADERS+=("$2"); shift 2 ;;
        --latency)      LATENCY="--latency"; shift ;;
        --timeout)      TIMEOUT="--timeout $2"; shift 2 ;;
        --rps)          TARGET_RPS="$2"; shift 2 ;;
        --keep-server)  KEEP_SERVER=1; shift ;;
        -h|--help)      usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

[[ -x "$WRK" ]]   || { echo "ERROR: wrk not found — run install.sh first" >&2; exit 1; }
[[ -x "$NGINX" ]] || { echo "ERROR: nginx not found — run install.sh first" >&2; exit 1; }

# -- RPS throttle
TMPSCRIPT=""
if [[ -n "$TARGET_RPS" ]]; then
    [[ "$TARGET_RPS" =~ ^[0-9]+$ ]] || { echo "ERROR: --rps must be a positive integer" >&2; exit 1; }
    DELAY_MS=$(awk -v c="$CONNECTIONS" -v r="$TARGET_RPS" 'BEGIN{printf "%d", int(c/r*1000 + 0.5)}')
    TMPSCRIPT="$(mktemp /tmp/wrk-delay-XXXXXX.lua)"
    printf 'function delay()\n  return %d\nend\n' "$DELAY_MS" > "$TMPSCRIPT"
    echo "RPS throttle: ${TARGET_RPS} req/s → ${DELAY_MS}ms delay per connection"
    [[ -n "$LUA_SCRIPT" ]] && echo "WARNING: --rps overrides -s (user Lua script ignored)"
    LUA_SCRIPT="$TMPSCRIPT"
fi

# -- CPU affinity for wrk threads
if [[ -n "${WRK_CORES:-}" ]]; then
    command -v taskset &>/dev/null || { echo "ERROR: taskset not found (install util-linux)" >&2; exit 1; }
    NUM_CPUS=$(nproc)
    CORES=()
    IFS=',' read -ra TOKENS <<< "$WRK_CORES"
    for token in "${TOKENS[@]}"; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
            (( lo <= hi )) || { echo "ERROR: invalid range: $token" >&2; exit 1; }
            for (( c=lo; c<=hi; c++ )); do CORES+=("$c"); done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            CORES+=("$token")
        else
            echo "ERROR: invalid core spec: $token" >&2; exit 1
        fi
    done
    for core in "${CORES[@]}"; do
        (( core < NUM_CPUS )) || { echo "ERROR: core $core >= nproc ($NUM_CPUS)" >&2; exit 1; }
    done
    if (( ${#CORES[@]} != THREADS )); then
        echo "ERROR: WRK_CORES lists ${#CORES[@]} core(s) but -t is ${THREADS}; counts must match" >&2
        exit 1
    fi
    WRK_CORE_LIST=$(IFS=,; echo "${CORES[*]}")
    WRK_TASKSET=(taskset -c "$WRK_CORE_LIST")
    echo "CPU affinity: wrk pinned to cores [${WRK_CORE_LIST}]"
fi

# -- Build wrk command
WRK_CMD=("${WRK_TASKSET[@]}" "$WRK" -t "$THREADS" -c "$CONNECTIONS" -d "$DURATION")
[[ -n "$LATENCY" ]]    && WRK_CMD+=("$LATENCY")
[[ -n "$TIMEOUT" ]]    && WRK_CMD+=($TIMEOUT)
[[ -n "$LUA_SCRIPT" ]] && WRK_CMD+=(-s "$LUA_SCRIPT")
for h in "${EXTRA_HEADERS[@]:-}"; do
    WRK_CMD+=(-H "$h")
done
WRK_CMD+=("$URL")

# -- Start nginx
nginx_started=""
if [[ -z "$KEEP_SERVER" ]]; then
    if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Using existing nginx (pid $(cat "$PID_FILE"))"
    else
        mkdir -p "$DIST_DIR/nginx/logs"
        "$NGINX" -p "$DIST_DIR/nginx" -c conf/nginx.conf
        sleep 2
        nginx_started=1
        echo "nginx started (pid $(cat "$PID_FILE"))"
    fi
fi

# -- Run benchmark
echo ""
echo "Running: ${WRK_CMD[*]}"
echo ""
"${WRK_CMD[@]}"

[[ -n "$TMPSCRIPT" ]] && rm -f "$TMPSCRIPT"

# -- Stop nginx
if [[ -n "$nginx_started" ]]; then
    "$NGINX" -p "$DIST_DIR/nginx" -c conf/nginx.conf -s quit
    echo ""
    echo "nginx stopped"
fi
