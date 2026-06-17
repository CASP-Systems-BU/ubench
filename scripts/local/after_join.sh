#!/bin/bash
# Runs on the control node after workers join: set up kubeconfig, deploy the CNI
# and metrics-server. Single flat NIC here, so (unlike the CloudLab variant) no
# device pinning is needed — Cilium auto-detects the only interface.
set -euo pipefail

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# CNI: Cilium (eBPF) + Hubble observability, replacing flannel. ipam.mode=kubernetes
# honors the kubeadm --pod-network-cidr; kube-proxy is left in place for a drop-in
# swap. Hubble gives the network-flow/DNS/drop metric source used by the collector.
CILIUM_CLI_VERSION="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
curl -fsSL "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" -o /tmp/cilium.tgz
sudo tar -C /usr/local/bin -xzf /tmp/cilium.tgz
HUBBLE_CLI_VERSION="$(curl -fsSL https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)"
curl -fsSL "https://github.com/cilium/hubble/releases/download/${HUBBLE_CLI_VERSION}/hubble-linux-amd64.tar.gz" -o /tmp/hubble.tgz
sudo tar -C /usr/local/bin -xzf /tmp/hubble.tgz

cilium install \
	--set ipam.mode=kubernetes \
	--set routingMode=tunnel \
	--set tunnelProtocol=vxlan \
	--set kubeProxyReplacement=false \
	--set hubble.enabled=true \
	--set hubble.relay.enabled=true \
	--set hubble.metrics.enableOpenMetrics=true \
	--set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp}"
cilium status --wait

# L7 DNS visibility (OBSERVATION ONLY). Without an L7 rule, Hubble sees port-53
# traffic at L3/L4 only, so cilium/dns.jsonl is empty (we see THAT a pod hit
# CoreDNS, not WHICH name it resolved). This routes DNS through Cilium's DNS
# proxy so flows carry the parsed query/response. enableDefaultDeny:false keeps
# it purely additive — it never drops traffic. HTTP stays with Istio.
# Canonical copy + rationale: k8s/cilium/dns-visibility.yaml (keep in sync).
kubectl apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: dns-visibility
spec:
  endpointSelector: {}
  enableDefaultDeny:
    egress: false
    ingress: false
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchPattern: "*"
EOF

# metrics-server so `kubectl top nodes/pods` works (run.sh samples pod CPU/mem
# mid-test). On a kubeadm cluster the kubelet serving cert isn't signed by the
# cluster CA, so the default secure scrape fails — inject --kubelet-insecure-tls.
METRICS_URL="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
curl -fsSL "${METRICS_URL}" -o /tmp/metrics-server.yml
sed -i -E 's|^([[:space:]]*)- --kubelet-use-node-status-port|\1- --kubelet-insecure-tls\n\1- --kubelet-use-node-status-port|' /tmp/metrics-server.yml
kubectl apply -f /tmp/metrics-server.yml

echo 'source <(kubectl completion bash)' >> ~/.bashrc || true
