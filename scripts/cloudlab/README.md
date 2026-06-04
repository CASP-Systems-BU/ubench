# Set up k8s cluster on Cloudlab

* Change the `config.json` to include all hostnames and username
* Run `python3 setup_kube.py` which will install everything and set up a k8s cluster. The first node in the hostname list will be the control node, and the rest will be worker nodes.

## Istio service-level metrics (optional)

With Istio enabled, every benchmark pod gets an Envoy sidecar (`2/2`) that
exports per-service request counts / error codes / latency histograms
(`istio_requests_total`, `istio_request_duration_milliseconds`), scraped by an
in-cluster Prometheus. How to query them, the full metric catalog, and an
Istio on/off A-B guide are documented in `scripts/local/EXPERIMENT.md`.

### New cluster

Controlled by `"enable_istio_metrics"` in `config.json` (code default: off).
When `true`, `setup_kube.py` runs `enable_istio_metrics.sh` on the control node
after the workers join: Istio control plane (demo profile) + Prometheus /
Grafana / Kiali addons + `istio-injection=enabled` on the `default` namespace.
Set it to `false` to get the original bare cluster.

### EXISTING cluster (set up before this script existed)

The switch only acts during `setup_kube.py`. To retrofit a running CloudLab
cluster — **do NOT re-run `bootstrap.sh`** (it re-runs `kubeadm init` and will
wreck the cluster). Instead, from your laptop on this branch:

```bash
# the control node won't have the script yet (bootstrap copied the scripts
# before it existed), so copy it up first:
scp scripts/cloudlab/enable_istio_metrics.sh <user>@<node0>.apt.emulab.net:~/

ssh <user>@<node0>.apt.emulab.net 'bash ~/enable_istio_metrics.sh'   # idempotent
ssh <user>@<node0>.apt.emulab.net 'kubectl rollout restart deployment && kubectl get pods'
# benchmark pods come back 2/2 (app + sidecar)
```

No firewall changes needed: the ufw rules from `bootstrap.sh` already allow the
node LAN (`10.0.0.0/24`) and the pod CIDR (`10.244.0.0/16`), which is all the
traffic Istio uses (sidecar<->istiod, Prometheus scraping, injection webhook).

### Running workloads with Istio on

Use `deploy.sh` / `run.sh` **from this branch**: their health checks use a real
HTTP client (wget). The older `echo | nc` heartbeat is rejected by the Envoy
sidecar — with the old scripts the sweep reports `[FAIL]` for every service and
`--run` hangs forever in the connectivity gate. Both script versions behave
identically on a cluster without Istio.

To disable Istio again:
`kubectl label namespace default istio-injection- && kubectl rollout restart deployment`
(pods return to `1/1`; full uninstall: `istioctl uninstall --purge -y && kubectl delete ns istio-system`).