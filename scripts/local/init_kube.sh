#!/bin/bash
set -euo pipefail

# Advertise the API server on the control node's LAN IP (passed by setup_kube.py
# as config nodes[0]) so the generated join command targets that IP. On a flat
# single-NIC LAN this equals the default-route IP, but passing it explicitly is
# robust even when extra interfaces (docker0, etc.) exist.
ADVERTISE_ADDR="${1:?control node IP required as arg 1}"

sudo kubeadm init \
	--apiserver-advertise-address="${ADVERTISE_ADDR}" \
	--pod-network-cidr=10.244.0.0/16 \
	--upload-certs
