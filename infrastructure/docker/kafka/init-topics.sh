#!/bin/bash
set -e

BOOTSTRAP_SERVER="${KAFKA_BOOTSTRAP_SERVER:-kafka:29092}"
REPLICATION_FACTOR="${KAFKA_REPLICATION_FACTOR:-1}"

echo "============================================"
echo " PulseStream — Kafka Topic Initialization"
echo "============================================"
echo ""
echo "Waiting for Kafka broker to be ready..."

# Wait until Kafka is reachable
MAX_RETRIES=30
RETRY_COUNT=0
until kafka-topics --bootstrap-server "$BOOTSTRAP_SERVER" --list > /dev/null 2>&1; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: Kafka broker not reachable after $MAX_RETRIES attempts. Exiting."
    exit 1
  fi
  echo "  Attempt $RETRY_COUNT/$MAX_RETRIES — broker not ready, retrying in 3s..."
  sleep 3
done
echo "Kafka broker is ready!"
echo ""

# ──────────────────────────────────────────────
# Topic definitions
#   Format: TOPIC_NAME:PARTITIONS:RETENTION_MS
# ──────────────────────────────────────────────
TOPICS=(
  "pulsestream.events.raw:3:604800000"
  "pulsestream.events.processed:3:604800000"
  "pulsestream.events.failed:1:2592000000"
  "pulsestream.notifications:2:259200000"
  "pulsestream.metrics:2:86400000"
)

for TOPIC_DEF in "${TOPICS[@]}"; do
  IFS=':' read -r TOPIC_NAME PARTITIONS RETENTION_MS <<< "$TOPIC_DEF"

  if kafka-topics --bootstrap-server "$BOOTSTRAP_SERVER" --describe --topic "$TOPIC_NAME" > /dev/null 2>&1; then
    echo "✓ Topic '$TOPIC_NAME' already exists — skipping."
  else
    echo "Creating topic '$TOPIC_NAME' (partitions=$PARTITIONS, retention=${RETENTION_MS}ms)..."
    kafka-topics --bootstrap-server "$BOOTSTRAP_SERVER" \
      --create \
      --topic "$TOPIC_NAME" \
      --partitions "$PARTITIONS" \
      --replication-factor "$REPLICATION_FACTOR" \
      --config retention.ms="$RETENTION_MS" \
      --config cleanup.policy=delete
    echo "✓ Topic '$TOPIC_NAME' created."
  fi
done

echo ""
echo "──────────────────────────────────────────"
echo " All topics initialized. Listing topics:"
echo "──────────────────────────────────────────"
kafka-topics --bootstrap-server "$BOOTSTRAP_SERVER" --list
echo ""
echo "Done."
