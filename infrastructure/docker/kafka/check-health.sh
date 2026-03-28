#!/bin/bash
# ============================================
#  PulseStream — Kafka Broker Health Check
# ============================================

BOOTSTRAP_SERVER="${KAFKA_BOOTSTRAP_SERVER:-localhost:9092}"
EXIT_CODE=0

echo "============================================"
echo " Kafka Broker Health Check"
echo " Bootstrap: $BOOTSTRAP_SERVER"
echo "============================================"
echo ""

# ── 1. Broker connectivity ───────────────────
echo "1. Checking broker connectivity..."
if kafka-broker-api-versions --bootstrap-server "$BOOTSTRAP_SERVER" > /dev/null 2>&1; then
  echo "   ✓ Broker is reachable"
else
  echo "   ✗ Broker is NOT reachable"
  EXIT_CODE=1
fi
echo ""

# ── 2. Cluster metadata ─────────────────────
echo "2. Retrieving cluster metadata..."
METADATA=$(kafka-metadata --snapshot /var/lib/kafka/data/__cluster_metadata-0/00000000000000000000.log --cluster-id 2>/dev/null || echo "")
if [ -n "$METADATA" ]; then
  echo "   ✓ Cluster metadata available"
else
  echo "   ⚠ Cluster metadata not available (expected for single-node dev setup)"
fi
echo ""

# ── 3. Topic listing ────────────────────────
echo "3. Listing topics..."
TOPICS=$(kafka-topics --bootstrap-server "$BOOTSTRAP_SERVER" --list 2>/dev/null)
if [ $? -eq 0 ]; then
  TOPIC_COUNT=$(echo "$TOPICS" | grep -c "pulsestream" || echo "0")
  echo "   ✓ Topic listing works — $TOPIC_COUNT PulseStream topic(s) found"
  if [ -n "$TOPICS" ]; then
    echo "$TOPICS" | while read -r topic; do
      echo "     • $topic"
    done
  fi
else
  echo "   ✗ Failed to list topics"
  EXIT_CODE=1
fi
echo ""

# ── 4. Topic details ────────────────────────
echo "4. Checking topic partition details..."
for TOPIC in $(echo "$TOPICS" | grep "pulsestream"); do
  DESCRIBE=$(kafka-topics --bootstrap-server "$BOOTSTRAP_SERVER" --describe --topic "$TOPIC" 2>/dev/null)
  if [ $? -eq 0 ]; then
    PARTITION_COUNT=$(echo "$DESCRIBE" | grep -c "Partition:" || echo "?")
    echo "   ✓ $TOPIC — $PARTITION_COUNT partition(s)"
  else
    echo "   ✗ $TOPIC — failed to describe"
    EXIT_CODE=1
  fi
done
echo ""

# ── 5. Consumer group listing ────────────────
echo "5. Listing consumer groups..."
GROUPS=$(kafka-consumer-groups --bootstrap-server "$BOOTSTRAP_SERVER" --list 2>/dev/null)
if [ $? -eq 0 ]; then
  GROUP_COUNT=$(echo "$GROUPS" | grep -c "." || echo "0")
  echo "   ✓ Consumer group listing works — $GROUP_COUNT group(s)"
else
  echo "   ✗ Failed to list consumer groups"
  EXIT_CODE=1
fi
echo ""

# ── 6. Produce / consume test ───────────────
echo "6. Running produce/consume smoke test..."
TEST_TOPIC="pulsestream.healthcheck.test"
TEST_MESSAGE="healthcheck-$(date +%s)"

# Create ephemeral test topic
kafka-topics --bootstrap-server "$BOOTSTRAP_SERVER" \
  --create --topic "$TEST_TOPIC" --partitions 1 --replication-factor 1 \
  --config retention.ms=60000 > /dev/null 2>&1

# Produce
echo "$TEST_MESSAGE" | kafka-console-producer --bootstrap-server "$BOOTSTRAP_SERVER" --topic "$TEST_TOPIC" > /dev/null 2>&1

# Consume
CONSUMED=$(timeout 10 kafka-console-consumer --bootstrap-server "$BOOTSTRAP_SERVER" \
  --topic "$TEST_TOPIC" --from-beginning --max-messages 1 2>/dev/null)

if [ "$CONSUMED" = "$TEST_MESSAGE" ]; then
  echo "   ✓ Produce/consume roundtrip successful"
else
  echo "   ✗ Produce/consume roundtrip FAILED"
  EXIT_CODE=1
fi

# Cleanup test topic
kafka-topics --bootstrap-server "$BOOTSTRAP_SERVER" --delete --topic "$TEST_TOPIC" > /dev/null 2>&1
echo ""

# ── Summary ──────────────────────────────────
echo "============================================"
if [ "$EXIT_CODE" -eq 0 ]; then
  echo " ✓  All health checks PASSED"
else
  echo " ✗  Some health checks FAILED"
fi
echo "============================================"
exit $EXIT_CODE
