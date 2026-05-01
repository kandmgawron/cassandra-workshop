#!/usr/bin/env bash
# One-command bring-up for the 3-node Cassandra sandbox.
#
# Usage:
#   ./setup.sh            # start cluster, wait for all 3 nodes UN, load schema
#   ./setup.sh --status   # show cluster status (nodetool status)
#   ./setup.sh --help     # show help
#
# Requirements: Docker Desktop (or any Docker Engine) with Compose v2.

set -euo pipefail

cd "$(dirname "$0")"

usage() {
  cat <<EOF
Cassandra 3-node sandbox

Commands:
  ./setup.sh             Start cluster and load sample schema
  ./setup.sh --status    Show 'nodetool status' from cassandra-1
  ./setup.sh --cqlsh     Open an interactive cqlsh shell
  ./setup.sh --help      Show this message

Teardown:
  ./teardown.sh          Stop containers (data preserved)
  ./teardown.sh --wipe   Stop containers AND delete volumes
EOF
}

case "${1:-}" in
  -h|--help)   usage; exit 0 ;;
  --status)    docker exec cassandra-1 nodetool status; exit 0 ;;
  --cqlsh)     exec docker exec -it cassandra-1 cqlsh ;;
esac

echo "==> Starting 3-node Cassandra cluster (this takes ~2-3 minutes on first run)"
docker compose up -d

echo "==> Waiting for all 3 nodes to reach UN (Up/Normal)..."
for i in $(seq 1 60); do
  up_count=$(docker exec cassandra-1 nodetool status 2>/dev/null \
    | awk '/^UN/ {c++} END {print c+0}')
  echo "    nodes UN: ${up_count}/3 (attempt ${i}/60)"
  if [ "${up_count}" = "3" ]; then
    break
  fi
  sleep 10
done

if [ "${up_count:-0}" != "3" ]; then
  echo "ERROR: cluster did not reach 3 UN nodes. Current status:"
  docker exec cassandra-1 nodetool status || true
  exit 1
fi

echo "==> Loading sample schema (cql/init.cql)"
docker cp ./cql/init.cql cassandra-1:/tmp/init.cql
docker exec cassandra-1 cqlsh -f /tmp/init.cql

echo
echo "Cluster ready. Try:"
echo "  ./setup.sh --status     # show ring"
echo "  ./setup.sh --cqlsh      # interactive shell"
echo "  Then paste queries from cql/demo-queries.cql"
