#!/bin/bash
# Runs `swift test` for PhotonKit, and if its output stops for STALL_SECONDS, prints a sample of every
# test process and fails, instead of waiting out the job's timeout. A hang then shows where it is.
set -uo pipefail

STALL_SECONDS="${STALL_SECONDS:-300}"
log="$(mktemp -t photon-test)"

swift test --package-path Packages/PhotonKit "$@" > >(tee "$log") 2>&1 &
test_pid=$!

last_size=-1
quiet=0
while kill -0 "$test_pid" 2>/dev/null; do
    sleep 10
    size=$(stat -f %z "$log")
    if [ "$size" -ne "$last_size" ]; then
        last_size=$size
        quiet=0
        continue
    fi
    quiet=$((quiet + 10))
    if [ "$quiet" -ge "$STALL_SECONDS" ]; then
        echo "::error::No test output for ${STALL_SECONDS} seconds. Sampling the test processes."
        for pid in $(pgrep -f 'PhotonKitPackageTests|swiftpm-testing-helper|xctest'); do
            echo "::group::sample $pid $(ps -o comm= -p "$pid")"
            sample "$pid" 5 -mayDie 2>&1 || true
            echo "::endgroup::"
        done
        pkill -P "$test_pid" 2>/dev/null
        pkill -f 'PhotonKitPackageTests|swiftpm-testing-helper' 2>/dev/null
        kill "$test_pid" 2>/dev/null
        wait "$test_pid" 2>/dev/null
        exit 1
    fi
done

wait "$test_pid"
