mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# CNI: Cilium (eBPF) + Hubble observability, replacing flannel. Hubble gives us
# a second metric/log source alongside Istio — network-level flows, DNS, and
# packet drops (see scripts/run_and_collect.sh / collect_metrics.py).
#
# Two CloudLab-specific settings carry over what flannel used to handle:
#   * devices=<LAN iface>: CloudLab nodes are dual-NIC (public eno1 + experiment
#     LAN 10.0.0.x). flannel was pinned to the LAN via --iface-can-reach; Cilium
#     must likewise attach its datapath to the LAN iface, else NodePort/masq BPF
#     binds the public NIC and inter-node traffic (which ufw only allows on
#     10.0.0.0/24) is dropped. Auto-detected here; r320 nodes are homogeneous so
#     the same iface name is valid cluster-wide. Tunnel endpoints already ride
#     the LAN because kubelet is pinned to --node-ip=10.0.0.x (see kube.sh).
#   * ipam.mode=kubernetes: honor the kubeadm --pod-network-cidr=10.244.0.0/16
#     (init_kube.sh), so the existing ufw allow-rule for the pod CIDR still holds.
# kube-proxy is left in place (kubeProxyReplacement=false) for a drop-in swap;
# VXLAN matches flannel's encap (UDP 8472, already covered by the LAN allow-rule).
LAN_IFACE=$(ip -4 -o addr show | awk '/ 10\.0\.0\./{print $2; exit}')
if [ -z "${LAN_IFACE}" ]; then
	echo "[!] No 10.0.0.x experiment-LAN iface found for Cilium device pinning" >&2
	exit 1
fi
echo "[after_join] Cilium will attach to LAN device: ${LAN_IFACE}"

# cilium-cli + hubble CLI (hubble CLI is used by run_and_collect.sh to stream
# flows during a benchmark run). Pinned-stable versions resolved from upstream.
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
	--set devices="${LAN_IFACE}" \
	--set hubble.enabled=true \
	--set hubble.relay.enabled=true \
	--set hubble.metrics.enableOpenMetrics=true \
	--set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp}"
cilium status --wait

# Deploy metrics-server so `kubectl top nodes/pods` works (run.sh samples pod
# CPU/memory mid-test via `kubectl top pods`; without this it errors with
# "Metrics API not available"). It's not part of stock kubeadm. On a kubeadm
# cluster the kubelet serving cert isn't signed by the cluster CA, so the
# default secure scrape fails and the deployment never goes Ready — we inject
# --kubelet-insecure-tls (safe here: scrape traffic is on the internal LAN).
# sed reuses the matched line's own indentation (\1) so it stays valid YAML.
METRICS_URL="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
curl -fsSL "${METRICS_URL}" -o /tmp/metrics-server.yml
sed -i -E 's|^([[:space:]]*)- --kubelet-use-node-status-port|\1- --kubelet-insecure-tls\n\1- --kubelet-use-node-status-port|' /tmp/metrics-server.yml
kubectl apply -f /tmp/metrics-server.yml

echo 'source <(kubectl completion bash)' >> ~/.bashrc
source ~/.bashrc