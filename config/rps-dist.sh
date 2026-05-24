# Tunable parameters for --rps-dist distributions.
# All values must be positive numbers. Edit any line to override the bench.sh defaults.

# normal: sigma as a fraction of the mean delay N.
#   delay = N + Z*(N*SIGMA_FACTOR), Z ~ N(0,1), clamped to >=0
RPS_DIST_NORMAL_SIGMA_FACTOR=0.333

# lognormal: sigma in log-space. Larger -> heavier right tail.
#   mean is preserved at N via mu = ln(N) - sigma^2/2.
RPS_DIST_LOGNORMAL_SIGMA=0.5

# pareto: shape alpha. Must be > 1 for finite mean.
#   Lower alpha -> heavier tail (alpha=1.5 is moderately heavy; alpha<2 -> infinite variance).
RPS_DIST_PARETO_ALPHA=1.5

# onoff (bursty): K requests per burst, burst rate ratio = burst rate / mean rate.
#   d_on = N / RATE_RATIO; d_off auto-derived so mean(delay) = N.
#   K=10, RATE_RATIO=10 -> bursts of 10 at 10x speed, then a 10*N silence.
RPS_DIST_ONOFF_K=100
RPS_DIST_ONOFF_RATE_RATIO=100
