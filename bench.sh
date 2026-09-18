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
DURATION_SET=""  # set to 1 if -d was passed explicitly
REQUESTS=""      # if set, stop after ~N total requests (count mode)
URL="https://127.0.0.1:8089/test.html"
LATENCY=""
TIMEOUT=""
LUA_SCRIPT=""
EXTRA_HEADERS=()
KEEP_SERVER=""   # if set, don't start/stop nginx — assume it's already running
TARGET_RPS=""    # if set, inject a delay() Lua hook to throttle per-connection rate
TARGET_RPS_DIST="const"   # const | normal | exp | lognormal | pareto | onoff

# -- shape params for --rps-dist (overridable via config/rps-dist.sh)
: "${RPS_DIST_NORMAL_SIGMA_FACTOR:=0.333}"
: "${RPS_DIST_LOGNORMAL_SIGMA:=0.5}"
: "${RPS_DIST_PARETO_ALPHA:=1.5}"
: "${RPS_DIST_ONOFF_K:=10}"
: "${RPS_DIST_ONOFF_RATE_RATIO:=10}"
DIST_CONFIG="$SCRIPT_DIR/config/rps-dist.sh"
[[ -f "$DIST_CONFIG" ]] && source "$DIST_CONFIG"

for v in RPS_DIST_NORMAL_SIGMA_FACTOR RPS_DIST_LOGNORMAL_SIGMA \
         RPS_DIST_PARETO_ALPHA RPS_DIST_ONOFF_K RPS_DIST_ONOFF_RATE_RATIO; do
    val="${!v}"
    [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(awk "BEGIN{print ($val > 0)}") )) || {
        echo "ERROR: $v must be a positive number, got: $val" >&2; exit 1; }
done
WRK_TASKSET=()   # taskset prefix for wrk, populated if WRK_CORES is set
WRK_PID=""
RUN_OUT=""

cleanup() {
    local status=$?
    trap - EXIT INT TERM

    if [[ -n "$WRK_PID" ]] && kill -0 "$WRK_PID" 2>/dev/null; then
        kill -TERM "$WRK_PID" 2>/dev/null || true
        wait "$WRK_PID" 2>/dev/null || true
    fi
    [[ -n "${RUN_OUT:-}" ]]    && rm -f "$RUN_OUT"
    [[ -n "${TMPSCRIPT:-}" ]]  && rm -f "$TMPSCRIPT"
    [[ -n "${COUNTSCRIPT:-}" ]] && rm -f "$COUNTSCRIPT"

    if [[ -n "${nginx_started:-}" ]] && [[ -f "$PID_FILE" ]]; then
        "$NGINX" -p "$DIST_DIR/nginx" -c conf/nginx.conf -s quit >/dev/null 2>&1 || true
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -t THREADS      number of threads        (default: nproc = $(nproc))
  -c CONNECTIONS  concurrent connections   (default: 100)
  -d DURATION     test duration            (default: 90s)
  -n REQUESTS     stop after ~N total requests instead of running for -d
                  (splits N/THREADS per thread; -d becomes a safety cap)
  -u URL          target URL               (default: https://127.0.0.1:8089/test.html)
  -s SCRIPT       LuaJIT script for wrk
  -H HEADER       add HTTP header (repeatable)
  --rps RPS       throttle to target requests/sec; 0 or inf = no throttle
  --rps-dist NAME inter-arrival distribution for --rps:
                  const|normal|exp|lognormal|pareto|onoff  (default: const)
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
        -d) DURATION="$2"; DURATION_SET=1; shift 2 ;;
        -n|--requests) REQUESTS="$2"; shift 2 ;;
        -u) URL="$2";         shift 2 ;;
        -s) LUA_SCRIPT="$2";  shift 2 ;;
        -H) EXTRA_HEADERS+=("$2"); shift 2 ;;
        --latency)      LATENCY="--latency"; shift ;;
        --timeout)      TIMEOUT="--timeout $2"; shift 2 ;;
        --rps)          TARGET_RPS="$2"; shift 2 ;;
        --rps-dist)     TARGET_RPS_DIST="$2"; shift 2 ;;
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
    case "${TARGET_RPS,,}" in
        0|inf|infinite)
            echo "RPS throttle: unlimited (no throttle)"
            ;;
        *)
            [[ "$TARGET_RPS" =~ ^[0-9]+$ ]] || { echo "ERROR: --rps must be a positive integer, 0, or inf" >&2; exit 1; }
            case "$TARGET_RPS_DIST" in
                const|normal|exp|lognormal|pareto|onoff) ;;
                *) echo "ERROR: --rps-dist must be one of: const, normal, exp, lognormal, pareto, onoff" >&2; exit 1 ;;
            esac
            DELAY_MS=$(awk -v c="$CONNECTIONS" -v r="$TARGET_RPS" 'BEGIN{printf "%d", int(c/r*1000 + 0.5)}')
            TMPSCRIPT="$(mktemp /tmp/wrk-delay-XXXXXX.lua)"
            cat > "$TMPSCRIPT" <<EOF
