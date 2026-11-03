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
#           3. create the flow topic (RF=min(3,N), retention-capped), the
#              resolved-events + entities topics (see below), and a smoke topic
#           4. node-0: install kcat, write ~/ubench/kafka.env (KAFKA_BROKERS,
#              KAFKA_TOPIC) — run_and_collect.sh picks it up on the next --run
#           5. smoke test: produce + consume one message from node-0
#           6. provision a read-only kubeconfig for the resolver (node-0 has
#              no other way to hand out k8s API access to non-k8s hosts —
#              see provision_resolver_rbac.sh) and distribute it to every
#              Kafka node
#           7. every Kafka node: deploy kafka/flow_resolver.py + its venv,
#              start it as the transient systemd unit `ubench-flow-resolver`
#              — it consumes the raw flow topic, resolves+parses each flow
#              the same way gnnid's offline `ingest` does, and republishes to
#              KAFKA_RESOLVED_TOPIC (+ KAFKA_ENTITIES_TOPIC on every snapshot
#              refresh). The raw topic itself is untouched.
#           8. Kafka nodes also get an EXTERNAL listener (port 9094),
#              advertised via each node's *public* CloudLab hostname —
#              unauthenticated, same trust model as the internal listener.
#              It's only reachable once a specific IP is allowed through the
#              firewall; see kafka/grant_external_access.sh <ip>.
#   status  broker + resolver unit status, topic layout, node-0 wiring
#   down    stop the brokers + resolvers (data kept; `up` resumes them)
#   wipe    stop + delete broker/resolver data, and unwire node-0 (runs stop streaming)
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
#     KAFKA_RESOLVED_TOPIC     resolved-events topic (default hubble-flows-resolved)
#     KAFKA_ENTITIES_TOPIC     compacted entity-snapshot topic (default hubble-entities)
#     RESOLVER_REFRESH_INTERVAL_S  re-poll the k8s API this often on every
#                              Kafka node's resolver, to catch pod churn
#                              (default 0 = poll once at startup; topology is
#                              assumed mostly static for now)
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
RESOLVED_TOPIC="${KAFKA_RESOLVED_TOPIC:-hubble-flows-resolved}"
ENTITIES_TOPIC="${KAFKA_ENTITIES_TOPIC:-hubble-entities}"
SMOKE_TOPIC="ubench-smoke"
RESOLVER_REFRESH_INTERVAL_S="${RESOLVER_REFRESH_INTERVAL_S:-0}"

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
	# Always a clean stop+restart (not skip-if-active): deployKafkaNode.sh's
	# property rewrite + restart is idempotent and preserves on-disk data
	# (log.dirs untouched).
	on "$host" "bash -s" <<EOF
set -e
sudo systemctl stop ubench-kafka 2>/dev/null || true
sudo systemctl reset-failed ubench-kafka 2>/dev/null || true
sudo systemd-run --unit=ubench-kafka --uid="\$(id -un)" \
	--working-directory="\$HOME/${REMOTE_DIR}" \
	-p Restart=on-failure -p RestartSec=5 \
	/bin/bash "\$HOME/${REMOTE_DIR}/deployKafkaNode.sh" "${BROKER_IPS}" "${ip}" "" "${host}"
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
	echo "[*] Creating topic ${TOPIC} (${NK} partitions, RF=${RF}) + ${RESOLVED_TOPIC} + ${ENTITIES_TOPIC} + ${SMOKE_TOPIC}..."
	on_k0 "bash -s" <<EOF
set -e
${KAFKA_BIN}/kafka-topics.sh --bootstrap-server ${BOOTSTRAP} --create --if-not-exists \
	--topic ${TOPIC} --partitions ${NK} --replication-factor ${RF} \
	--config retention.ms=${RETENTION_MS} --config retention.bytes=${RETENTION_BYTES}
# Same retention as the raw topic — one resolved Event per kept raw flow.
${KAFKA_BIN}/kafka-topics.sh --bootstrap-server ${BOOTSTRAP} --create --if-not-exists \
	--topic ${RESOLVED_TOPIC} --partitions ${NK} --replication-factor ${RF} \
	--config retention.ms=${RETENTION_MS} --config retention.bytes=${RETENTION_BYTES}
# Compacted: one row per entity_id (keyed), so only the latest known value
# per pod/service/node is kept rather than an ever-growing log.
${KAFKA_BIN}/kafka-topics.sh --bootstrap-server ${BOOTSTRAP} --create --if-not-exists \
	--topic ${ENTITIES_TOPIC} --partitions ${NK} --replication-factor ${RF} \
	--config cleanup.policy=compact
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

# node-0 already has ~/.kube/config (after_join.sh); the Kafka nodes don't,
# and aren't k8s members, so there's no in-cluster ServiceAccount mount to
# fall back on. provision_resolver_rbac.sh (run on node-0 over this same ssh
# connection) creates a read-only ClusterRole/Binding + a non-expiring token
# Secret and prints a standalone kubeconfig built from them; we capture that
# and copy it out to every Kafka node.
RESOLVER_KUBECONFIG_LOCAL=""
provision_resolver_rbac() {
	echo "[*] Provisioning read-only k8s API access for the resolver (on ${MAIN})..."
	RESOLVER_KUBECONFIG_LOCAL="$(mktemp)"
	trap 'rm -f "${RESOLVER_KUBECONFIG_LOCAL}"' EXIT
	if ! on "$MAIN" "bash -s" <"${SCRIPT_DIR}/provision_resolver_rbac.sh" >"${RESOLVER_KUBECONFIG_LOCAL}"; then
		echo "[!] provision_resolver_rbac.sh failed on ${MAIN}" >&2
		return 1
	fi
	echo "[*] Distributing resolver kubeconfig to ${NK} Kafka node(s)..."
	each_kafka_parallel distribute_resolver_kubeconfig
}

