#!/usr/bin/env python3
"""Plot RPS over time and inter-arrival distribution from nginx access log.

Expected log format: one float per line, the $msec value (seconds with ms resolution).
"""
import sys
from pathlib import Path

try:
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError as e:
    sys.exit(f"ERROR: missing dependency ({e.name}). Run: python3 -m pip install matplotlib numpy")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: plot-rps.py <access-log> <output.png>")

    log_path = Path(sys.argv[1])
    png_path = Path(sys.argv[2])

    if not log_path.is_file():
        sys.exit(f"ERROR: access log not found: {log_path}")

    with log_path.open() as f:
        ts = np.array([float(line) for line in f if line.strip()])

    if len(ts) == 0:
        sys.exit("ERROR: access log is empty (no requests logged)")

    ts.sort()
    t_rel = ts - ts[0]
    duration = t_rel[-1] if t_rel[-1] > 0 else 1.0

    # -- RPS over time (100ms buckets)
    bucket_s = 0.1
    edges = np.arange(0, duration + bucket_s, bucket_s)
    counts, _ = np.histogram(t_rel, bins=edges)
    rps = counts / bucket_s
    centers = edges[:-1] + bucket_s / 2

    # -- Inter-arrival gaps (ms) — aggregate across all connections
    gaps_ms = np.diff(ts) * 1000.0

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8))

    mean_rps = len(ts) / duration
    ax1.plot(centers, rps, linewidth=0.7, color="#1f77b4")
    ax1.axhline(mean_rps, color="red", linestyle="--", linewidth=0.8, label=f"mean {mean_rps:.0f}")
    ax1.set_xlabel("Time (s)")
    ax1.set_ylabel("RPS (per 100ms bucket)")
    ax1.set_title(f"RPS over time — {len(ts)} requests over {duration:.1f}s")
    ax1.legend(loc="upper right")
    ax1.grid(True, alpha=0.3)

    # Clip histogram x-axis to 99.5th percentile so heavy tails don't squash the bulk
    xmax = np.percentile(gaps_ms, 99.5) if len(gaps_ms) > 100 else gaps_ms.max()
    ax2.hist(gaps_ms, bins=80, range=(0, xmax), edgecolor="none", color="#2ca02c")
    ax2.set_xlabel("Inter-arrival gap (ms)")
    ax2.set_ylabel("Count")
    ax2.set_title(
        f"Inter-arrival distribution — mean {gaps_ms.mean():.2f}ms, "
        f"median {np.median(gaps_ms):.2f}ms, max {gaps_ms.max():.0f}ms "
        f"(x clipped at 99.5th pct = {xmax:.1f}ms)"
    )
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(png_path, dpi=100)
    print(f"plot saved to {png_path}")


if __name__ == "__main__":
    main()
