#!/bin/bash
#
# One-shot startup for a fresh CloudLab cluster: register -> bootstrap ->
# initial deployment test -> stratus install, with a verification gate after
# each stage so a failure stops the script instead of cascading silently into
# the next step.
#
# Usage:
#   1. Instantiate the CloudLab experiment (profile: d710 x5, or r320x5 once
#      available), grab the hostnames from the List View (node-0 first).
#   2. Paste them into NODE_HOSTS below.
#   3. ./verified_startup.sh
#
# Re-run safely: register_cluster.py / bootstrap.sh / deploy.sh are all
# idempotent, so re-running after fixing a failed stage just redoes that work.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# PASTE NEW NODE HOSTNAMES HERE (node-0 first -- becomes the control plane).
# From the CloudLab experiment's List View, in order.
NODE_HOSTS=(
	"pc508.emulab.net"
	"pc422.emulab.net"
	"pc428.emulab.net"
	"pc505.emulab.net"
	"pc426.emulab.net"
)

# IP base for the cluster LAN. Only needed if your profile's node-0 isn't
# 10.0.0.101 (register_cluster.py's own default) -- e.g. the old 10.0.0.1
# convention. Leave empty to use register_cluster.py's default.
IP_BASE=""

# Benchmark to use for the initial deployment smoke test.
BENCH="${BENCH:-boutique}"
# ---------------------------------------------------------------------------

log()  { printf '\n[*] %s\n' "$*"; }
ok()   { printf '  [OK]   %s\n' "$*"; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

[ "${#NODE_HOSTS[@]}" -ge 2 ] || die "NODE_HOSTS is empty/too short -- edit this script and paste in the new node hostnames first"

# ---- 1. register the cluster ------------------------------------------------
log "Registering cluster: ${NODE_HOSTS[*]}"
REG_ARGS=("${NODE_HOSTS[@]}" --check)
[ -n "${IP_BASE}" ] && REG_ARGS+=(--ip-base "${IP_BASE}")
python3 register_cluster.py "${REG_ARGS[@]}"
ok "nodes.sh + config.json written"

# ---- 2. bootstrap: kube + ghcr + secure ------------------------------------
MAIN_HOST="$(grep -oP '"\K[^"]+(?=")' nodes.sh | head -1)"
SSH_USER="$(python3 -c 'import json; print(json.load(open("config.json"))["nodes_user"])')"

# Resume-safe: a fresh `kube` run calls `kubeadm init`, which hard-fails with
# a wall of "port already in use" / "manifest already exists" preflight
# errors against a cluster that's already up (e.g. after a kube+audit+istio
# run succeeded earlier but the script got interrupted on a LATER step like
# ghcr/secure). Check for an existing kubeconfig on node-0 first and skip
# straight to ghcr+secure in that case instead of re-running kube blindly.
log "Checking whether node-0 already has an initialized cluster..."
if ssh -o ConnectTimeout=10 "${SSH_USER}@${MAIN_HOST}" "sudo test -f /etc/kubernetes/admin.conf" 2>/dev/null; then
	ok "cluster already initialized on ${MAIN_HOST} -- skipping kube bring-up, resuming at ghcr+secure"
	./bootstrap.sh ghcr
	./bootstrap.sh secure
else
	log "No existing cluster found -- running full bootstrap (kube, ghcr, secure)..."
	./bootstrap.sh all
fi
ok "bootstrap complete"

log "Verifying cluster nodes are Ready..."
ssh -o ConnectTimeout=10 "${SSH_USER}@${MAIN_HOST}" "kubectl get nodes" \
	|| die "nodes not reachable/Ready after bootstrap"

# ---- 3. initial deployment test --------------------------------------------
log "Deploying '${BENCH}' as an initial smoke test..."
./deploy.sh "${BENCH}"
ok "'${BENCH}' deployed and heartbeat-verified (see sweep output above)"

# ---- 4. stratus red team install -------------------------------------------
log "Installing + preflight-checking Stratus Red Team on node-0..."
./bootstrap.sh stratus
ok "stratus installed (see technique count + egress check above)"

log "Startup complete. Cluster is ready for: ./deploy.sh ${BENCH} --run  (+ stratus detonate ... from node-0)"
