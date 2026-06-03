#!/bin/bash
# Runs on the control node after workers join: set up kubeconfig, deploy the CNI
# and metrics-server. No interface pinning (flat single-NIC LAN -> flannel
# auto-detect is correct).
set -euo pipefail

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# CNI: vanilla flannel (auto-detects the iface from the default route).
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# metrics-server so `kubectl top nodes/pods` works (run.sh samples pod CPU/mem
# mid-test). On a kubeadm cluster the kubelet serving cert isn't signed by the
# cluster CA, so the default secure scrape fails — inject --kubelet-insecure-tls.
METRICS_URL="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
curl -fsSL "${METRICS_URL}" -o /tmp/metrics-server.yml
sed -i -E 's|^([[:space:]]*)- --kubelet-use-node-status-port|\1- --kubelet-insecure-tls\n\1- --kubelet-use-node-status-port|' /tmp/metrics-server.yml
kubectl apply -f /tmp/metrics-server.yml

echo 'source <(kubectl completion bash)' >> ~/.bashrc || true
