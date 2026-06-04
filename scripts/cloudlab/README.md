# Running on CloudLab

## 1. Instantiate a cluster

1. Go to [Project Profiles](https://www.cloudlab.us/user-dashboard.php#projectprofiles).
2. Pick the **r320x5** profile and click [Instantiate](https://www.cloudlab.us/show-profile.php?uuid=5e50d04b-1b1e-11f0-af1a-e4434b2381fc).
3. Change only the experiment **name** — keep everything else at the defaults.
4. Once it's ready, grab the node hostnames from the **List View**.

## 2. Point the scripts at your nodes

Edit [nodes.sh](nodes.sh) — the single shared list of public hostnames sourced by both
`bootstrap.sh` and `deploy.sh`. `node-0` MUST be first (it becomes the control plane) and
the order must match the internal-IP order in [config.json](config.json). This is the only
file you edit when swapping experiments.

## 3. Bootstrap the cluster

```bash
./bootstrap.sh
```

Orchestrates the whole setup across all nodes: brings up the k8s cluster (`kube`) and applies
firewall + SSH hardening (`secure`).

## 4. Deploy a workload

```bash
./deploy.sh              # defaults to the boutique workload
./deploy.sh movie        # any workload under k8s/<bench>/
```

Copies the workload's `k8s/<bench>/` manifests to the control node, applies them, waits for
rollout, and runs a heartbeat sweep to confirm the deploy is live.

Flags:

- `--down` — tear down a workload's services (directory-based `kubectl delete`).
- `--run` — after deploying, copy `scripts/run.sh` + `client/` up and drive the `wrk` load
  test against the services. `wrk` params are env-overridable via `REQUEST` / `THREADS` /
  `CONNS` / `DURATION` (defaults: mix, 4, 16, 30).

```bash
./deploy.sh boutique --run
./deploy.sh boutique --down
```

## 5. Istio service-level metrics (optional)

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

### Existing cluster (set up before this script existed)

The switch only acts during `setup_kube.py`. To retrofit a running CloudLab
cluster — **do NOT re-run `bootstrap.sh`** (it re-runs `kubeadm init` and will
wreck the cluster). Instead, from your laptop:

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

Use `deploy.sh` / `run.sh`: their health checks use a real HTTP client (wget).
The older `echo | nc` heartbeat is rejected by the Envoy sidecar — with the old
scripts the sweep reports `[FAIL]` for every service and `--run` hangs forever
in the connectivity gate. Both script versions behave identically on a cluster
without Istio.

To disable Istio again:
`kubectl label namespace default istio-injection- && kubectl rollout restart deployment`
(pods return to `1/1`; full uninstall: `istioctl uninstall --purge -y && kubectl delete ns istio-system`).
