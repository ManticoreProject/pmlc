#!/bin/bash

# this script should be run from the root of the manticore source dir.
# it assumes the following:
#
# 1. Manticore's already built.
# 2. SML/NJ 64-bit is available in /usr/smlnj64/bin

set -ex

MC_DIR=$(pwd)
TRIALS=5
RESULTS_DIR=${MC_DIR}/results

SMLNJ64_BIN_PATH=/usr/smlnj64/bin

# make sure `perf stat` works, since the benchmark's conf script doesn't
# check for this but it's required.
if ! perf stat echo; then
  # assuming it's a lack of linux-tools for the host's particular kernel,
  # try installing it
  apt-get update && apt-get install -y linux-tools-$(uname -r)

  # recheck
  if ! perf stat echo; then
    set +ex
    echo -e "perf is not working! If you're in Docker, make sure"
    echo -e "you passed --privileged or --cap-add sys_admin to docker run!"
    exit 1
  fi
fi

# run the benchmarks
mkdir "${RESULTS_DIR}"
cd src/benchmarks/drivers
PATH=${SMLNJ64_BIN_PATH}:${PATH} ./pldi20.sh "${MC_DIR}" "${RESULTS_DIR}" ${TRIALS}

# generate plots
LANG=C.UTF-8 LC_ALL=C.UTF-8 ./plotall.sh "${RESULTS_DIR}"

# make the message below not ugly
set +ex
echo "----------------------------------------------------------------------"
echo "Benchmarking complete!"
echo "Results are in ${RESULTS_DIR}"
echo "Keep this Docker session alive and follow instructions in the README"
echo "to copy the results to your local filesystem!"