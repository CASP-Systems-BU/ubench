# Running on CloudLab

## 1. Instantiate a cluster

1. Go to [Project Profiles](https://www.cloudlab.us/user-dashboard.php#projectprofiles).
2. Pick a profile whose nodes are named `node-0..node-N` on a shared `10.0.0.x`
   LAN — e.g. the **r320x5** profile
   ([Instantiate](https://www.cloudlab.us/show-profile.php?uuid=5e50d04b-1b1e-11f0-af1a-e4434b2381fc))
   for the classic 1 control plane + 4 workers shape. Any node count works; the
   scripts adapt.
3. Change only the experiment **name** — keep everything else at the defaults.
4. Once it's ready, grab the node hostnames from the **List View**.

## 2. Register the cluster

```bash
python3 register_cluster.py apt120.apt.emulab.net apt096.apt.emulab.net ... [--check]
```

One command, hostnames from the List View in order (**node-0 first** — it
becomes the control plane). It rewrites [nodes.sh](nodes.sh) and
[config.json](config.json) consistently (internal IPs `10.0.0.101 + i`, ssh
user, home dir; `--user/--ip-base/--home` to override, `--check` to ssh-probe
every host first). Don't edit those files by hand.

> **Placement is deterministic for any worker count.** The workloads pin every
> service to a specific node via `nodeSelector: ubench.io/node-index: "<N>"` so
> the pod→node layout (and therefore the network flow topology) is reproducible
> across runs — see the per-workload `PLACEMENT.md` (e.g.
> [k8s/boutique/PLACEMENT.md](../../k8s/boutique/PLACEMENT.md)).
>
> - **node-0** = the control plane (tainted `NoSchedule`, runs no services);
> - **node-1 … node-N** = workers. An experiment spec's `workers:` value says
>   how many of them the placement spans; `deploy.sh` labels each node
>   `ubench.io/node-index=<N>` from its `node-<N>` ordinal on every deploy and
>   **fails fast** if the cluster has fewer workers than the experiment needs.
>   Extra workers just go unused.

## 3. Bootstrap the cluster

```bash
./bootstrap.sh
```

Orchestrates the whole setup across all nodes: brings up the k8s cluster (`kube`) and applies
firewall + SSH hardening (`secure`).

## 4. Deploy a workload / run an experiment

```bash
./deploy.sh                                              # boutique, defaults
./deploy.sh movie                                        # any workload under k8s/<bench>/
./deploy.sh --experiment ../../experiments/foo.yaml --run  # spec-driven experiment
```

Renders the workload's manifests for the experiment (`render_manifests.py` —
worker count, per-service replicas, chain-* processing times), copies the
rendered `build/<name>/` to the control node, applies it, waits for rollout,
and runs a heartbeat sweep to confirm the deploy is live. See
[experiments/README.md](../../experiments/README.md) for the spec schema.

Flags:

- `--experiment <spec.yaml>` — render/deploy/run this experiment spec.
- `--down` — tear down the currently deployed workload (deletes exactly the
  manifests of the last deploy, kept on the control node).
- `--run` — after deploying, drive **one continuous wrk2 load** and harvest
  telemetry into one run dir per segment. Knobs (env overrides spec):
  `REQUEST` / `THREADS` / `CONNS` / `RATE` / `TOTAL_S` / `SEGMENT_S`
  (defaults: mix, 4, 16, 1000 req/s, 60s, =TOTAL_S).

```bash
./deploy.sh boutique --run                        # one 60s segment at 1000 req/s
RATE=500 TOTAL_S=1800 SEGMENT_S=600 ./deploy.sh boutique --run   # 3 x 10min segments
./deploy.sh boutique --down
```

> **wrk2 is open-loop**: `RATE` is offered load, independent of how the cluster
> responds, and latency is coordinated-omission-corrected. Numbers are NOT
> comparable with the old closed-loop `wrk` runs (their tails were optimistic) —
> `meta.json.generator` marks the epoch. Pick `RATE` below the saturation knee:
> sweep procedure in [experiments/README.md](../../experiments/README.md).

### What `--run` collects, and where it goes

`--run` wraps `run.sh` with `scripts/run_and_collect.sh`: run.sh deploys the
client and starts wrk2 detached in it; the collector then harvests telemetry
every `SEGMENT_S` into its own self-contained run directory (all copied back to
`results/<bench>-<request>_<UTC-timestamp>/`, one per segment). Segments exist
because the log sources rotate with hard caps — a multi-hour run collected only
at the end would silently lose its early hours — and because each run dir is
then a contiguous time slice: consumers that split runs by timestamp get a
temporal split of the long experiment for free. Keep `SEGMENT_S` ≤ ~900s.

```
meta.json          params + window + rate offered/achieved + segment index
run.log            setup output + the full wrk2 output (same in every segment)
wrk.txt            the wrk2 stats block incl. the HdrHistogram percentile
                   spectrum (whole-experiment stats, duplicated per segment)
resources.csv      per-pod CPU/mem time-series, sampled every 5s (metrics-server)
k8s_snapshot/      entity snapshot for graph construction (any cluster):
  objects.json     pods/services/endpoints/deployments/RS/STS/DS at run START
  objects_end.json same at collection time (catches mid-run pod churn)
  nodes.json       node objects (InternalIPs, labels)
audit/             only when the enable_audit_log gate was applied:
  audit.jsonl      kube-apiserver audit events (Metadata level) in the run window
istio/             only when Istio is enabled (see below):
  requests_total.json / request_duration_ms.json / *_bytes.json
                   raw Istio counters/histograms as a 15s time-series over the run
  edges.json       source -> destination request counts for THIS run (the call graph)
  summary.json     per-service request rate / error rate / p50-p90-p99 latency
  access_logs/*.log  Envoy per-request access logs (one JSON line per request;
                   older clusters without accessLogEncoding=JSON emit text lines,
                   both are window-filtered correctly)
cilium/            only when Cilium is the CNI (see "Network-layer metrics"):
  flows.jsonl      Hubble network flow log, one JSON line per L3/L4 flow (streamed live)
  edges.json       src -> dst (port, verdict) flow counts — the network-level graph
  dns.jsonl        DNS flows sliced out of flows.jsonl
  hubble_metrics.prom  snapshot of Hubble's Prometheus metrics (drops, flows, DNS)
```

> **Applying new collection gates to a live cluster**: `./bootstrap.sh addons`
> re-copies `scripts/cloudlab/` to node-0 and runs only the config.json-gated
> add-on steps (`enable_audit_log`, `enable_istio_metrics`) — safe on an
> already-initialized cluster, where a full `kube` re-run would fail at
> `kubeadm init`. The audit gate patches the kube-apiserver static-pod manifest
> (restarting it, ~30-60s) and verifies events flow to
> `/var/log/kubernetes/audit/audit.log`.

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

> L7 visibility (HTTP/DNS *contents*) needs an explicit Hubble L7 policy or a
> `proxy-visibility` annotation, and would overlap with Istio's Envoy sidecars.
> By design we let Istio own L7 and use Cilium for what only it can see — L3/L4
> flows, DNS lookups, and packet drops. `flows.jsonl` always has the L3/L4 graph;
> per-request HTTP semantics live in `istio/access_logs/`.

Query flows live on the control node:
```bash
cilium hubble port-forward &
hubble observe --follow                       # live flow stream
hubble observe --verdict DROPPED              # just denied traffic
```
