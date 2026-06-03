#!/bin/bash
set -euo pipefail

# Internal (experiment LAN) IP to advertise the API server on.
# Passed in by setup_kube.py; defaults to the main node's internal IP.
ADVERTISE_ADDR="${1:-10.0.0.101}"

sudo kubeadm init \
	--apiserver-advertise-address="${ADVERTISE_ADDR}" \
	--pod-network-cidr=10.244.0.0/16 \
	--upload-certs