distribute_resolver_kubeconfig() {
	local host="$1" ip="$2"
	on "$host" "mkdir -p ~/.kube"
	scp -q "${SSH_OPTS[@]}" "${RESOLVER_KUBECONFIG_LOCAL}" \
		"${SSH_USER}@${host}:~/.kube/resolver.conf"
}

# Remote layout for the resolver (separate from REMOTE_DIR/KAFKA_BIN above,
# which are Kafka's own).
RESOLVER_REMOTE_DIR="ubench-flow-resolver"

deploy_resolver() {
	local host="$1" ip="$2"
	echo "=== flow-resolver @ ${host} (${ip}) ==="
	on "$host" "bash -s" <<'EOF'
set -e
# `import venv` always succeeds (it's stdlib); the actual gap on a bare
# Ubuntu image is ensurepip, which only the python3-venv apt package
# provides — without it, `python3 -m venv` creates a venv directory but its
# pip never gets installed. Just ensure the package; apt is a cheap no-op
# if it's already there.
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv
mkdir -p ~/ubench-flow-resolver
EOF
	scp -q "${SSH_OPTS[@]}" -r "${SCRIPT_DIR}/kafka/flow_resolver.py" \
		"${SCRIPT_DIR}/kafka/flow_resolver_requirements.txt" "${SCRIPT_DIR}/kafka/flowlib" \
		"${SSH_USER}@${host}:~/${RESOLVER_REMOTE_DIR}/"
	on "$host" "bash -s" <<EOF
set -e
cd ~/${RESOLVER_REMOTE_DIR}
# A venv missing python3-venv (ensurepip) still creates bin/python before
# failing on pip — check for pip itself, and rebuild from scratch if it's
# not there, rather than leaving a half-built venv in place.
if [ ! -x venv/bin/pip ]; then
	rm -rf venv
	python3 -m venv venv
fi
venv/bin/pip install -q -r flow_resolver_requirements.txt
if systemctl is-active --quiet ubench-flow-resolver; then
	echo "[flow-resolver] already running on ${ip}, restarting to pick up any update"
	sudo systemctl stop ubench-flow-resolver
	sudo systemctl reset-failed ubench-flow-resolver 2>/dev/null || true
fi
sudo systemd-run --unit=ubench-flow-resolver --uid="\$(id -un)" \
	--working-directory="\$HOME/${RESOLVER_REMOTE_DIR}" \
	-p Restart=on-failure -p RestartSec=5 \
	--setenv=KAFKA_BROKERS="${BOOTSTRAP}" \
	--setenv=KAFKA_TOPIC="${TOPIC}" \
	--setenv=KAFKA_RESOLVED_TOPIC="${RESOLVED_TOPIC}" \
	--setenv=KAFKA_ENTITIES_TOPIC="${ENTITIES_TOPIC}" \
	--setenv=RESOLVER_KUBECONFIG="\$HOME/.kube/resolver.conf" \
	--setenv=RESOLVER_RUN_ID="${ip}" \
	--setenv=RESOLVER_REFRESH_INTERVAL_S="${RESOLVER_REFRESH_INTERVAL_S}" \
	"\$HOME/${RESOLVER_REMOTE_DIR}/venv/bin/python" "\$HOME/${RESOLVER_REMOTE_DIR}/flow_resolver.py"
echo "[flow-resolver] started ubench-flow-resolver on ${ip}"
EOF
}

# ---------------------------------------------------------------------------
kafka_up() {
	each_kafka_parallel start_broker
	wait_brokers
	create_topics
	wire_control
	smoke_test
	provision_resolver_rbac
	each_kafka_parallel deploy_resolver
	echo "[*] Kafka ready: ${BOOTSTRAP} topic=${TOPIC}. Next ./deploy.sh --run streams Hubble flows into it."
	echo "[*] Resolved events: ${RESOLVED_TOPIC}; entity snapshots: ${ENTITIES_TOPIC}."
}

kafka_status() {
	local h
	for h in "${KAFKA_NODES[@]}"; do
		printf '%-28s ubench-kafka: %-10s ubench-flow-resolver: %s\n' "$h" \
			"$(on "$h" 'systemctl is-active ubench-kafka' 2>/dev/null || true)" \
			"$(on "$h" 'systemctl is-active ubench-flow-resolver' 2>/dev/null || true)"
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
	on "$host" "sudo systemctl stop ubench-flow-resolver 2>/dev/null; sudo systemctl reset-failed ubench-flow-resolver 2>/dev/null; true"
	on "$host" "sudo systemctl stop ubench-kafka 2>/dev/null; sudo systemctl reset-failed ubench-kafka 2>/dev/null; true"
	echo "[kafka] stopped ${host} (${ip})"
}

wipe_broker() {
	local host="$1" ip="$2"
	stop_broker "$host" "$ip"
	on "$host" "sudo rm -rf ${KAFKA_DATA_DIR} ~/${REMOTE_DIR}/kafka_2.13-3.9.0/logs ~/${RESOLVER_REMOTE_DIR}/venv ~/.kube/resolver.conf"
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
