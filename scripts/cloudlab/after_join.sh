mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Deploy flannel, but pin its interface to the experiment LAN. Like kubelet,
# flannel otherwise auto-detects its iface from the default route (the public
# eno1), so the vxlan tunnel endpoints — i.e. all inter-node pod traffic —
# would flow over the public network. --iface-can-reach makes each flannel pod
# choose the iface that routes to the control node's LAN IP (10.0.0.101).
# sed reuses the matched line's own indentation (\1) so it stays valid YAML.
FLANNEL_URL="https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml"
curl -fsSL "${FLANNEL_URL}" -o /tmp/kube-flannel.yml
sed -i -E 's|^([[:space:]]*)- --kube-subnet-mgr|\1- --kube-subnet-mgr\n\1- --iface-can-reach=10.0.0.101|' /tmp/kube-flannel.yml
kubectl apply -f /tmp/kube-flannel.yml

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