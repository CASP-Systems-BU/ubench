#!/bin/bash
#
# Allow one external IP to reach the Kafka brokers' EXTERNAL listener (port
# 9094, see ../kafka.sh / deployKafkaNode.sh). Run this any time you stand up
# a new, separate pipeline outside the CloudLab experiment LAN and need it to
# talk to Kafka (e.g. consume hubble-flows-resolved).
#
# This is network-level only: firewall access, nothing more. The EXTERNAL
# listener has no authentication or per-topic restriction — once an IP is
# allowed through, it has the same full read/write access any internal
# client has. Harden this later if it turns out to matter; for now it
# matches the plain "allow everyone" model the internal listener already
# uses.
#
# Usage:
#   ./grant_external_access.sh <ip>
#
# To revoke, remove the matching `ufw delete allow from <ip> to any port
# 9094` on each Kafka node by hand.
set -euo pipefail

IP="${1:?Usage: $0 <ip>}"
EXTERNAL_PORT="${KAFKA_EXTERNAL_PORT:-9094}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${SCRIPT_DIR}/config.json"

cfg() {
	python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2], ""); print(" ".join(v) if isinstance(v, list) else v)' \
		"${CONFIG}" "$1"
}

SSH_USER="${SSH_USER:-$(cfg nodes_user)}"
read -ra KAFKA_IPS <<<"$(cfg kafka_nodes)"
source "${SCRIPT_DIR}/nodes.sh"
KAFKA_NODES=(${KAFKA_NODES[@]+"${KAFKA_NODES[@]}"})

if [[ ${#KAFKA_NODES[@]} -eq 0 ]]; then
	echo "[!] No Kafka nodes registered — run register_cluster.py --kafka first." >&2
	exit 1
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)
on() { local host="$1"; shift; ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"; }

echo "[*] Allowing ${IP} -> port ${EXTERNAL_PORT} on ${#KAFKA_NODES[@]} Kafka node(s)..."
for host in "${KAFKA_NODES[@]}"; do
	on "$host" "sudo ufw allow from ${IP} to any port ${EXTERNAL_PORT} proto tcp"
done

echo "[*] Done. ${IP} can now reach Kafka via bootstrap.servers:"
printf '      '
for host in "${KAFKA_NODES[@]}"; do printf '%s:%s,' "$host" "$EXTERNAL_PORT"; done
echo
