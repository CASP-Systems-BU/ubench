#!/bin/bash
#
# Deploy (or tear down) a ubench workload's services on the CloudLab k8s cluster.
#
# Run this from the SAME machine you run bootstrap.sh from (your laptop / dev
# box). It copies k8s/<benchmark>/ up to the control node (node-0), applies the
# service manifests there, waits for the deployments to roll out, and does a
# heartbeat sweep across the services so you know the deploy is actually live.
# With --down it deletes that workload's services instead.
#
# The cluster must already be up (./bootstrap.sh).
#
#   Usage:
#     ./deploy.sh                 # deploy boutique (default)
#     ./deploy.sh movie           # deploy a different workload (movie/social/hotel/...)
#     ./deploy.sh boutique --down # tear down a workload's services
#     ./deploy.sh boutique --run  # deploy, then drive the wrk workload against it
#
#   Env overrides:
#     CONTROL_HOST=apt190.apt.emulab.net   # control node (default: 1st entry in nodes.sh)
#     SSH_USER=yuhang                      # ssh user (default: yuhang)
#     REQUEST=mix THREADS=4 CONNS=16 DURATION=30   # --run wrk parameters
#
# Prereqs (same as bootstrap.sh): `ssh <user>@<control-host>` works with your
# CloudLab key in the ssh-agent.
set -euo pipefail

# Args: an optional workload name (default boutique) and an optional --down or
# --run flag, in any order: `./deploy.sh`, `./deploy.sh movie --down`, etc.
BENCH="boutique"
DOWN=0
RUN=0
for arg in "$@"; do
	case "$arg" in
		--down) DOWN=1 ;;
		--run)  RUN=1 ;;
		-*)     echo "[!] Unknown option: $arg (supported: --down, --run)" >&2; exit 1 ;;
		*)      BENCH="$arg" ;;
	esac
done
if [[ "${DOWN}" -eq 1 && "${RUN}" -eq 1 ]]; then
	echo "[!] --down and --run are mutually exclusive" >&2; exit 1
fi
SSH_USER="${SSH_USER:-yuhang}"

# wrk parameters used by --run (override via env). Mirror k8s/boutique/run.sh.
REQUEST="${REQUEST:-mix}"
THREADS="${THREADS:-4}"
CONNS="${CONNS:-16}"
DURATION="${DURATION:-30}"

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

# Copy the workload's manifests up to the control node (~ expands remotely).
# Both deploy and teardown operate on this remote directory so kubectl parses
# each file independently — robust regardless of trailing newlines, unlike
# hand-concatenating the files into one stream.
echo "[*] Copying ${LOCAL_DIR} -> ${MAIN}:~/ubench/k8s/"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "mkdir -p ~/ubench/k8s"
scp "${SSH_OPTS[@]}" -r "${LOCAL_DIR}" "${SSH_USER}@${MAIN}:~/ubench/k8s/"

REMOTE_YAMLS="~/ubench/k8s/${BENCH}/yamls"

# --- teardown -------------------------------------------------------------
# NOTE: workloads share generic service names (every one has a "frontend"), so
# only tear down the workload that is actually deployed — running `<other>
# --down` can delete objects that belong to the workload currently running.
if [[ "${DOWN}" -eq 1 ]]; then
	echo "[*] Tearing down '${BENCH}' on ${SSH_USER}@${MAIN}"
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "kubectl delete --ignore-not-found -f ${REMOTE_YAMLS}/"
	echo
	echo "=== remaining workload resources (default namespace) ==="
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "kubectl get deploy,svc"
	echo
	echo "[*] '${BENCH}' torn down on ${MAIN}."
	exit 0
fi

# Apply + wait + verify, all on the control node. Heredoc is quoted ('EOF') so
# it is sent verbatim; the benchmark name is passed as $1 to the remote bash,
# and everything else is evaluated on the control node.
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

# --- run the wrk workload (optional) --------------------------------------
# scripts/run.sh drives the benchmark: it deploys the load-generator client pod
# (public image yizhengx/mucache:client) and execs `wrk` against the services.
# It expects to live at ~/ubench/scripts/run.sh with ~/ubench/client/ alongside
# the k8s manifests, so copy those up before invoking it on the control node.
# (`kubectl top` inside run.sh needs metrics-server, which isn't installed — it
# prints an error there but is non-fatal and does not affect the wrk result.)
if [[ "${RUN}" -eq 1 ]]; then
	echo
	echo "[*] Copying run.sh + client/ to ${MAIN}"
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "mkdir -p ~/ubench/scripts"
	scp "${SSH_OPTS[@]}" "${REPO_ROOT}/scripts/run.sh" "${SSH_USER}@${MAIN}:~/ubench/scripts/"
	scp "${SSH_OPTS[@]}" -r "${REPO_ROOT}/client" "${SSH_USER}@${MAIN}:~/ubench/"

	echo "[*] Running wrk: ${BENCH} request=${REQUEST} threads=${THREADS} conns=${CONNS} duration=${DURATION}s"
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
		"bash ~/ubench/scripts/run.sh ${BENCH} ${REQUEST} ${THREADS} ${CONNS} ${DURATION}"
	echo
	echo "[*] wrk workload finished on ${MAIN}."
fi
