#!/bin/bash

KAFKA_CONTAINER=kafka

docker exec $KAFKA_CONTAINER kafka-topics \
  --create --topic telemetry.events.raw \
  --bootstrap-server localhost:9092 \
  --partitions 3 \
  --replication-factor 1

docker exec $KAFKA_CONTAINER kafka-topics \
  --create --topic telemetry.events.processed \
  --bootstrap-server localhost:9092 \
  --partitions 3 \
  --replication-factor 1

docker exec $KAFKA_CONTAINER kafka-topics \
  --create --topic telemetry.events.dlq \
  --bootstrap-server localhost:9092 \
  --partitions 1 \
  --replication-factor 1