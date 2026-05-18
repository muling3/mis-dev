#!/usr/bin/env bash
# Create the minimum set of Kafka topics from the architecture docs.
set -euo pipefail

CONTAINER="${KAFKA_CONTAINER:-mis-dev-kafka-1}"
BROKER="${KAFKA_BROKER:-kafka:9092}"

READY_TIMEOUT="${KAFKA_READY_TIMEOUT:-90}"

# Wait for the broker to accept connections. `docker compose up -d` returns
# before Kafka is listening and the container has no healthcheck, so poll.
echo "→ waiting for Kafka broker ($CONTAINER) — up to ${READY_TIMEOUT}s"
deadline=$(( $(date +%s) + READY_TIMEOUT ))
until docker exec "$CONTAINER" kafka-broker-api-versions \
        --bootstrap-server "$BROKER" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "✗ Kafka not ready after ${READY_TIMEOUT}s" >&2
    exit 1
  fi
  sleep 3
done
echo "✓ Kafka broker ready"

topics=(
  mis.audit
  mis.dlq
  mis.cases
  mis.cases.sla
  mis.applications
  mis.documents
  mis.notifications
  mis.sandbox.verdicts
)

for t in "${topics[@]}"; do
  echo "→ creating $t"
  docker exec "$CONTAINER" kafka-topics \
    --bootstrap-server "$BROKER" \
    --create --if-not-exists \
    --topic "$t" --partitions 1 --replication-factor 1
done

docker exec "$CONTAINER" kafka-topics --bootstrap-server "$BROKER" --list
