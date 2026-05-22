#!/bin/bash

# -- nginx settings
NGINX_MASTER_CORE=0
NGINX_CORES=1-16

# -- wrk settings
WRK_CORES=20-29
THREADS=10
CONNECTIONS=300
DURATION=100

# -- output file (encodes nginx + wrk config plus a UTC timestamp)
RST_DIR="rst"
mkdir -p "$RST_DIR"          # creates rst/ if it does not exist, no-op if it does
STAMP=$(date -u +%Y%m%d-%H%M%S)
OUT="${RST_DIR}/nginx-m${NGINX_MASTER_CORE}-w${NGINX_CORES}_wrk-cpu${WRK_CORES}-t${THREADS}-c${CONNECTIONS}-d${DURATION}_${STAMP}.out"

# -- always restart nginx so the running config matches the filename
pgrep nginx &>/dev/null && ./stop.sh
NGINX_MASTER_CORE="$NGINX_MASTER_CORE" NGINX_CORES="$NGINX_CORES" ./start.sh

echo "RUN"
START_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Start: $START_UTC" | tee "$OUT"
WRK_CORES="$WRK_CORES" ./bench.sh -t "$THREADS" -c "$CONNECTIONS" -d "$DURATION" --keep-server 2>&1 | tee -a "$OUT"
END_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "End:   $END_UTC" | tee -a "$OUT"

echo "DONE -> $OUT"