-- generated by bench.sh: --rps $TARGET_RPS --rps-dist $TARGET_RPS_DIST
local N = $DELAY_MS
local NORMAL_SIGMA_FACTOR = $RPS_DIST_NORMAL_SIGMA_FACTOR
local LOGNORMAL_SIGMA     = $RPS_DIST_LOGNORMAL_SIGMA
local PARETO_ALPHA        = $RPS_DIST_PARETO_ALPHA
local ONOFF_K             = $RPS_DIST_ONOFF_K
local ONOFF_RATE_RATIO    = $RPS_DIST_ONOFF_RATE_RATIO
math.randomseed(os.time())
EOF
            case "$TARGET_RPS_DIST" in
                const) cat >> "$TMPSCRIPT" <<'LUA'
function delay()
  return N
end
LUA
                    ;;
                normal) cat >> "$TMPSCRIPT" <<'LUA'
function delay()
  local u1 = math.random(); if u1 < 1e-12 then u1 = 1e-12 end
  local u2 = math.random()
  local z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
  local d = N + z * (N * NORMAL_SIGMA_FACTOR)
  if d < 0 then d = 0 end
  return d
end
LUA
                    ;;
                exp) cat >> "$TMPSCRIPT" <<'LUA'
function delay()
  return -N * math.log(1 - math.random())
end
LUA
                    ;;
                lognormal) cat >> "$TMPSCRIPT" <<'LUA'
function delay()
  local sigma = LOGNORMAL_SIGMA
  local mu = math.log(N) - sigma * sigma / 2
  local u1 = math.random(); if u1 < 1e-12 then u1 = 1e-12 end
  local u2 = math.random()
  local z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
  return math.exp(mu + sigma * z)
end
LUA
                    ;;
                pareto) cat >> "$TMPSCRIPT" <<'LUA'
function delay()
  local alpha = PARETO_ALPHA
  local x_m = N * (alpha - 1) / alpha
  return x_m * (1 - math.random()) ^ (-1 / alpha)
end
LUA
                    ;;
                onoff) cat >> "$TMPSCRIPT" <<'LUA'
local K = ONOFF_K
local d_on  = N / ONOFF_RATE_RATIO
local d_off = (K + 1) * N - K * d_on
local in_burst = (math.random() < 0.5)
local remaining = in_burst and K or 1
function delay()
  remaining = remaining - 1
  if remaining <= 0 then
    in_burst = not in_burst
    remaining = in_burst and K or 1
  end
  if in_burst then return d_on else return d_off end
end
LUA
                    ;;
            esac
            case "$TARGET_RPS_DIST" in
                const|exp) extra="" ;;
                normal)    extra=", sigma_factor=$RPS_DIST_NORMAL_SIGMA_FACTOR" ;;
                lognormal) extra=", sigma=$RPS_DIST_LOGNORMAL_SIGMA" ;;
                pareto)    extra=", alpha=$RPS_DIST_PARETO_ALPHA" ;;
                onoff)     extra=", K=$RPS_DIST_ONOFF_K, rate_ratio=$RPS_DIST_ONOFF_RATE_RATIO" ;;
            esac
            echo "RPS throttle: ${TARGET_RPS} req/s, dist=${TARGET_RPS_DIST}${extra}, mean delay=${DELAY_MS}ms per connection"
            [[ -n "$LUA_SCRIPT" ]] && echo "WARNING: --rps overrides -s (user Lua script ignored)"
            LUA_SCRIPT="$TMPSCRIPT"
            ;;
    esac
fi

