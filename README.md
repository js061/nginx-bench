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
| `-u URL` | `https://127.0.0.1:8089/test.html` | Target URL |
| `-s SCRIPT` | — | LuaJIT script for custom request logic |
| `-H HEADER` | — | Add HTTP header (repeatable) |
| `--rps RPS` | — | Throttle to a target requests/sec (approximate) |
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

# Isolate load generator and server on separate cores
NGINX_CORES=0-7 ./start.sh
WRK_CORES=8-11 ./bench.sh -t 4 -c 100 --keep-server
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
```

## Comparison to PTS

| | PTS `batch-run nginx` | This pipeline |
|---|---|---|
| Connections | Fixed menu: 1, 20, 100, 200, 500, 1000, 4000 | Any value via `-c` |
| Duration | Hardcoded 90s | Any value via `-d` |
| Threads | Hardcoded `$(nproc)` | Configurable via `-t` |
| Latency stats | Not shown | `--latency` flag |
| Rate limiting | Not supported | `--rps` throttle |
| CPU affinity | Not supported | `NGINX_CORES` / `NGINX_MASTER_CORE` (server) and `WRK_CORES` (load generator) |
| Lua scripting | Not supported | `-s script.lua` |
| Custom headers | Not supported | `-H "Header: value"` |
| Result parsing | Automated into PTS result DB | Raw wrk output to stdout |
| Iterations | 3 runs per config, averaged | Manual |
