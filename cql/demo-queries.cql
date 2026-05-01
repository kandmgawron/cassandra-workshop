-- Demo queries to run after init.cql. Paste these into cqlsh
-- (`./cqlsh.sh`) to walk through Cassandra fundamentals.

-- 1. Where do my replicas live? Each row should be replicated on all 3 nodes.
--    Run from cqlsh:  TRACING ON;  then the SELECT, to see node coordination.
USE sandbox;

-- 2. Read with default consistency (LOCAL_ONE).
SELECT * FROM sensor_readings WHERE sensor_id = 'sensor-a';

-- 3. Force quorum reads/writes (2 of 3 replicas must respond). Try this,
--    then stop one node (`docker stop cassandra-3`) and rerun: still works.
CONSISTENCY QUORUM;
SELECT * FROM sensor_readings WHERE sensor_id = 'sensor-a';

-- 4. Force ALL: every replica must respond. Stop a node and this query fails,
--    which is the textbook CAP-theorem trade-off in action.
CONSISTENCY ALL;
SELECT * FROM sensor_readings WHERE sensor_id = 'sensor-a';

CONSISTENCY LOCAL_ONE;

-- 5. Show how partition key drives data placement.
--    `nodetool getendpoints sandbox sensor_readings sensor-a`
--    (run from a shell, not cqlsh) lists which nodes own this partition.