# -- Request-count mode: stop after ~N total requests
COUNTSCRIPT=""
if [[ -n "$REQUESTS" ]]; then
    [[ "$REQUESTS" =~ ^[0-9]+$ ]] && (( REQUESTS > 0 )) || {
        echo "ERROR: -n must be a positive integer" >&2; exit 1; }

    # per-thread quota (rounded up so the total is at least N)
    REQ_PER_THREAD=$(awk -v n="$REQUESTS" -v t="$THREADS" 'BEGIN{printf "%d", int((n + t - 1)/t)}')
    ACTUAL_TOTAL=$(( REQ_PER_THREAD * THREADS ))

    # When the caller does not provide a safety cap, estimate one from the real
    # workload. The request supervisor below still ends wrk as soon as the quotas
    # drain; this calibration only prevents the default -d from being too short.
    WARMUP_LUA="$LUA_SCRIPT"   # base script (throttle or user -s) at this point
    CALIBRATE=""
    if [[ -n "$DURATION_SET" ]]; then
        echo "Request-count mode: capping at ~${ACTUAL_TOTAL} requests (${REQ_PER_THREAD}/thread × ${THREADS}) within your -d ${DURATION}"
    else
        CALIBRATE=1
        echo "Request-count mode: ~${ACTUAL_TOTAL} requests (${REQ_PER_THREAD}/thread × ${THREADS}); calibrating -d from a short warmup"
    fi
    (( ACTUAL_TOTAL != REQUESTS )) && echo "  note: rounded up from ${REQUESTS} to a per-thread multiple (${THREADS} threads)"

    COUNTSCRIPT="$(mktemp /tmp/wrk-count-XXXXXX.lua)"
    if [[ -n "$LUA_SCRIPT" ]]; then
        # layer counting on top of the existing script (rps throttle or user -s),
        # chaining its response() handler if it has one
        BASE_LUA_ABS="$(cd "$(dirname "$LUA_SCRIPT")" && pwd)/$(basename "$LUA_SCRIPT")"
        cat > "$COUNTSCRIPT" <<EOF
-- generated by bench.sh: -n $REQUESTS (quota ${REQ_PER_THREAD}/thread)
dofile("$BASE_LUA_ABS")
local __n_user_response = response
local __n_counter = 0
local __n_quota = $REQ_PER_THREAD
function response(status, headers, body)
  if __n_user_response then __n_user_response(status, headers, body) end
  __n_counter = __n_counter + 1
  if __n_counter >= __n_quota then wrk.thread:stop() end
end
EOF
    else
        cat > "$COUNTSCRIPT" <<EOF
-- generated by bench.sh: -n $REQUESTS (quota ${REQ_PER_THREAD}/thread)
local __n_counter = 0
local __n_quota = $REQ_PER_THREAD
function response(status, headers, body)
  __n_counter = __n_counter + 1
  if __n_counter >= __n_quota then wrk.thread:stop() end
end
EOF
    fi
    LUA_SCRIPT="$COUNTSCRIPT"
fi

