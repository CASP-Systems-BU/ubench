#!/usr/bin/env bash
# Native Kafka 3.9.0 in KRaft mode; requires Java and curl or wget.
# Usage: deployKafkaNode.sh <broker-ips> [this-node-ip] [isolated-run-directory]
# The optional arguments let local runs use the same deployment without SSH.
#
# Vendored from CASP-Systems-BU/disaggregated-streaming
# (scripts/kafka/deployKafkaNode.sh). ubench change: replication defaults are
# sized to the broker count (capped at 3, min ISR = RF-1) so a 3-node cluster
# survives a broker loss; upstream inherits the template's RF=1.
# Started by ../kafka.sh as the transient systemd unit `ubench-kafka`.
set -euo pipefail

KAFKA_VERSION="3.9.0"
KAFKA_PKG="kafka_2.13-${KAFKA_VERSION}.tgz"
KAFKA_DIR="$PWD/kafka_2.13-${KAFKA_VERSION}"
KAFKA_DOWNLOAD_URL="https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${KAFKA_PKG}"
BROKER_IPS=${1:?Usage: deployKafkaNode.sh broker-ips [this-node-ip] [isolated-run-directory]}
BROKER_IPS=$(printf '%s' "$BROKER_IPS" | tr -d ' ')
CURRENT_IP=${2:-}
RUN_DIR=${3:-}

# Legacy callers may omit this argument; the cluster launcher supplies its IP.
if [ -z "$CURRENT_IP" ]; then
  if command -v ip >/dev/null 2>&1; then
    CURRENT_IP=$(ip route get 1.1.1.1 | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
  else
    echo "Pass this node's IP as the second argument on non-Linux hosts." >&2
    exit 1
  fi
fi

IFS=',' read -ra IPS <<< "$BROKER_IPS"
VOTERS=""
NODE_ID=""
for index in "${!IPS[@]}"; do
  id=$((index + 1))
  ip=${IPS[$index]}
  VOTERS="${VOTERS:+${VOTERS},}${id}@${ip}:9093"
  if [ "$ip" = "$CURRENT_IP" ]; then
    NODE_ID=$id
  fi
done
if [ -z "$NODE_ID" ]; then
  echo "Node IP $CURRENT_IP is not in broker list $BROKER_IPS" >&2
  exit 1
fi
REPLICAS=$(( ${#IPS[@]} < 3 ? ${#IPS[@]} : 3 ))
MIN_ISR=$(( REPLICAS > 1 ? REPLICAS - 1 : 1 ))
java -version

if [ ! -d "$KAFKA_DIR" ]; then
  if [ ! -f "$KAFKA_PKG" ]; then
    echo "Downloading Kafka ${KAFKA_VERSION}..."
    if command -v curl >/dev/null 2>&1; then
      curl --fail --location --retry 3 --output "${KAFKA_PKG}.partial" "$KAFKA_DOWNLOAD_URL"
    else
      wget -O "${KAFKA_PKG}.partial" "$KAFKA_DOWNLOAD_URL"
    fi
    mv "${KAFKA_PKG}.partial" "$KAFKA_PKG"
  fi
  tar -xzf "$KAFKA_PKG"
fi

CONFIG="$KAFKA_DIR/config/kraft/reconfig-server.properties"
TEMPLATE="$KAFKA_DIR/config/kraft/server.properties"
KAFKA_DATA_DIR="/tmp/kraft-combined-logs"
if [ -n "$RUN_DIR" ]; then
  mkdir -p "$RUN_DIR"
  RUN_DIR=$(cd "$RUN_DIR" && pwd)
  CONFIG="$RUN_DIR/server.properties"
  KAFKA_DATA_DIR="$RUN_DIR/data"
  # Kafka uses LOG_DIR for JVM/application logs; log.dirs controls broker data.
  export LOG_DIR="$RUN_DIR/logs"
else
  export LOG_DIR="$KAFKA_DIR/logs"
  # Preserve any existing cluster tuning outside the deployment-owned keys.
  if [ -f "$CONFIG" ]; then
    TEMPLATE="$CONFIG"
  fi
fi

# The archive ships server.properties, not reconfig-server.properties. Replace
# active values portably (BSD and GNU awk); append keys absent in the template.
awk -v node="$NODE_ID" -v voters="$VOTERS" -v host="$CURRENT_IP" \
    -v partitions="${#IPS[@]}" -v data="$KAFKA_DATA_DIR" \
    -v replicas="$REPLICAS" -v minisr="$MIN_ISR" '
BEGIN {
  values["node.id"]=node
  values["controller.quorum.voters"]=voters
  values["listeners"]="PLAINTEXT://" host ":9092,CONTROLLER://" host ":9093"
  values["advertised.listeners"]="PLAINTEXT://" host ":9092"
  values["num.partitions"]=partitions
  values["log.dirs"]=data
  values["auto.create.topics.enable"]="true"
  values["message.timestamp.type"]="LogAppendTime"
  values["default.replication.factor"]=replicas
  values["min.insync.replicas"]=minisr
  values["offsets.topic.replication.factor"]=replicas
  values["transaction.state.log.replication.factor"]=replicas
  values["transaction.state.log.min.isr"]=minisr
}
{
  split($0, fields, "=")
  key=fields[1]
  if (key in values) {
    if (!(key in seen)) print key "=" values[key]
    seen[key]=1
  } else print
}
END {for (key in values) if (!(key in seen)) print key "=" values[key]}
' "$TEMPLATE" > "${CONFIG}.tmp"
mv "${CONFIG}.tmp" "$CONFIG"

mkdir -p "$KAFKA_DATA_DIR"
if [ ! -f "$KAFKA_DATA_DIR/meta.properties" ]; then
  echo ">>> Formatting Kafka storage"
  "$KAFKA_DIR/bin/kafka-storage.sh" format -t "hi5lupemSWui6TOy7mQlTA" -c "$CONFIG"
fi

echo ">>> Starting native Kafka node $NODE_ID at $CURRENT_IP:9092"
# Keep Kafka in the owned process group so the caller can stop this run only.
exec "$KAFKA_DIR/bin/kafka-server-start.sh" "$CONFIG"
