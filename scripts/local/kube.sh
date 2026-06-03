#!/bin/bash
#
# Per-node environment setup for a self-hosted (non-CloudLab) cluster on
# Ubuntu 24.04 (cgroup v2). Run on every node by setup_kube.py. Installs the
# containerd runtime (via docker.io) + kubeadm, disables swap, sets the
# required sysctls, and aligns kubelet + containerd on the systemd cgroup driver.
#
# Unlike the CloudLab variant this does NOT pin kubelet to a specific LAN
# interface: on a flat single-NIC LAN the default-route IP already is the
# cluster IP, so kubelet auto-detection is correct.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

sudo apt update -yq
# curl/gnupg are needed below for the k8s apt key but aren't on minimal images.
sudo apt install -yq docker.io curl ca-certificates gnupg apt-transport-https
sudo systemctl enable docker

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update -yq
sudo apt install kubeadm kubelet kubectl -yq
sudo apt-mark hold kubeadm kubelet kubectl

# Disable swap (kubelet refuses to start with swap on). Also mask any systemd
# .swap units so it stays off across reboots.
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
for u in $(systemctl list-units --type swap --all --no-legend --plain | awk '{print $1}'); do
	sudo systemctl mask "$u" || true
done

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

# --- container runtime: containerd (the CRI kubeadm actually uses) ----------
# docker.io pulls in containerd, but its packaged config disables the CRI
# plugin and defaults to the cgroupfs driver -> kubeadm init would fail on
# Ubuntu 24.04 (cgroup v2). Regenerate a full default config (CRI enabled) and
# switch the runtime to the systemd cgroup driver.
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Match the kubelet cgroup driver to containerd (systemd). Also the kubeadm
# default on 1.30+; set explicitly. (Node IP is left to kubelet auto-detect.)
echo 'KUBELET_EXTRA_ARGS="--cgroup-driver=systemd"' | sudo tee /etc/default/kubelet > /dev/null
sudo systemctl daemon-reload && sudo systemctl restart kubelet

# docker daemon.json is irrelevant to Kubernetes (kubelet -> containerd, not
# docker), but keep docker itself usable with the cgroup-v2-correct driver.
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
