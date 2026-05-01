#!/usr/bin/env bash
# Stop the sandbox cluster.
#
#   ./teardown.sh         # stop containers, keep volumes (data persists)
#   ./teardown.sh --wipe  # stop containers AND delete volumes (fresh start next time)

set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--wipe" ]; then
  echo "==> Stopping containers and removing volumes (all data will be lost)"
  docker compose down -v
else
  echo "==> Stopping containers (volumes preserved; rerun ./setup.sh to resume)"
  docker compose down
fi
