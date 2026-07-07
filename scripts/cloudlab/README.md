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

> **Cluster topology is now fixed at exactly 5 nodes.** The workloads pin every
> service to a specific node via `nodeSelector: ubench.io/node-index: "<N>"` so
> the pod→node layout (and therefore the network flow topology) is reproducible
> across runs — see the per-workload `PLACEMENT.md` (e.g.
> [k8s/boutique/PLACEMENT.md](../../k8s/boutique/PLACEMENT.md)). This requires:
>
> - **node-0** = the control plane (tainted `NoSchedule`, runs no services), and
> - **node-1 … node-4** = exactly four workers that run the services.
>
> `deploy.sh` labels each node `ubench.io/node-index=<N>` from its `node-<N>`
> ordinal on every deploy, so `nodes.sh` must list all five in order
> (node-0 first). A cluster with fewer than four workers will leave some pods
> stuck `Pending` (the selected node-index label won't exist); more than four
> just go unused. The **r320x5** profile created by Yuanli `pentium3` gives exactly this shape.

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

### What `--run` collects, and where it goes

`--run` wraps `run.sh` with `scripts/run_and_collect.sh`, which captures the run
into a single self-contained directory on the control node and then copies it
back to the host under `results/<bench>-<request>_<UTC-timestamp>/`:

```
meta.json          run params + time window + istio/cilium on/off
run.log            full run.sh output (wrk result, heartbeat, top snapshot)
wrk.txt            just the wrk latency/throughput block
resources.csv      per-pod CPU/mem time-series, sampled every 5s (metrics-server)
istio/             only when Istio is enabled (see below):
  requests_total.json / request_duration_ms.json / *_bytes.json
                   raw Istio counters/histograms as a 15s time-series over the run
  edges.json       source -> destination request counts for THIS run (the call graph)
  summary.json     per-service request rate / error rate / p50-p90-p99 latency
  access_logs/*.log  Envoy per-request access logs (one structured line per request)
cilium/            only when Cilium is the CNI (see "Network-layer metrics"):
  flows.jsonl      Hubble network flow log, one JSON line per L3/L4 flow (streamed live)
  edges.json       src -> dst (port, verdict) flow counts — the network-level graph
  dns.jsonl        DNS flows sliced out of flows.jsonl
  hubble_metrics.prom  snapshot of Hubble's Prometheus metrics (drops, flows, DNS)
```

The Istio metrics come from the in-cluster Prometheus via a temporary
port-forward (no NodePort needed); the per-run figures use `increase()`/`rate()`
over the exact run window and are filtered to `reporter="destination"` so each
request is counted once. The Cilium flows are streamed live during the run via
`hubble observe -f` (the relay's ring buffer is too small to query after the
fact). On a cluster **without** a given layer, its subfolder is simply skipped
and the rest is still collected. `results/` is gitignored.

The two sources are complementary: Istio (Envoy sidecars) gives the **L7
application** view — HTTP/gRPC requests, codes, latency — while Cilium/Hubble
gives the **L3/L4 network** view — every socket-level flow, DNS lookup, and
dropped/denied packet — that no sidecar can see.

> Access logs (`istio/access_logs/*.log`) are read from the rotated CRI log
> files on each node, not via `kubectl logs`. kubelet rotates a container's log
> at 10Mi (`containerLogMaxSize` default) and `kubectl logs` only returns the
> *current* file — so a busy sidecar that rotates mid-run (e.g. frontend or
> productcatalog under load) would otherwise come back empty even though it
> logged tens of MB. The collector SSHes control→worker (needs `ssh -A`, which
> `deploy.sh` sets), concatenates all `0.log.*` (decompressing `.gz`), and
> window-filters to the run. If a worker is unreachable it falls back to
> `kubectl logs` and prints a WARN. As a belt-and-suspenders alternative you can
> raise `containerLogMaxSize` (e.g. to 500Mi) in `kube.sh` so logs don't rotate
> mid-run — then plain `kubectl logs` would suffice.

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

## 6. Network-layer metrics (Cilium / Hubble)

The cluster CNI is **Cilium** (eBPF), which replaces flannel and adds **Hubble**
— a network-flow observability layer that is the L3/L4 counterpart to Istio's L7
sidecars. It's installed by `after_join.sh` at bootstrap, so it's always present
on a freshly instantiated cluster (it is **not** a runtime toggle like Istio —
the CNI is chosen at `kubeadm init` time and cannot be swapped on a live cluster).

`deploy.sh --run` captures Hubble data into the per-run `cilium/` folder (see
"What `--run` collects" above): `flows.jsonl` (every L3/L4 flow as it happens),
`edges.json` (the network call graph with per-edge verdicts and ports),
`dns.jsonl`, and a `hubble_metrics.prom` snapshot.

CloudLab specifics baked into the install:

- **LAN device pinning** — nodes are dual-NIC (public `eno1` + experiment LAN
  `10.0.0.x`); Cilium is pinned to the LAN iface (`--set devices=`), the eBPF
  equivalent of flannel's old `--iface-can-reach`. Without it the datapath could
  bind the public NIC and ufw (which only allows `10.0.0.0/24`) would drop it.
- **`ipam.mode=kubernetes`** honors the kubeadm pod CIDR `10.244.0.0/16`, so the
  existing ufw rules need no change.
- **kube-proxy is kept** (`kubeProxyReplacement=false`) for a drop-in swap.

> **L7 split:** Istio owns **HTTP** (per-request semantics in
> `istio/access_logs/`) — we do *not* enable Cilium HTTP visibility, which would
> just duplicate Envoy and add proxy overhead. Cilium owns what only it can see:
> L3/L4 flows, packet drops, and **DNS**. DNS *names* (which host each pod
> resolved) need an L7 rule, so `after_join.sh` applies a cluster-wide,
> **observation-only** `CiliumClusterwideNetworkPolicy` (`dns-visibility`,
> canonical copy at `k8s/cilium/dns-visibility.yaml`) that routes port-53 through
> Cilium's DNS proxy. `enableDefaultDeny:false` makes it purely additive — it
> never drops traffic. Result: `flows.jsonl` keeps the full L3/L4 graph and now
> also carries `l7.dns` events, and per-run `dns.jsonl` lists the resolved names.

Query flows live on the control node:
```bash
cilium hubble port-forward &
hubble observe --follow                       # live flow stream
hubble observe --verdict DROPPED              # just denied traffic
```

## Red-team attack simulation + labeled capture

To capture **labeled** benign+malicious data (an injected adversary on top of the
normal metric bundle), use the Stratus Red Team integration:

```bash
./enable_audit.sh enable        # one-time: turn on the kube-apiserver audit log (reversible)
./attack.sh boutique            # benign load + a control-plane attack, captured + labeled
```

This deploys the app, drives benign `wrk` load, detonates a Stratus Red Team
Kubernetes technique mid-window, captures the full bundle **plus** the audit log
(`audit/`) and ground truth (`attack/`), and labels every audit event / network
flow benign|malicious. See [`RED_TEAM.md`](../../RED_TEAM.md) for the full guide,
the technique catalog, the labeling rules, and an honest fit assessment
(Stratus emulates *control-plane* attacks; the signal lives in the audit log).
