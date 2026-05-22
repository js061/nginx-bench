#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
NGINX="$DIST_DIR/nginx/sbin/nginx"
PID_FILE="$DIST_DIR/nginx/logs/nginx.pid"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h]

Starts the benchmark nginx server. No-op if nginx is already running.

Worker count and CPU affinity are set via environment variables:
  WORKER_NUMS        number of nginx worker processes (default: auto)
  NGINX_CORES        pin workers to CPU cores, e.g. 0-3 or 0,2,4,6
                     (sets worker count to the number of cores listed)
  NGINX_MASTER_CORE  pin the master process to a single CPU core

Options:
  -h, --help         show this help

Examples:
  ./$(basename "$0")
  WORKER_NUMS=4 ./$(basename "$0")
  NGINX_CORES=0-3 ./$(basename "$0")
  NGINX_MASTER_CORE=39 NGINX_CORES=0-7 ./$(basename "$0")
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

[[ -x "$NGINX" ]] || { echo "ERROR: nginx not found — run install.sh first" >&2; exit 1; }

# Precedence: NGINX_CORES > WORKER_NUMS > auto
WORKERS="${WORKER_NUMS:-}"
NGINX_CORES="${NGINX_CORES:-}"
NGINX_MASTER_CORE="${NGINX_MASTER_CORE:-}"
CONF="conf/nginx.conf"
TMPCONF=""
AFFINITY_MASKS=""
NUM_CPUS=$(nproc)

trap '[[ -n "$TMPCONF" ]] && rm -f "$TMPCONF"' EXIT

if [[ -n "$NGINX_MASTER_CORE" ]]; then
    [[ "$NGINX_MASTER_CORE" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid NGINX_MASTER_CORE: $NGINX_MASTER_CORE" >&2; exit 1; }
    (( NGINX_MASTER_CORE < NUM_CPUS ))     || { echo "ERROR: NGINX_MASTER_CORE $NGINX_MASTER_CORE >= nproc ($NUM_CPUS)" >&2; exit 1; }
    command -v taskset &>/dev/null         || { echo "ERROR: taskset not found (install util-linux)" >&2; exit 1; }
fi

if [[ -n "$NGINX_CORES" ]]; then
    CORES=()
    IFS=',' read -ra TOKENS <<< "$NGINX_CORES"
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
    WORKERS="${#CORES[@]}"

    for core in "${CORES[@]}"; do
        mask=$(printf '%0*d' "$NUM_CPUS" 0)
        pos=$(( NUM_CPUS - 1 - core ))
        mask="${mask:0:$pos}1${mask:$(( pos + 1 ))}"
        AFFINITY_MASKS="$AFFINITY_MASKS $mask"
    done
    AFFINITY_MASKS="${AFFINITY_MASKS# }"
fi

if [[ -n "$WORKERS" ]]; then
    [[ "$WORKERS" =~ ^[0-9]+$ ]] || { echo "ERROR: workers must be a positive integer" >&2; exit 1; }
    TMPCONF="$(mktemp "$DIST_DIR/nginx/conf/nginx.tmp.XXXXXX.conf")"
    if [[ -n "$AFFINITY_MASKS" ]]; then
        sed "s|^\s*worker_processes\s.*;|worker_processes ${WORKERS};\nworker_cpu_affinity ${AFFINITY_MASKS};|" \
            "$DIST_DIR/nginx/conf/nginx.conf" > "$TMPCONF"
        echo "CPU affinity: workers pinned to cores [${NGINX_CORES}]"
    else
        sed "s/^\s*worker_processes\s.*;/worker_processes ${WORKERS};/" \
            "$DIST_DIR/nginx/conf/nginx.conf" > "$TMPCONF"
    fi
    CONF="conf/$(basename "$TMPCONF")"
fi

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "nginx is already running (pid $(cat "$PID_FILE"))"
    exit 0
fi

mkdir -p "$DIST_DIR/nginx/logs"
if [[ -n "$NGINX_MASTER_CORE" ]]; then
    taskset -c "$NGINX_MASTER_CORE" "$NGINX" -p "$DIST_DIR/nginx" -c "$CONF"
    echo "Master process pinned to core ${NGINX_MASTER_CORE}"
else
    "$NGINX" -p "$DIST_DIR/nginx" -c "$CONF"
fi
sleep 1

if [[ -f "$PID_FILE" ]]; then
    echo "nginx started (pid $(cat "$PID_FILE"))"
else
    echo "ERROR: nginx failed to start — check $DIST_DIR/nginx/logs/error.log" >&2
    exit 1
fi
