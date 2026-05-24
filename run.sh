#!/bin/bash

# -- parse flags
TRACE=""
PLOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --trace) TRACE=1; shift ;;
        --plot)  PLOT=1;  shift ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--trace] [--plot]

Runs one benchmark via bench.sh, with output saved to rst/. Settings (nginx +
wrk) come from env vars; defaults are baked into this script.

Options:
  --trace    enable nginx access logging during the run; archive the access
             log into rst/ next to the .out file
  --plot     also render a PNG plot from the access log; only takes effect
             when --trace is also set (requires Python + matplotlib + numpy)

Env vars: NGINX_MASTER_CORE NGINX_CORES WRK_CORES THREADS CONNECTIONS
          DURATION TARGETRPS TARGETRPS_DIST RUN_TAG
EOF
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -n "$PLOT" && -z "$TRACE" ]]; then
    echo "WARNING: --plot has no effect without --trace; skipping plot" >&2
fi

# -- nginx settings
NGINX_MASTER_CORE="${NGINX_MASTER_CORE:-0}"
NGINX_CORES="${NGINX_CORES:-1-16}"

# -- wrk settings
WRK_CORES="${WRK_CORES:-20-29}"

# THREADS defaults to the number of cores in WRK_CORES (so the two always match
# unless the user explicitly overrides one of them).
count_cores() {
    local spec="$1" n=0 t
    local IFS=','
    for t in $spec; do
        if [[ "$t" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            n=$(( n + ${BASH_REMATCH[2]} - ${BASH_REMATCH[1]} + 1 ))
        elif [[ "$t" =~ ^[0-9]+$ ]]; then
            n=$(( n + 1 ))
        fi
    done
    echo "$n"
}
if [[ -z "${THREADS:-}" ]]; then
    THREADS=$(count_cores "$WRK_CORES")
    echo "THREADS auto-set to ${THREADS} from WRK_CORES=${WRK_CORES}"
fi

CONNECTIONS="${CONNECTIONS:-300}"
DURATION="${DURATION:-100}"
TARGETRPS="${TARGETRPS:-1000}"
TARGETRPS_DIST="${TARGETRPS_DIST:-const}"

# -- output file (encodes nginx + wrk config plus a UTC timestamp)
RST_DIR="rst"
mkdir -p "$RST_DIR"          # creates rst/ if it does not exist, no-op if it does
STAMP=$(date -u +%Y%m%d-%H%M%S)
RUN_TAG="${RUN_TAG:-}"
TAG_PART=""
[[ -n "$RUN_TAG" ]] && TAG_PART="_${RUN_TAG}"
case "${TARGETRPS,,}" in
    0|inf|infinite)  RPS_PART="-rps${TARGETRPS}" ;;
    *)               RPS_PART="-rps${TARGETRPS}-dist${TARGETRPS_DIST}" ;;
esac
OUT="${RST_DIR}/nginx-m${NGINX_MASTER_CORE}-w${NGINX_CORES}_wrk-cpu${WRK_CORES}-t${THREADS}-c${CONNECTIONS}-d${DURATION}${RPS_PART}${TAG_PART}_${STAMP}.out"

# -- always restart nginx so the running config matches the filename
pgrep nginx &>/dev/null && ./stop.sh
NGINX_MASTER_CORE="$NGINX_MASTER_CORE" NGINX_CORES="$NGINX_CORES" \
    LOG_REQUESTS="${TRACE:+1}" ./start.sh

echo "RUN"
START_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Start: $START_UTC" | tee "$OUT"
WRK_CORES="$WRK_CORES" ./bench.sh -t "$THREADS" --rps "$TARGETRPS" --rps-dist "$TARGETRPS_DIST" -c "$CONNECTIONS" -d "$DURATION" --keep-server 2>&1 | tee -a "$OUT"
END_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "End:   $END_UTC" | tee -a "$OUT"

# -- archive access log and (optionally) plot
if [[ -n "$TRACE" ]]; then
    ACCESS_SRC="dist/nginx/logs/access.log"
    ACCESS_OUT="${OUT%.out}.access.log"
    PLOT_OUT="${OUT%.out}.png"
    if [[ -f "$ACCESS_SRC" ]]; then
        cp "$ACCESS_SRC" "$ACCESS_OUT"
        {
            echo "Trace: $ACCESS_OUT"
            echo "Plot:  python3 ./plot-rps.py $ACCESS_OUT $PLOT_OUT"
        } | tee -a "$OUT"
        if [[ -n "$PLOT" ]]; then
            if python3 ./plot-rps.py "$ACCESS_OUT" "$PLOT_OUT"; then
                echo "Plot saved: $PLOT_OUT" | tee -a "$OUT"
            else
                echo "Plot: generation failed (install: python3 -m pip install matplotlib numpy)" >&2
            fi
        fi
    else
        echo "Trace: ERROR — access log missing at $ACCESS_SRC" >&2
    fi
fi

echo "DONE -> $OUT"
