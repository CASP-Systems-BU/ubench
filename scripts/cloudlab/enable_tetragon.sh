#!/bin/bash
#
# Enable Tetragon (eBPF syscall/runtime observability). Runs on the MAIN node
# (it owns the kubeconfig from after_join.sh). setup_kube.py executes this
# after the workers join, gated by "enable_tetragon" in config.json.
# Idempotent (helm upgrade --install).
#
# Installs the Tetragon DaemonSet (one eBPF agent per node, cilium/tetragon
# Helm chart) with its default process exec/exit lifecycle tracking. No
# TracingPolicy is applied here -- that's deliberately separate: see
# tetragon-policies/ + tetra_policy.sh to turn on specific syscall hooks
# (connect, openat, ptrace, setuid, ...) and experiment with overhead per
# policy without touching the agent install itself.
#
# Every agent pod runs a 2nd container, `export-stdout`, that dumps the JSON
# event stream to its own stdout -- so cluster-wide live tail is just:
#   kubectl logs -n kube-system -l app.kubernetes.io/name=tetragon \
#       -c export-stdout -f --timestamps --prefix
# run_and_collect.sh's experiment-wide stream capture uses exactly this.

set -euo pipefail

TETRAGON_NAMESPACE="${TETRAGON_NAMESPACE:-kube-system}"

echo "[enable_tetragon] Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s || \
	echo "[enable_tetragon] WARN: not all nodes Ready, continuing anyway"

if ! command -v helm >/dev/null 2>&1; then
	echo "[enable_tetragon] Installing Helm"
	curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
		| sudo bash
fi

echo "[enable_tetragon] Adding/updating the cilium Helm repo"
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

echo "[enable_tetragon] Installing/upgrading Tetragon (namespace=${TETRAGON_NAMESPACE})"
helm upgrade --install tetragon cilium/tetragon \
	-n "${TETRAGON_NAMESPACE}" \
	--wait --timeout 5m

echo "[enable_tetragon] Waiting for the Tetragon DaemonSet to be ready on every node..."
kubectl -n "${TETRAGON_NAMESPACE}" rollout status ds/tetragon --timeout=180s

echo "[enable_tetragon] Done."
echo
echo "Live tail every node's syscall/process events:"
echo "  kubectl -n ${TETRAGON_NAMESPACE} logs -l app.kubernetes.io/name=tetragon -c export-stdout -f --timestamps --prefix"
echo
echo "No TracingPolicy is active yet (default: process exec/exit only.)"
echo "Turn on specific syscall hooks with:  ./tetra_policy.sh list|enable|disable <name>"
