# Cassandra Workshop Sandbox

A 3-node Apache Cassandra 5.0 cluster you can run on your laptop (Docker) or on AWS (3 separate EC2 hosts). Built for the DoiT × Gresham Cassandra workshop.

---

## What's included

| File | Purpose |
|------|---------|
| `docker/docker-compose.yml` | 3-node local cluster |
| `docker/deploy.sh` | One-command bring-up, health wait, schema load |
| `docker/teardown.sh` | Stop or wipe the local cluster |
| `cql/init.cql` | Demo keyspace + table + sample data |
| `cql/demo-queries.cql` | Guided queries for the workshop (consistency levels etc.) |
| `aws/cloudformation.yaml` | 3 EC2 instances (one Cassandra node each) + VPC |
| `aws/deploy.sh` | Deploy, check ring, stop/start/delete the AWS stack |

---

## Option A — Local (Docker)

**Requirements:** Docker Desktop with ≥ 5 GB RAM allocated to Docker.

```bash
# Start the cluster (~2-3 min on first run)
docker/deploy.sh

# Check all 3 nodes are UN (Up/Normal)
docker/deploy.sh --status

# Open a CQL shell
docker/deploy.sh --cqlsh

# Stop when done (data preserved)
docker/teardown.sh

# Stop + delete all data
docker/teardown.sh --wipe
```

The cluster exposes CQL on `localhost:9042`. All three nodes share a bridge network and form a ring automatically via gossip.

---

## Option B — AWS (3 EC2 hosts)

**Requirements:** AWS CLI configured (`aws configure`), an existing EC2 key pair.

Each Cassandra node runs on its own `t4g.small` EC2 instance — a genuinely distributed cluster across separate hosts.

```bash
cd aws

# Deploy (detects your public IP, locks SG to it)
./deploy.sh my-key-pair us-east-1

# Check ring once the stack is up (~8-10 min after CREATE_COMPLETE)
./deploy.sh --ring us-east-1

# Show node IPs and CQL endpoint
./deploy.sh --status us-east-1

# Stop all 3 instances to pause cost (~$0.05/hr while running)
./deploy.sh --stop us-east-1

# Restart
./deploy.sh --start us-east-1

# Tear down everything
./deploy.sh --delete us-east-1
```

**Cost:** 3 × t4g.small ≈ **$0.05/hr** (~$37/mo if always on). Stop instances between sessions — storage costs ~$0.24/mo per node while stopped.

---

## Demo schema

The setup script automatically loads `cql/init.cql`, which creates:

```cql
KEYSPACE sandbox  -- NetworkTopologyStrategy, RF=3
TABLE sensor_readings (sensor_id, reading_ts, temperature, humidity)
```

Run the workshop exercises from `cql/demo-queries.cql` to explore consistency levels, partition ownership, and the CAP theorem in action.

---

## Cluster details

| Setting | Value |
|---------|-------|
| Cassandra version | 5.0 |
| Cluster name | `SandboxCluster` |
| Datacenter | `dc1` |
| Replication factor | 3 |
| Snitch | `GossipingPropertyFileSnitch` |
| JVM heap per node | 512 MB (local) |
