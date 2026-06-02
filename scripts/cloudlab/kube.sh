#!/bin/bash

# this script is to set up the environment of kubernetes on Ubuntu 22.04
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

sudo apt update -yq
sudo apt install docker.io -yq
sudo systemctl enable docker

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update -yq
sudo apt install kubeadm kubelet kubectl -yq
sudo apt-mark hold kubeadm kubelet kubectl

sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

sudo tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
sudo tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system

# Pin kubelet to this node's experiment-LAN IP (10.0.0.x). Without this,
# kubelet derives its node IP from the default route, which on CloudLab is the
# *public* iface (eno1) -> the API server then reaches kubelets over public IPs
# and ufw (which only allows 10.0.0.0/24) drops exec/logs/top. Auto-detected so
# the same script works unchanged on every node.
NODE_IP=$(ip -4 -o addr show | awk '/ 10\.0\.0\./{print $4}' | cut -d/ -f1 | head -n1)
if [ -z "${NODE_IP}" ]; then
	echo "[!] No 10.0.0.x experiment-LAN address found on this node" >&2
	exit 1
fi
echo "KUBELET_EXTRA_ARGS=\"--cgroup-driver=cgroupfs --node-ip=${NODE_IP}\"" | sudo tee /etc/default/kubelet > /dev/null
sudo systemctl daemon-reload && sudo systemctl restart kubelet
sudo tee /etc/docker/daemon.json <<EOF
{
      "exec-opts": ["native.cgroupdriver=systemd"],
      "log-driver": "json-file",
      "log-opts": {
      "max-size": "100m"
   },

       "storage-driver": "overlay2"
       }
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker

# git clone https://github.com/aliceziyun/meshtrek.git ~/meshtrek