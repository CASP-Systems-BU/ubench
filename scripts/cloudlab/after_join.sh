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

echo 'source <(kubectl completion bash)' >> ~/.bashrc
source ~/.bashrc