-- Sandbox schema for the 3-node Cassandra cluster.
-- Demonstrates the Cassandra basics worth showing in a workshop:
--   * keyspace with NetworkTopologyStrategy and replication factor 3
--     (one replica on each node)
--   * a partitioned table with a clustering key
--   * a few sample rows so SELECTs return data immediately

CREATE KEYSPACE IF NOT EXISTS sandbox
WITH replication = {
  'class': 'NetworkTopologyStrategy',
  'dc1': 3
};

USE sandbox;

CREATE TABLE IF NOT EXISTS sensor_readings (
  sensor_id   text,
  reading_ts  timestamp,
  temperature double,
  humidity    double,
  PRIMARY KEY (sensor_id, reading_ts)
) WITH CLUSTERING ORDER BY (reading_ts DESC);

INSERT INTO sensor_readings (sensor_id, reading_ts, temperature, humidity)
  VALUES ('sensor-a', '2026-05-01 09:00:00', 21.4, 47.2);
INSERT INTO sensor_readings (sensor_id, reading_ts, temperature, humidity)
  VALUES ('sensor-a', '2026-05-01 09:05:00', 21.6, 47.0);
INSERT INTO sensor_readings (sensor_id, reading_ts, temperature, humidity)
  VALUES ('sensor-a', '2026-05-01 09:10:00', 21.9, 46.8);
INSERT INTO sensor_readings (sensor_id, reading_ts, temperature, humidity)
  VALUES ('sensor-b', '2026-05-01 09:00:00', 19.1, 52.0);
INSERT INTO sensor_readings (sensor_id, reading_ts, temperature, humidity)
  VALUES ('sensor-b', '2026-05-01 09:05:00', 19.0, 52.4);
INSERT INTO sensor_readings (sensor_id, reading_ts, temperature, humidity)
  VALUES ('sensor-c', '2026-05-01 09:00:00', 23.7, 41.5);
