#!/bin/bash

# -- nginx settings
NGINX_MASTER_CORE="${NGINX_MASTER_CORE:-0}"
NGINX_CORES="${NGINX_CORES:-1-16}"

# -- wrk settings
WRK_CORES="${WRK_CORES:-20-29}"
THREADS="${THREADS:-10}"
CONNECTIONS="${CONNECTIONS:-300}"
DURATION="${DURATION:-100}"
TARGETRPS="${TARGETRPS:-1000}"

# -- output file (encodes nginx + wrk config plus a UTC timestamp)
RST_DIR="rst"
mkdir -p "$RST_DIR"          # creates rst/ if it does not exist, no-op if it does
STAMP=$(date -u +%Y%m%d-%H%M%S)
RUN_TAG="${RUN_TAG:-}"
TAG_PART=""
[[ -n "$RUN_TAG" ]] && TAG_PART="_${RUN_TAG}"
OUT="${RST_DIR}/nginx-m${NGINX_MASTER_CORE}-w${NGINX_CORES}_wrk-cpu${WRK_CORES}-t${THREADS}-c${CONNECTIONS}-d${DURATION}-rps${TARGETRPS}${TAG_PART}_${STAMP}.out"

# -- always restart nginx so the running config matches the filename
pgrep nginx &>/dev/null && ./stop.sh
NGINX_MASTER_CORE="$NGINX_MASTER_CORE" NGINX_CORES="$NGINX_CORES" ./start.sh

echo "RUN"
START_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Start: $START_UTC" | tee "$OUT"
WRK_CORES="$WRK_CORES" ./bench.sh -t "$THREADS" --rps "$TARGETRPS" -c "$CONNECTIONS" -d "$DURATION" --keep-server 2>&1 | tee -a "$OUT"
END_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "End:   $END_UTC" | tee -a "$OUT"

echo "DONE -> $OUT"
