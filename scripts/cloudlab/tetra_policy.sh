#!/bin/bash
#
# List / enable / disable individual Tetragon TracingPolicies on the live
# cluster, without touching the Tetragon agent install itself (enable_tetragon.sh).
# This is the "pick a syscall, measure it, swap it out" scaffold: each policy
# in tetragon-policies/*.yaml is its own independent TracingPolicy CRD, so
# enabling/disabling one never restarts the agent or affects the others.
#
# Usage:
#   ./tetra_policy.sh list
#   ./tetra_policy.sh enable  openat
#   ./tetra_policy.sh disable openat
#   ./tetra_policy.sh enable  all        # every policy in tetragon-policies/
#   ./tetra_policy.sh disable all
#
# "<name>" is a tetragon-policies/<name>.yaml filename (without .yaml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="${SCRIPT_DIR}/tetragon-policies"
cd "${SCRIPT_DIR}"

CFG_USER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodes_user"])' \
	"${SCRIPT_DIR}/config.json" 2>/dev/null || true)"
SSH_USER="${SSH_USER:-${CFG_USER:-WillG}}"
source "${SCRIPT_DIR}/nodes.sh"
MAIN="${NODES[0]}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)

usage() { echo "usage: $0 {list|enable|disable} [<name>|all]" >&2; exit 1; }

ACTION="${1:-}"
NAME="${2:-}"
[ -n "${ACTION}" ] || usage

list_policies() {
	echo "Available policies (tetragon-policies/*.yaml):"
	for f in "${POLICY_DIR}"/*.yaml; do
		[ -f "$f" ] || continue
		printf '  %-16s %s\n' "$(basename "${f%.yaml}")" \
			"$(awk -F'"' '/^  name:/{print $2; exit}' "$f")"
	done
	echo
	echo "Currently applied on the cluster:"
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
		"kubectl get tracingpolicies.cilium.io -o custom-columns=NAME:.metadata.name,STATE:.status.state 2>/dev/null" \
		|| echo "  (none, or cluster unreachable)"
}

apply_or_delete() {
	local verb="$1" name="$2"
	local file="${POLICY_DIR}/${name}.yaml"
	[ -f "${file}" ] || { echo "[tetra_policy] no such policy: ${name} (see './tetra_policy.sh list')" >&2; exit 1; }

	echo "[tetra_policy] ${verb}ing ${name}..."
	scp "${SSH_OPTS[@]}" "${file}" "${SSH_USER}@${MAIN}:~/ubench_tetragon_policy_${name}.yaml" >/dev/null
	if [ "${verb}" = "apply" ]; then
		ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
			"kubectl apply -f ~/ubench_tetragon_policy_${name}.yaml"
	else
		ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
			"kubectl delete -f ~/ubench_tetragon_policy_${name}.yaml --ignore-not-found"
	fi
}

case "${ACTION}" in
	list)
		list_policies
		;;
	enable|disable)
		[ -n "${NAME}" ] || usage
		VERB="apply"; [ "${ACTION}" = "disable" ] && VERB="delete"
		if [ "${NAME}" = "all" ]; then
			for f in "${POLICY_DIR}"/*.yaml; do
				apply_or_delete "${VERB}" "$(basename "${f%.yaml}")"
			done
		else
			apply_or_delete "${VERB}" "${NAME}"
		fi
		echo "[tetra_policy] done. Current state:"
		list_policies
		;;
	*) usage ;;
esac
