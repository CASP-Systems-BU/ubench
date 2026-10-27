#!/bin/bash
#
# Stand up a 3-broker Kafka cluster on the dedicated CloudLab Kafka nodes and
# wire the control node (node-0) to stream Hubble flows into it during
# `deploy.sh --run`. Run this *from your local machine*, like bootstrap.sh.
#
# The Kafka nodes are extra nodes of the same experiment (same 10.0.0.x LAN)
# that do NOT join k8s; register them with
#   python3 register_cluster.py <k8s hosts...> --kafka <h1> <h2> <h3>
# which writes KAFKA_NODES (public hostnames, nodes.sh) and kafka_nodes /
# kafka_topic (internal IPs + topic, config.json).
#
#   up      1. every Kafka node: install Java, copy kafka/deployKafkaNode.sh,
#              start it as the transient systemd unit `ubench-kafka` (native
#              Kafka 3.9 KRaft, combined broker+controller, LAN listeners;
#              first start downloads Kafka)
#           2. wait until all brokers are registered
#           3. create the flow topic (RF=min(3,N), retention-capped) + a smoke topic
#           4. node-0: install kcat, write ~/ubench/kafka.env (KAFKA_BROKERS,
#              KAFKA_TOPIC) — run_and_collect.sh picks it up on the next --run
#           5. smoke test: produce + consume one message from node-0
#   status  broker count, topic layout, node-0 wiring
#   down    stop the brokers (data kept; `up` resumes them)
#   wipe    stop + delete broker data, and unwire node-0 (runs stop streaming)
#
#   Usage:
#     ./kafka.sh [up|status|down|wipe]        # default: up
#
#   Env:
#     SSH_USER                 ssh user (default: config.json nodes_user)
#     KAFKA_RETENTION_MS       flow topic retention (default 86400000 = 24h)
#     KAFKA_RETENTION_BYTES    per-partition cap (default 2 GiB). Broker data
#                              lives in /tmp on the small CloudLab root disk;
#                              each node holds ~RF x partitions/N of these.
#     KAFKA_READY_TIMEOUT_S    how long to wait for brokers (default 240)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.json"

cfg() {
	python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2], ""); print(" ".join(v) if isinstance(v, list) else v)' \
		"${CONFIG}" "$1"
}

SSH_USER="${SSH_USER:-$(cfg nodes_user)}"
read -ra KAFKA_IPS <<<"$(cfg kafka_nodes)"
TOPIC="$(cfg kafka_topic)"
TOPIC="${TOPIC:-hubble-flows}"
SMOKE_TOPIC="ubench-smoke"

source "${SCRIPT_DIR}/nodes.sh"
MAIN="${NODES[0]}"
KAFKA_NODES=(${KAFKA_NODES[@]+"${KAFKA_NODES[@]}"})

