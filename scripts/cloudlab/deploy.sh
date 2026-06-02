#!/bin/bash
#
# Deploy a ubench workload's services onto the CloudLab k8s cluster.
#
# Run this from the SAME machine you run bootstrap.sh from (your laptop / dev
# box). It copies k8s/<benchmark>/ up to the control node (node-0), applies the
# service manifests there, waits for the deployments to roll out, and does a
# heartbeat sweep across the services so you know the deploy is actually live.
#
# The cluster must already be up (./bootstrap.sh).
#
#   Usage:
#     ./deploy.sh                 # deploy boutique (default)
#     ./deploy.sh movie           # deploy a different workload (movie/social/hotel/...)
#
#   Env overrides:
#     CONTROL_HOST=apt190.apt.emulab.net   # control node (default: 1st entry in nodes.sh)
#     SSH_USER=yuhang                      # ssh user (default: yuhang)
#
# Prereqs (same as bootstrap.sh): `ssh <user>@<control-host>` works with your
# CloudLab key in the ssh-agent.
set -euo pipefail

BENCH="${1:-boutique}"
SSH_USER="${SSH_USER:-yuhang}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)

# Control node: the first hostname in nodes.sh (the shared node list, node-0).
# Override with CONTROL_HOST if you need to target a different node.
source "${SCRIPT_DIR}/nodes.sh"
MAIN="${CONTROL_HOST:-${NODES[0]:-}}"
if [[ -z "${MAIN}" ]]; then
	echo "[!] Could not determine the control node hostname. Set CONTROL_HOST=..." >&2
	exit 1
fi

LOCAL_DIR="${REPO_ROOT}/k8s/${BENCH}"
if [[ ! -d "${LOCAL_DIR}/yamls" ]]; then
	echo "[!] No manifests found at ${LOCAL_DIR}/yamls" >&2
	echo "    Available workloads: $(ls "${REPO_ROOT}/k8s" 2>/dev/null | tr '\n' ' ')" >&2
	exit 1
fi

echo "[*] Deploying '${BENCH}' to control node ${SSH_USER}@${MAIN}"

# 1. Copy the workload's k8s dir up to the control node (~ expands remotely).
echo "[*] Copying ${LOCAL_DIR} -> ${MAIN}:~/ubench/k8s/"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "mkdir -p ~/ubench/k8s"
scp "${SSH_OPTS[@]}" -r "${LOCAL_DIR}" "${SSH_USER}@${MAIN}:~/ubench/k8s/"

# 2. Apply + wait + verify, all on the control node. Heredoc is quoted ('EOF')
#    so it is sent verbatim; the benchmark name is passed as $1 to the remote
#    bash, and everything else is evaluated on the control node.
echo "[*] Applying manifests + verifying on ${MAIN}"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "bash -s" "${BENCH}" <<'EOF'
set -e
BENCH="$1"
YAMLS="${HOME}/ubench/k8s/${BENCH}/yamls"

kubectl apply -f "${YAMLS}/"

echo
echo "[*] Waiting for all deployments to become available (timeout 180s)..."
kubectl wait --for=condition=available --timeout=180s deploy --all

echo
echo "=== deployments ==="
kubectl get deploy

echo
echo "=== heartbeat sweep (by service name, from inside the cluster) ==="
POD=$(kubectl get pods -o jsonpath='{.items[0].metadata.name}')
rc=0
for svc in $(kubectl get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -vx kubernetes); do
	ok=0
	for _ in 1 2 3; do
		if kubectl exec "$POD" -- sh -c '(echo -e "GET /heartbeat HTTP/1.1\r\nHost: '"$svc"'\r\nConnection: close\r\n\r\n") | nc -w 3 '"$svc"' 80' 2>/dev/null | grep -qi heartbeat; then
			ok=1; break
		fi
		sleep 2
	done
	if [ "$ok" -eq 1 ]; then echo "  [OK]   $svc"; else echo "  [FAIL] $svc"; rc=1; fi
done
exit $rc
EOF

echo
echo "[*] '${BENCH}' deployed and verified on ${MAIN}."
