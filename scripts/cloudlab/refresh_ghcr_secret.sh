#!/bin/bash
#
# Create/refresh the `ghcr-secret` k8s secret on node-0 from a GitHub CLI
# token. The secret doesn't persist across a cluster rebuild, but the token
# does — this pulls it from `gh` (authenticated once, ever, on your
# workstation) instead of minting a new PAT by hand each time.
#
# One-time setup (never repeat, survives reboots via the OS keychain):
#   gh auth login
#   gh auth refresh -h github.com -s read:packages
#   # if the package is linked to a private repo and read:packages alone 403s:
#   gh auth refresh -h github.com -s read:packages,repo
#
# Usage:
#   ./refresh_ghcr_secret.sh
#
# Safe to re-run: `kubectl apply` on a `--dry-run=client` manifest is an
# idempotent upsert. See ../../README-ghcr-secret-ubuntu-client.md for context.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v gh >/dev/null 2>&1 || {
	echo "[!] gh CLI not found — install it, then: gh auth login" >&2
	exit 1
}
gh auth status >/dev/null 2>&1 || {
	echo "[!] gh not authenticated — run: gh auth login" >&2
	exit 1
}

# ssh user: config.json `nodes_user` is the single source of truth
# (register_cluster.py writes it); SSH_USER env overrides.
CFG_USER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodes_user"])' \
	"${SCRIPT_DIR}/config.json" 2>/dev/null || true)"
USER="${SSH_USER:-${CFG_USER:-WillG}}"

# Public CloudLab hostnames live in nodes.sh (node-0 first = control plane).
source "${SCRIPT_DIR}/nodes.sh"
MAIN="${NODES[0]}"

GH_USER="$(gh api user -q .login)"

echo "[*] Refreshing ghcr-secret on ${MAIN} (github user: ${GH_USER})..."
# The token rides inside the YAML stream over stdin — never in a process
# argument, shell history, or node-0's disk. `create --dry-run=client` builds
# the manifest locally (on the ssh client side, i.e. here); `kubectl apply`
# runs on node-0 where kubectl is already configured.
gh auth token | ssh -A -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
	"${USER}@${MAIN}" "kubectl create secret docker-registry ghcr-secret \
		--docker-server=ghcr.io \
		--docker-username='${GH_USER}' \
		--docker-password=\"\$(cat)\" \
		--dry-run=client -o yaml | kubectl apply -f -"

echo "[*] Done."