if [[ ${#KAFKA_NODES[@]} -eq 0 || ${#KAFKA_NODES[@]} -ne ${#KAFKA_IPS[@]} ]]; then
	echo "[!] No Kafka nodes registered (KAFKA_NODES in nodes.sh: ${#KAFKA_NODES[@]}," \
		"kafka_nodes in config.json: ${#KAFKA_IPS[@]})." >&2
	echo "    Run: python3 register_cluster.py <k8s hosts...> --kafka <h1> <h2> <h3>" >&2
	exit 1
fi

NK=${#KAFKA_IPS[@]}
RF=$(( NK < 3 ? NK : 3 ))
BROKER_IPS="$(IFS=,; echo "${KAFKA_IPS[*]}")"
BOOTSTRAP="$(printf '%s:9092,' "${KAFKA_IPS[@]}")"; BOOTSTRAP="${BOOTSTRAP%,}"
RETENTION_MS="${KAFKA_RETENTION_MS:-86400000}"
RETENTION_BYTES="${KAFKA_RETENTION_BYTES:-2147483648}"
READY_TIMEOUT_S="${KAFKA_READY_TIMEOUT_S:-240}"

# Remote layout on each Kafka node (deployKafkaNode.sh unpacks Kafka next to
# itself; KAFKA_DATA_DIR is its default /tmp/kraft-combined-logs).
REMOTE_DIR="ubench-kafka"
KAFKA_BIN="~/${REMOTE_DIR}/kafka_2.13-3.9.0/bin"
KAFKA_DATA_DIR="/tmp/kraft-combined-logs"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)
on()   { local host="$1"; shift; ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"; }
on_k0() { on "${KAFKA_NODES[0]}" "$@"; }

# Run "$@ <host> <ip>" against every Kafka node in parallel; fail if any fails.
each_kafka_parallel() {
	local pids=() rc=0 i
	for i in "${!KAFKA_NODES[@]}"; do
		"$@" "${KAFKA_NODES[$i]}" "${KAFKA_IPS[$i]}" &
		pids+=($!)
	done
	for i in "${!pids[@]}"; do
		if ! wait "${pids[$i]}"; then
			echo "[!] step failed on ${KAFKA_NODES[$i]}" >&2
			rc=1
		fi
	done
	return $rc
}

# ---------------------------------------------------------------------------
start_broker() {
	local host="$1" ip="$2"
	echo "=== kafka @ ${host} (${ip}) ==="
	on "$host" "bash -s" <<'EOF'
set -e
if ! command -v java >/dev/null 2>&1; then
	sudo apt-get update -qq
	sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openjdk-17-jre-headless
fi
mkdir -p ~/ubench-kafka
EOF
	scp -q "${SSH_OPTS[@]}" "${SCRIPT_DIR}/kafka/deployKafkaNode.sh" \
		"${SSH_USER}@${host}:~/${REMOTE_DIR}/"
	# Transient unit: outlives this ssh session, restarts on crash, stops cleanly.
	on "$host" "bash -s" <<EOF
set -e
if systemctl is-active --quiet ubench-kafka; then
	echo "[kafka] ubench-kafka already running on ${ip}"
	exit 0
fi
sudo systemctl reset-failed ubench-kafka 2>/dev/null || true
sudo systemd-run --unit=ubench-kafka --uid="\$(id -un)" \
	--working-directory="\$HOME/${REMOTE_DIR}" \
	-p Restart=on-failure -p RestartSec=5 \
	/bin/bash "\$HOME/${REMOTE_DIR}/deployKafkaNode.sh" "${BROKER_IPS}" "${ip}"
echo "[kafka] started ubench-kafka on ${ip}"
EOF
}

wait_brokers() {
	echo "[*] Waiting for ${NK} brokers to register (timeout ${READY_TIMEOUT_S}s; the first start downloads Kafka)..."
	if ! on_k0 "bash -s" <<EOF
deadline=\$(( \$(date +%s) + ${READY_TIMEOUT_S} ))
while [ \$(date +%s) -lt \$deadline ]; do
	if [ -x ${KAFKA_BIN}/kafka-broker-api-versions.sh ]; then
		n=\$(${KAFKA_BIN}/kafka-broker-api-versions.sh --bootstrap-server ${BOOTSTRAP} 2>/dev/null \
			| grep -c ':9092 (id:' || true)
		echo "[kafka] brokers up: \${n}/${NK}"
		[ "\${n}" -ge ${NK} ] && exit 0
	fi
	sleep 5
done
exit 1
EOF
	then
		echo "[!] Brokers did not come up. Recent unit logs:" >&2
		local h
		for h in "${KAFKA_NODES[@]}"; do
			echo "--- ${h}" >&2
			on "$h" "sudo journalctl -u ubench-kafka --no-pager -n 25" >&2 || true
		done
		return 1
	fi
}

create_topics() {
	echo "[*] Creating topic ${TOPIC} (${NK} partitions, RF=${RF}) + ${SMOKE_TOPIC}..."
	on_k0 "bash -s" <<EOF
set -e
${KAFKA_BIN}/kafka-topics.sh --bootstrap-server ${BOOTSTRAP} --create --if-not-exists \
	--topic ${TOPIC} --partitions ${NK} --replication-factor ${RF} \
	--config retention.ms=${RETENTION_MS} --config retention.bytes=${RETENTION_BYTES}
${KAFKA_BIN}/kafka-topics.sh --bootstrap-server ${BOOTSTRAP} --create --if-not-exists \
	--topic ${SMOKE_TOPIC} --partitions 1 --replication-factor ${RF} \
	--config retention.ms=3600000
${KAFKA_BIN}/kafka-topics.sh --bootstrap-server ${BOOTSTRAP} --describe --topic ${TOPIC}
EOF
}

# node-0 runs run_and_collect.sh; kafka.env is how it learns where to send flows.
wire_control() {
	echo "[*] Wiring control node ${MAIN} -> ${BOOTSTRAP} (topic ${TOPIC})..."
	on "$MAIN" "bash -s" <<EOF
set -e
if ! command -v kcat >/dev/null 2>&1 && ! command -v kafkacat >/dev/null 2>&1; then
	sudo apt-get update -qq
	sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq kcat \
		|| sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq kafkacat
fi
mkdir -p ~/ubench
cat > ~/ubench/kafka.env <<ENV
# Written by kafka.sh — sourced by run_and_collect.sh to stream Hubble flows.
KAFKA_BROKERS=${BOOTSTRAP}
KAFKA_TOPIC=${TOPIC}
ENV
echo "[kafka] wrote ~/ubench/kafka.env"
EOF
}

smoke_test() {
	echo "[*] Smoke test: node-0 -> ${SMOKE_TOPIC} -> node-0..."
	if on "$MAIN" "bash -s" <<EOF
set -e
K=\$(command -v kcat || command -v kafkacat)
tag="ubench-smoke-\$(date +%s)-\$\$"
echo "{\"smoke\":\"\${tag}\"}" | "\$K" -P -b ${BOOTSTRAP} -t ${SMOKE_TOPIC} -X acks=all
"\$K" -C -b ${BOOTSTRAP} -t ${SMOKE_TOPIC} -o -1 -e -q | grep -q "\${tag}"
EOF
	then
		echo "[+] Smoke test OK — Kafka is reachable from node-0"
	else
		echo "[!] Smoke test FAILED (produce/consume from node-0)" >&2
		return 1
	fi
}

# ---------------------------------------------------------------------------
kafka_up() {
	each_kafka_parallel start_broker
	wait_brokers
	create_topics
	wire_control
	smoke_test
	echo "[*] Kafka ready: ${BOOTSTRAP} topic=${TOPIC}. Next ./deploy.sh --run streams Hubble flows into it."
}

kafka_status() {
	local h
	for h in "${KAFKA_NODES[@]}"; do
		printf '%-28s ubench-kafka: %s\n' "$h" \
			"$(on "$h" 'systemctl is-active ubench-kafka' 2>/dev/null || true)"
	done
	on_k0 "bash -s" <<EOF || true
echo "--- registered brokers"
${KAFKA_BIN}/kafka-broker-api-versions.sh --bootstrap-server ${BOOTSTRAP} 2>/dev/null | grep ':9092 (id:'
echo "--- topic ${TOPIC}"
${KAFKA_BIN}/kafka-topics.sh --bootstrap-server ${BOOTSTRAP} --describe --topic ${TOPIC}
EOF
	echo "--- control node ${MAIN}"
	on "$MAIN" 'cat ~/ubench/kafka.env 2>/dev/null || echo "(no ~/ubench/kafka.env — runs will not stream to Kafka)"; command -v kcat || command -v kafkacat || echo "(kcat not installed)"' || true
}

stop_broker() {
	local host="$1" ip="$2"
	on "$host" "sudo systemctl stop ubench-kafka 2>/dev/null; sudo systemctl reset-failed ubench-kafka 2>/dev/null; true"
	echo "[kafka] stopped ${host} (${ip})"
}

wipe_broker() {
	local host="$1" ip="$2"
	stop_broker "$host" "$ip"
	on "$host" "sudo rm -rf ${KAFKA_DATA_DIR} ~/${REMOTE_DIR}/kafka_2.13-3.9.0/logs"
	echo "[kafka] wiped data on ${host} (${ip})"
}

kafka_down() { each_kafka_parallel stop_broker; }

kafka_wipe() {
	each_kafka_parallel wipe_broker
	on "$MAIN" "rm -f ~/ubench/kafka.env"
	echo "[kafka] removed ~/ubench/kafka.env on ${MAIN} (runs no longer stream to Kafka)"
}

case "${1:-up}" in
	up)     kafka_up ;;
	status) kafka_status ;;
	down)   kafka_down ;;
	wipe)   kafka_wipe ;;
	*) echo "usage: $0 [up|status|down|wipe]" >&2; exit 1 ;;
esac
