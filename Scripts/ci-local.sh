#!/usr/bin/env bash
# Runs the CI checks locally: the Linux job in Docker via nektos/act, the macOS job natively.
# Needs: act, and a running Docker engine (Colima or Docker Desktop). Usage: Scripts/ci-local.sh [linux|macos|all]
set -euo pipefail
cd "$(dirname "$0")/.."
what="${1:-all}"

linux() {
  # --container-daemon-socket - : Colima cannot bind-mount its docker socket into the job container.
  act -j core-linux --container-architecture linux/arm64 -P ubuntu-latest=swift:6.0 --container-daemon-socket -
}
macos() {
  swift build -c release
  swift test
  swift test --sanitize=address
  swift test --sanitize=thread
  swift test --sanitize=undefined
}

case "$what" in
  linux) linux ;;
  macos) macos ;;
  all) linux; macos ;;
  *) echo "usage: $0 [linux|macos|all]"; exit 2 ;;
esac
