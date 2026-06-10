#!/bin/bash
#
# Orchestrate the whole CloudLab k8s cluster setup *from your local machine*.
#
# Run this from wherever you normally `ssh yuhang@apt141.apt.emulab.net` from
# (your laptop / dev box). It will, over the *public* CloudLab hostnames:
#
#   kube      1. copy scripts/cloudlab/ up to the main node (node-0)
#             2. run setup_kube.py there, which brings up the cluster over the
#                internal 10.0.0.x network (agent-forwarded so node-0 can SSH
#                into the workers with your CloudLab key)
#   secure    3. on every node: apply the ufw rules (incl. OpenSSH) and harden
#                sshd -> key-only auth, no password login, no root login
#
#   Usage:
#     ./bootstrap.sh            # kube setup, then secure (default)
#     ./bootstrap.sh kube       # only copy + run setup_kube.py
#     ./bootstrap.sh secure     # only apply firewall + SSH hardening
#                                 (alias: `firewall`)
#
# Prereqs on the machine you run this from:
#   * `ssh yuhang@apt141.apt.emulab.net` already works (key in your ssh-agent)
#   * that key is what authenticates to all the CloudLab nodes (it is, by
#     default) — `ssh -A` forwards it so node-0 can reach the workers.
#
set -euo pipefail

USER="yuhang"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Public CloudLab hostnames live in nodes.sh (node-0 first = control plane).
source "${SCRIPT_DIR}/nodes.sh"
MAIN="${NODES[0]}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)

# ---------------------------------------------------------------------------
setup_secure() {
	# Firewall + SSH hardening, all in one SSH session per node.
	#
	# ufw: allow-rules are added *before* `ufw enable` (reverse of the order
	# you pasted) so there's never a window where the firewall is live with no
	# allows. OpenSSH is now explicitly allowed, so port 22 stays reachable.
	#
	# sshd hardening is written as a drop-in (00-hardening.conf sorts before
	# Ubuntu's 50-cloud-init.conf, and sshd uses first-match-wins, so it
	# overrides the cloud-init `PasswordAuthentication yes`). The config is
	# validated with `sshd -t` and only then reloaded; if it's invalid we
	# delete the drop-in and bail so we never reload a broken sshd.
	local fw
	fw=$(cat <<'EOF'
set -e
# --- firewall ---
# cloudlab webui
sudo ufw allow from 155.98.33.74
# home
sudo ufw allow from 172.112.90.89
# BU
sudo ufw allow from 128.197.29.0/24
sudo ufw allow from 128.197.28.0/24
# internal
sudo ufw allow from 10.0.0.0/24
# k8s pod CIDR (10.244.0.0/16, set by kubeadm --pod-network-cidr and honored by
# the CNI): pods reach host services (notably the API server at 10.0.0.101:6443,
# fronted by the 10.96.0.1 ClusterIP) with a pod-IP source. Cross-node pod egress
# is masqueraded to a 10.0.0.x source, but a pod on the same node as the API
# server (e.g. CoreDNS on the control plane) is delivered locally and keeps its
# 10.244.x source — so without this rule it hits INPUT, gets dropped, CoreDNS
# never reaches the API and stays NotReady, and cluster DNS has no endpoints.
# CNI-agnostic: holds for flannel or Cilium as long as the pod CIDR is unchanged.
sudo ufw allow from 10.244.0.0/16
# ssh (key-only auth is enforced below)
sudo ufw allow OpenSSH
echo y | sudo ufw enable
sudo systemctl start ufw
sudo systemctl enable ufw
sudo ufw status

# --- ssh hardening: key-only auth, no root login ---
sudo tee /etc/ssh/sshd_config.d/00-hardening.conf >/dev/null <<'CONF'
# Managed by ubench bootstrap.sh
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
CONF
if sudo /usr/sbin/sshd -t; then
	sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd
	echo "[+] sshd hardened: password & root login disabled"
else
	echo "[!] sshd config invalid — reverting hardening, leaving sshd untouched" >&2
	sudo rm -f /etc/ssh/sshd_config.d/00-hardening.conf
	exit 1
fi
EOF
)
	echo "[*] Applying firewall + SSH hardening on all nodes..."
	local rc=0
	for host in "${NODES[@]}"; do
		echo "=== secure @ ${host} ==="
		if ! ssh "${SSH_OPTS[@]}" "${USER}@${host}" "bash -s" <<<"$fw"; then
			echo "[!] secure step FAILED on ${host}" >&2
			rc=1
		fi
	done
	return $rc
}

# ---------------------------------------------------------------------------
setup_kube() {
	echo "[*] Copying setup scripts to main node (${MAIN})..."
	ssh "${SSH_OPTS[@]}" "${USER}@${MAIN}" "mkdir -p ~/ubench/scripts/cloudlab"
	scp "${SSH_OPTS[@]}" \
		"${SCRIPT_DIR}"/*.py "${SCRIPT_DIR}"/*.sh "${SCRIPT_DIR}"/config.json \
		"${USER}@${MAIN}:~/ubench/scripts/cloudlab/"

	echo "[*] Running setup_kube.py on main node (-A forwards your key to reach workers)..."
	ssh -A "${SSH_OPTS[@]}" "${USER}@${MAIN}" \
		"cd ~/ubench/scripts/cloudlab && python3 setup_kube.py"
}

# ---------------------------------------------------------------------------
case "${1:-all}" in
	kube)            setup_kube ;;
	secure|firewall) setup_secure ;;
	all)             setup_kube; setup_secure ;;
	*) echo "usage: $0 [kube|secure|all]" >&2; exit 1 ;;
esac

echo "[*] Done."
