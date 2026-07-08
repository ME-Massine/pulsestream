#!/bin/bash
set -e

ZOOKEEPER_CONNECT="${KAFKA_ZOOKEEPER_CONNECT:-zookeeper:2181}"
BROKER_ID="${KAFKA_BROKER_ID:-1}"
MAX_ATTEMPTS="${KAFKA_BROKER_ID_WAIT_ATTEMPTS:-45}"
SLEEP_SECONDS="${KAFKA_BROKER_ID_WAIT_SECONDS:-2}"

cub zk-ready "$ZOOKEEPER_CONNECT" 30

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  ids_output=$(echo "ls /brokers/ids" | zookeeper-shell "$ZOOKEEPER_CONNECT" 2>/dev/null || true)
  ids_line=$(printf "%s\n" "$ids_output" | grep -E '^\[[0-9, ]*\]$' | tail -1 || true)

  if ! printf "%s" "$ids_line" | tr -d "[] " | tr "," "\n" | grep -Fxq "$BROKER_ID"; then
    exec /etc/confluent/docker/run
  fi

  echo "Waiting for stale Kafka broker id $BROKER_ID to expire in ZooKeeper ($attempt/$MAX_ATTEMPTS)"
  attempt=$((attempt + 1))
  sleep "$SLEEP_SECONDS"
done

echo "Timed out waiting for broker id $BROKER_ID to clear in ZooKeeper"
exit 1