# -- CPU affinity for wrk threads
if [[ -n "${WRK_CORES:-}" ]]; then
    command -v taskset &>/dev/null || { echo "ERROR: taskset not found (install util-linux)" >&2; exit 1; }
    # NOTE: wrk is pinned via `taskset -c <real cpu id>`, not an nproc-wide
    # bitmask, so cores need only be online -- not < nproc. (nproc counts
    # online CPUs, which can be a sparse ID range, e.g. 0,2,4,...,22 when
    # SMT siblings are interleaved rather than offset by nproc/2.)
    expand_cpu_spec() {
        local spec=$1 tok lo hi c
        local IFS=','
        for tok in $spec; do
            if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
                for (( c=lo; c<=hi; c++ )); do echo "$c"; done
            elif [[ "$tok" =~ ^[0-9]+$ ]]; then
                echo "$tok"
            fi
        done
    }
    ONLINE_CPUS=",$(expand_cpu_spec "$(cat /sys/devices/system/cpu/online 2>/dev/null)" | tr '\n' ','),"
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
        [[ "$ONLINE_CPUS" == *",$core,"* ]] || { echo "ERROR: core $core is not an online CPU" >&2; exit 1; }
    done
    if (( ${#CORES[@]} != THREADS )); then
        echo "ERROR: WRK_CORES lists ${#CORES[@]} core(s) but -t is ${THREADS}; counts must match" >&2
        exit 1
    fi
    WRK_CORE_LIST=$(IFS=,; echo "${CORES[*]}")
    WRK_TASKSET=(taskset -c "$WRK_CORE_LIST")
    echo "CPU affinity: wrk pinned to cores [${WRK_CORE_LIST}]"
fi

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

# -- Calibrate duration for unthrottled count mode (needs nginx up)
if [[ -n "${CALIBRATE:-}" ]]; then
    WARM_HEADERS=()
    for h in "${EXTRA_HEADERS[@]:-}"; do [[ -n "$h" ]] && WARM_HEADERS+=(-H "$h"); done
    WARM_LUA_ARG=()
    [[ -n "$WARMUP_LUA" ]] && WARM_LUA_ARG=(-s "$WARMUP_LUA")
    echo "Calibrating achievable throughput (3s warmup)..."
    WARM_OUT="$("${WRK_TASKSET[@]}" "$WRK" -t "$THREADS" -c "$CONNECTIONS" -d 3s "${WARM_LUA_ARG[@]}" "${WARM_HEADERS[@]}" "$URL" 2>/dev/null || true)"
    RPS_EST="$(awk '/Requests\/sec:/{print $2}' <<< "$WARM_OUT")"
    if [[ "$RPS_EST" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(awk "BEGIN{print ($RPS_EST > 0)}") )); then
        # duration = N / measured-rate + 10% headroom (rounded up) so the count is reached
        SECS=$(awk -v n="$ACTUAL_TOTAL" -v r="$RPS_EST" 'BEGIN{s=int(n/r*1.1 + 0.999999); if(s<1)s=1; print s}')
        DURATION="${SECS}s"
        echo "Calibration: ~${RPS_EST} req/s measured -> -d ${DURATION} for ~${ACTUAL_TOTAL} requests"
    else
        DURATION="30s"
        echo "WARNING: calibration could not read a rate; falling back to -d ${DURATION} cap"
    fi
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

supervise_request_count() {
    local pid=$1 comm="" threads=0 wchan="" saw_workers=""

    # taskset execs wrk without changing PID. Do not consider a one-thread state
    # terminal until wrk has first created its worker threads; otherwise a fast
    # poll during startup could interrupt it before the benchmark begins.
    while kill -0 "$pid" 2>/dev/null; do
        comm=$(cat "/proc/${pid}/comm" 2>/dev/null || true)
        if [[ "$comm" == "wrk" ]]; then
            threads=$(find "/proc/${pid}/task" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || true)
            (( threads > 1 )) && saw_workers=1
            if [[ -n "$saw_workers" ]] && (( threads == 1 )); then
                wchan=$(cat "/proc/${pid}/wchan" 2>/dev/null || true)
                if [[ "$wchan" == *sleep* ]]; then
                    echo "Request quota drained; ending wrk before the duration cap"
                    kill -INT "$pid"
                    return 0
                fi
            fi
        fi
        sleep 0.05
    done
}

# -- Run benchmark
echo ""
echo "Running: ${WRK_CMD[*]}"
echo ""
if [[ -n "$REQUESTS" ]]; then
    # wrk prints its report only at the end, so buffering stdout lets us retain
    # its exact PID for supervision without losing any useful live progress.
    RUN_OUT="$(mktemp /tmp/wrk-out-XXXXXX.log)"
    "${WRK_CMD[@]}" >"$RUN_OUT" &
    WRK_PID=$!
    supervise_request_count "$WRK_PID"
    if wait "$WRK_PID"; then
        WRK_STATUS=0
    else
        WRK_STATUS=$?
    fi
    WRK_PID=""

    cat "$RUN_OUT"
    DONE_COUNT="$(awk '/^[[:space:]]*[0-9]+ requests in /{print $1}' "$RUN_OUT" | tail -1)"
    rm -f "$RUN_OUT"
    RUN_OUT=""

    if (( WRK_STATUS != 0 )); then
        echo "ERROR: wrk exited with status ${WRK_STATUS}" >&2
        exit "$WRK_STATUS"
    fi
    if [[ ! "$DONE_COUNT" =~ ^[0-9]+$ ]]; then
        echo "ERROR: could not read the completed request count from wrk output" >&2
        exit 1
    fi
    if (( DONE_COUNT < ACTUAL_TOTAL )); then
        echo ""
        echo "ERROR: completed ${DONE_COUNT} of ~${ACTUAL_TOTAL} requested before the -d cap" >&2
        exit 1
    fi
else
    "${WRK_CMD[@]}"
fi

[[ -n "$TMPSCRIPT" ]]   && rm -f "$TMPSCRIPT"
[[ -n "$COUNTSCRIPT" ]] && rm -f "$COUNTSCRIPT"

# -- Stop nginx
if [[ -n "$nginx_started" ]]; then
    "$NGINX" -p "$DIST_DIR/nginx" -c conf/nginx.conf -s quit
    nginx_started=""
    echo ""
    echo "nginx stopped"
fi
