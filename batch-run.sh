#!/bin/bash

# -- number of times to repeat the whole sweep
REPEATS=1

# -- setting arrays
NGINX_MASTER_CORE_arr=(0)
NGINX_CORES_arr=(1-16)
WRK_CORES_arr=(20-29)
THREADS_arr=(10)
CONNECTIONS_arr=(100 200 300)
DURATION_arr=(100)
TARGETRPS_arr=(1000 inf)
TARGETRPS_DIST_arr=(const)

[[ -x ./run.sh ]] || { echo "ERROR: ./run.sh not found or not executable" >&2; exit 1; }

total=$(( REPEATS \
    * ${#NGINX_MASTER_CORE_arr[@]} * ${#NGINX_CORES_arr[@]} \
    * ${#WRK_CORES_arr[@]} * ${#THREADS_arr[@]} \
    * ${#CONNECTIONS_arr[@]} * ${#DURATION_arr[@]} \
    * ${#TARGETRPS_arr[@]} * ${#TARGETRPS_DIST_arr[@]} ))
count=0

echo "batch-run: $total run(s) total — $REPEATS repeat(s) of the sweep"

for rep in $(seq 1 "$REPEATS"); do                     # top layer: repeats
  for nm in "${NGINX_MASTER_CORE_arr[@]}"; do          # sub-layers: settings
    for nc in "${NGINX_CORES_arr[@]}"; do
      for wc in "${WRK_CORES_arr[@]}"; do
        for th in "${THREADS_arr[@]}"; do
          for cn in "${CONNECTIONS_arr[@]}"; do
            for du in "${DURATION_arr[@]}"; do
              for tr in "${TARGETRPS_arr[@]}"; do
                for trd in "${TARGETRPS_DIST_arr[@]}"; do
                  count=$(( count + 1 ))
                  echo ""
                  echo "=== [batch $count/$total] repeat=$rep | nginx-master=$nm nginx-cores=$nc | wrk-cores=$wc threads=$th conn=$cn dur=$du rps=$tr dist=$trd ==="
                  NGINX_MASTER_CORE="$nm" \
                  NGINX_CORES="$nc" \
                  WRK_CORES="$wc" \
                  THREADS="$th" \
                  CONNECTIONS="$cn" \
                  DURATION="$du" \
                  TARGETRPS="$tr" \
                  TARGETRPS_DIST="$trd" \
                  RUN_TAG="rep${rep}" \
                  ./run.sh
                done
              done
            done
          done
        done
      done
    done
  done
done

echo ""
echo "batch-run: all $total run(s) complete -> see rst/"
