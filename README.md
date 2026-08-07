# nginx-bench

Standalone nginx benchmark pipeline. Replicates the [Phoronix Test Suite](https://www.phoronix-test-suite.com/) `pts/nginx` profile without the PTS wrapper, giving full control over every benchmark parameter.

Uses **nginx 1.30.0** as the server under test and **wrk 4.2.0** as the HTTP load generator. Everything is compiled locally into `dist/` — no system-wide installation needed.

## Prerequisites

```bash
./setup.sh
```

Detects your distro (Debian/Ubuntu, RHEL/CentOS/Fedora, Arch, macOS) and installs the required packages — `gcc`, `make`, `openssl`, `zlib`, `curl`, `perl` — via the appropriate package manager. Prints a verification summary at the end.

## Quick Start

```bash
./install.sh          # download, compile, configure (one-time)
./bench.sh            # start nginx, run benchmark, stop nginx
./run.sh              # single run, saves output to rst/
./batch-run.sh        # sweep many configs (edit arrays at the top first)
```

## Scripts

### `install.sh`

Downloads sources, compiles nginx and wrk, generates a self-signed TLS certificate, and writes a clean `nginx.conf`. All output goes into `dist/`.

```bash
./install.sh
```

Re-running is safe — already-downloaded files are verified by SHA256 and skipped.

### `start.sh` / `stop.sh`

Start and stop the nginx server manually. Useful when running multiple back-to-back benchmarks without restarting nginx each time.

```bash
./start.sh
./stop.sh
```

`start.sh` is a no-op if nginx is already running. Worker count and CPU affinity are controlled via environment variables:

| Env var | Description |
|---------|-------------|
| `WORKER_NUMS` | Number of nginx worker processes (default: `auto` — one per core) |
| `NGINX_CORES` | Pin workers to specific CPU cores — accepts a list (`0,2,4`), ranges (`0-3`), or a mix (`0-3,6,8-11`); sets the worker count to the number of cores listed |
| `NGINX_MASTER_CORE` | Pin the nginx master process to a single CPU core (via `taskset`) |
| `LOG_REQUESTS` | If set (e.g. `=1`), enable nginx `access_log` with `$msec` timestamps to `dist/nginx/logs/access.log` (truncated at startup). Used by `run.sh --trace`; you usually don't set this directly. |

```bash
WORKER_NUMS=4 ./start.sh                          # 4 workers, no pinning
NGINX_CORES=0-3 ./start.sh                        # 4 workers pinned to cores 0-3
NGINX_MASTER_CORE=39 NGINX_CORES=0-7 ./start.sh   # master on core 39, workers on 0-7
```

`NGINX_CORES` takes precedence over `WORKER_NUMS`. If `NGINX_MASTER_CORE` is unset, the master process is left unpinned.

### `bench.sh`

Runs a full benchmark. By default manages nginx lifecycle (starts before, stops after). Pass `--keep-server` to skip that if nginx is already up.

```bash
./bench.sh [OPTIONS]
```

| Option | Default | Description |
|--------|---------|-------------|
| `-t THREADS` | `$(nproc)` | Number of wrk threads |
| `-c CONNECTIONS` | `100` | Concurrent HTTP connections |
| `-d DURATION` | `90s` | Test duration (`10s`, `2m`, `1h`) |
| `-n, --requests N` | — | Stop after **~N** total requests, then report over the actual elapsed time. The count is split evenly across threads (`ceil(N/THREADS)` each) and the first thread to finish signals wrk to exit, so the real total lands a little above or below N. `-d` still applies as an upper bound — whichever limit is hit first ends the run. |
| `-u URL` | `https://127.0.0.1:8089/test.html` | Target URL |
| `-s SCRIPT` | — | LuaJIT script for custom request logic |
| `-H HEADER` | — | Add HTTP header (repeatable) |
| `--rps RPS` | — | Throttle to a target requests/sec; `0` or `inf` = no throttle |
| `--rps-dist NAME` | `const` | Inter-arrival distribution for `--rps`: `const`, `normal`, `exp`, `lognormal`, `pareto`, `onoff` |
| `--latency` | — | Print p50/p75/p90/p99 latency breakdown |
| `--timeout SEC` | — | Mark a request failed after SEC seconds |
| `--keep-server` | — | Skip nginx start/stop |
| `-h` | — | Show help |

CPU affinity for wrk's own threads is controlled via an environment variable:

| Env var | Description |
|---------|-------------|
| `WRK_CORES` | Pin wrk threads to specific CPU cores — accepts a list (`0,2,4`), ranges (`0-3`), or a mix (`0-3,6,8-11`). The core count **must equal** `-t THREADS`, otherwise `bench.sh` errors out. |

```bash
WRK_CORES=0-3 ./bench.sh -t 4              # wrk threads pinned to cores 0-3
WRK_CORES=0,2,4,6 ./bench.sh -t 4          # list syntax
```

wrk is a single process with internal threads, so pinning is done by launching it under `taskset -c` — all wrk threads are confined to the listed cores. Pair it with `start.sh`'s `NGINX_CORES` to keep the load generator and the server on separate cores.

#### `--rps-dist` distributions

All six preserve `E[delay] = (CONN / target_rps) × 1000` ms, so target RPS is unchanged — only the *shape* of inter-arrivals varies:

| Name | Behavior | Typical use |
|---|---|---|
| `const` | every gap = mean | smooth, repeatable; default |
| `normal` | mean ± σ jitter (σ = mean/3) | gentle bell-curve noise |
| `exp` | exponential / Poisson arrivals | realistic baseline for independent clients |
| `lognormal` | right-skewed (log σ = 0.5) | occasional long pauses |
| `pareto` | heavy-tailed (α = 1.5) | bursty / self-similar traffic |
| `onoff` | stateful bursts (K=10 reqs at 10× rate, then 10× silence) | per-thread user model |

The shape parameters (σ, α, K, rate ratio) are tunable without editing `bench.sh` — see [`config/rps-dist.sh`](#configrps-distsh).

#### `config/rps-dist.sh`

`bench.sh` sources this file (if present) at startup to override the baked-in shape params. Each line is a plain shell assignment:

```bash
RPS_DIST_NORMAL_SIGMA_FACTOR=0.333   # normal σ as a fraction of the mean
RPS_DIST_LOGNORMAL_SIGMA=0.5         # lognormal σ in log-space
RPS_DIST_PARETO_ALPHA=1.5            # pareto shape; must be > 1; lower = heavier tail
RPS_DIST_ONOFF_K=10                  # onoff: requests per burst
RPS_DIST_ONOFF_RATE_RATIO=10         # onoff: burst rate / mean rate
```

All values must be positive numbers (validated at startup; bad values produce a clear error before any benchmark runs). The mean is preserved at `(CONNECTIONS / target_rps) * 1000 ms` for every distribution and parameter setting, so the target RPS is unchanged — only the variance / shape changes. The actual params used are written into the `RPS throttle:` line of each run's output, so results stay self-documenting.

### `run.sh`

Single-run driver: stops any running nginx, starts it with the configured CPU affinity, runs one benchmark via `bench.sh`, and saves the full output (with UTC `Start:` / `End:` timestamps) to a file in `rst/`. Filenames encode every config parameter plus a UTC timestamp, so repeated runs accumulate without overwriting.

```bash
./run.sh                                       # use the defaults baked into run.sh
NGINX_CORES=0-7 WRK_CORES=8-11 ./run.sh        # override any setting via env var
TARGETRPS_DIST=pareto ./run.sh                 # switch the rps distribution shape
./run.sh --trace --plot                        # also capture + plot the request traffic
```

**Override env vars:** `NGINX_MASTER_CORE`, `NGINX_CORES`, `WRK_CORES`, `THREADS`, `CONNECTIONS`, `DURATION`, `TARGETRPS`, `TARGETRPS_DIST`, plus optional `RUN_TAG` injected into the filename.

If you set `WRK_CORES` but not `THREADS`, `THREADS` is auto-derived from the `WRK_CORES` core count (so the strict `--t == core-count` rule in `bench.sh` doesn't bite you with a stale default).

**Flags:**

| Flag | Description |
|---|---|
| `--trace` | Enable nginx `access_log` during the run; archive the `.access.log` next to the `.out`. The `.out` file is **self-documenting** — it ends with a `Plot:` line containing the exact `plot-rps.py` command to render later. |
| `--plot` | Also render a `.png` plot via `plot-rps.py` (requires `python3 + numpy + matplotlib`). No effect without `--trace`. |

#### Traffic visualization (`plot-rps.py`)

`plot-rps.py` reads an access log captured via `--trace` (one float timestamp per line, nginx's `$msec`) and produces a single PNG with two stacked subplots:

- **RPS over time** — instantaneous rate per 100 ms bucket; lets you eyeball bursts and ramp-up.
- **Inter-arrival histogram** — distribution of gaps between consecutive requests; the direct fingerprint of `--rps-dist` (const = spike, exp = exponential decay, pareto = heavy tail, onoff = bimodal).

Render any saved trace later:
```bash
python3 ./plot-rps.py rst/<run>.access.log rst/<run>.png
```
The exact command is also written into the matching `.out` file, so you can copy-paste it.

### `batch-run.sh`

Sweeps the Cartesian product of setting arrays, optionally repeated `REPEATS` times (outermost loop). Each iteration calls `run.sh` with the right env vars; outputs go to `rst/` with the repeat number in the filename. Edit the arrays at the top of the script to define a sweep.

```bash
# inside batch-run.sh
REPEATS=3
NGINX_CORES_arr=(1-8 1-16)
CONNECTIONS_arr=(100 500 1000)
DURATION_arr=(60)
TARGETRPS_arr=(1000 10000 inf)
# ... etc.

./batch-run.sh   # prints [batch X/total] progress for each combination
```

`run.sh` always restarts nginx, so each combination gets a clean server with the right affinity. The loop continues on per-run failures (e.g. mismatched `WRK_CORES` vs `THREADS`), so unattended sweeps stay running.

## Examples

```bash
# Match PTS default exactly
./bench.sh -t 40 -c 100 -d 90s

# Quick exploratory run with latency percentiles
./bench.sh -c 500 -d 15s --latency

# Sweep connection counts manually
for c in 1 20 100 500 1000; do
    echo "=== $c connections ==="
    ./bench.sh -c "$c" -d 30s --keep-server
done

# Custom HTTP header
./bench.sh -c 200 -H "Accept-Encoding: gzip"

# POST requests via Lua script
./bench.sh -s post.lua -c 100 -d 30s

# Throttle load to a fixed rate instead of max throughput
./bench.sh --rps 5000 -c 100 -d 30s

# Realistic Poisson arrivals at the same target rate
./bench.sh --rps 5000 --rps-dist exp -c 100 -d 60s

# Bursty load (heavy-tailed) for stress testing
./bench.sh --rps 5000 --rps-dist pareto -c 100 -d 60s

# Isolate load generator and server on separate cores
NGINX_CORES=0-7 ./start.sh
WRK_CORES=8-11 ./bench.sh -t 4 -c 100 --keep-server

# Capture and visualize the actual request traffic shape
./run.sh --trace --plot                              # produces .out + .access.log + .png
TARGETRPS_DIST=pareto ./run.sh --trace --plot        # see the heavy-tail in the histogram

# Tune the pareto tail without editing bench.sh
echo 'RPS_DIST_PARETO_ALPHA=1.2' >> config/rps-dist.sh
TARGETRPS_DIST=pareto ./run.sh --trace --plot        # heavier tail than the default α=1.5
```

## Directory Layout

After `install.sh`:

```
dist/
├── downloads/                  cached source tarballs (SHA256-verified)
│   ├── nginx-1.30.0.tar.gz
│   ├── wrk-4.2.0.tar.gz
│   └── http-test-files-1.tar.xz
├── nginx/
│   ├── sbin/nginx              nginx binary
│   ├── conf/nginx.conf         generated config (port 8089, SSL, worker_connections 10240)
│   ├── html/test.html          static file served during benchmarks
│   └── logs/                   error.log, nginx.pid
├── wrk                         wrk binary
├── localhost.cert              self-signed TLS certificate (RSA 4096, 365 days)
└── localhost.key               private key (chmod 600)

config/
└── rps-dist.sh                  tunable shape params for --rps-dist (sourced by bench.sh)

plot-rps.py                      render PNG plots from --trace .access.log files

rst/                             benchmark output files (created by run.sh / batch-run.sh)
├── nginx-m0-w1-8_wrk-cpu20-29-t10-c300-d100-rps1000-distconst_rep1_20260522-143005.out
├── nginx-m0-w1-8_wrk-cpu20-29-t10-c300-d100-rps1000-distconst_rep1_20260522-143005.access.log   # with --trace
└── nginx-m0-w1-8_wrk-cpu20-29-t10-c300-d100-rps1000-distconst_rep1_20260522-143005.png         # with --trace --plot
```
