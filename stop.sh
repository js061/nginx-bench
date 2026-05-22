#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
NGINX="$DIST_DIR/nginx/sbin/nginx"
PID_FILE="$DIST_DIR/nginx/logs/nginx.pid"

[[ -x "$NGINX" ]] || { echo "ERROR: nginx not found — run install.sh first" >&2; exit 1; }

if [[ ! -f "$PID_FILE" ]] || ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "nginx is not running"
    exit 0
fi

"$NGINX" -p "$DIST_DIR/nginx" -c conf/nginx.conf -s quit
echo "nginx stopped"
