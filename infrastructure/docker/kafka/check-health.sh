#!/bin/bash
BOOTSTRAP_SERVER="${KAFKA_BOOTSTRAP_SERVER:-localhost:9092}"
MAX_ATTEMPTS="${KAFKA_HEALTHCHECK_MAX_ATTEMPTS:-15}"
SLEEP_SECONDS="${KAFKA_HEALTHCHECK_SLEEP_SECONDS:-2}"

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
  if kafka-broker-api-versions --bootstrap-server "$BOOTSTRAP_SERVER" > /dev/null 2>&1; then
    exit 0
  fi

  echo "Kafka is not ready yet ($attempt/$MAX_ATTEMPTS)"
  attempt=$((attempt + 1))
  sleep "$SLEEP_SECONDS"
done

echo "Kafka broker did not become ready at $BOOTSTRAP_SERVER"
exit 1
