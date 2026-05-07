#!/usr/bin/env bash
# One-command bring-up for the 3-node Cassandra sandbox.
#
# Usage:
#   ./deploy.sh            # start cluster, wait for all 3 nodes UN, load schema
#   ./deploy.sh --status   # show cluster status (nodetool status)
#   ./deploy.sh --cqlsh    # open an interactive cqlsh shell
#   ./deploy.sh --help     # show this message
#
# Requirements: Docker Desktop (or any Docker Engine) with Compose v2.

set -euo pipefail

cd "$(dirname "$0")"

usage() {
  cat <<EOF
Cassandra 3-node sandbox

Commands:
  ./deploy.sh             Start cluster and load sample schema
  ./deploy.sh --status    Show 'nodetool status' from the seed node
  ./deploy.sh --cqlsh     Open an interactive cqlsh shell
  ./deploy.sh --help      Show this message

Teardown:
  ./teardown.sh           Stop containers (data preserved)
  ./teardown.sh --wipe    Stop containers AND delete volumes
EOF
}

case "${1:-}" in
  -h|--help)   usage; exit 0 ;;
  --status)    docker exec cassandra nodetool status; exit 0 ;;
  --cqlsh)     exec docker exec -it cassandra cqlsh ;;
esac

echo "==> Starting 3-node Cassandra cluster (this takes ~2-3 minutes on first run)"
docker compose up -d

echo "==> Waiting for all 3 nodes to reach UN (Up/Normal)..."
for i in $(seq 1 60); do
  up_count=$(docker exec cassandra nodetool status 2>/dev/null \
    | awk '/^UN/ {c++} END {print c+0}')
  echo "    nodes UN: ${up_count}/3 (attempt ${i}/60)"
  if [ "${up_count}" = "3" ]; then
    break
  fi
  sleep 10
done

if [ "${up_count:-0}" != "3" ]; then
  echo "ERROR: cluster did not reach 3 UN nodes. Current status:"
  docker exec cassandra nodetool status || true
  exit 1
fi

echo "==> Loading sample schema (../cql/init.cql)"
docker cp ../cql/init.cql cassandra:/tmp/init.cql
docker exec cassandra cqlsh -f /tmp/init.cql

echo
echo "Cluster ready. Try:"
echo "  ./deploy.sh --status    # show ring"
echo "  ./deploy.sh --cqlsh     # interactive shell"
echo "  Then paste queries from ../cql/demo-queries.cql"
