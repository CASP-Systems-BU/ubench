# Boutique benchmark on a local k8s cluster — deploy, run, and read metrics

End-to-end runbook for standing up the `boutique` microservice benchmark on a
self-hosted (non-CloudLab) Kubernetes cluster with **Istio** enabled, driving a
`wrk` workload against it, and reading the resulting metrics — including the
per-service (Istio) metrics that `kubectl top` cannot give you.

Everything here is self-contained in `scripts/local/` and does **not** modify the
CloudLab scripts in `scripts/cloudlab/`.

---

## 0. Topology of this experiment

| Role | Hostname | IP | Notes |
|------|----------|----|-------|
| control plane | k8s0 | 10.0.0.48 | runs istiod, Prometheus, kubeconfig lives here |
| worker | k8s1 | 10.0.0.221 | |
| worker | k8s2 | 10.0.0.160 | |
| worker | k8s3 | 10.0.0.235 | |
| worker | k8s4 | 10.0.0.154 | |

- **Orchestrator**: a separate machine (your laptop/dev box) that SSHes into the
  5 nodes. It is *not* part of the cluster; it only needs `python3` + `ssh`/`scp`.
- All nodes: Ubuntu 24.04, single flat LAN (`10.0.0.0/24`), login user `vm`.
- Three metric sources you will see: **wrk** (client-side latency/throughput),
  **metrics-server** (`kubectl top`, CPU/mem), and **Istio** (per-service request
  counts + latency, via Prometheus). Only the last is "Istio metrics".

---

## 1. One-time prerequisites — passwordless SSH + sudo

`setup_kube.py` drives the nodes over non-interactive SSH and runs `sudo`
non-interactively, so every node needs (a) the orchestrator's SSH key installed
and (b) NOPASSWD sudo.

1. Fill in `scripts/local/config.json`:
   ```json
   {
       "nodes_user": "vm",
       "nodes": ["10.0.0.48", "10.0.0.221", "10.0.0.160", "10.0.0.235", "10.0.0.154"],
       "nodes_home": "/home/vm",
       "enable_istio_metrics": true
   }
   ```
   `nodes[0]` is the control node. `enable_istio_metrics: true` turns on the Istio
   layer during cluster setup.

2. From the orchestrator, run the bootstrap (reads the node list from
   `config.json`, prompts once for the shared password):
   ```bash
   cd scripts/local
   ./bootstrap_local.sh
   ```
   This installs `sshpass`, generates a passphrase-less key, pushes it to all 5
   nodes, sets NOPASSWD sudo, and verifies `sudo whoami == root` on each.

3. (Recommended) Give each node a **unique hostname** — kubeadm uses the hostname
   as the node name and they must be unique:
   ```bash
   # example: k8s0..k8s4, control node first
   ssh vm@10.0.0.48  'sudo hostnamectl set-hostname k8s0'
   ssh vm@10.0.0.221 'sudo hostnamectl set-hostname k8s1'
   ssh vm@10.0.0.160 'sudo hostnamectl set-hostname k8s2'
   ssh vm@10.0.0.235 'sudo hostnamectl set-hostname k8s3'
   ssh vm@10.0.0.154 'sudo hostnamectl set-hostname k8s4'
   ```

4. (Recommended) Disable unattended-upgrades on all nodes so it does not grab the
   apt/dpkg lock mid-setup:
   ```bash
   for ip in 10.0.0.48 10.0.0.221 10.0.0.160 10.0.0.235 10.0.0.154; do
     ssh vm@$ip 'sudo systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer'
   done
   ```

---

## 2. Build the cluster + Istio

From the orchestrator:
```bash
cd scripts/local
python3 setup_kube.py
```
This runs, in order:
1. `kube.sh` on all nodes — installs containerd (via docker.io) + kubeadm, disables
   swap, sets sysctls, and aligns **kubelet + containerd on the systemd cgroup
   driver** (required on Ubuntu 24.04 / cgroup v2).
2. `init_kube.sh` on the control node — `kubeadm init`, API advertised on the
   control node IP.
3. worker join + `after_join.sh` on the control node — kubeconfig, flannel CNI,
   metrics-server.
4. `enable_istio_metrics.sh` on the control node (because `enable_istio_metrics`
   is true) — installs the Istio control plane (demo profile), the Prometheus /
   Grafana / Kiali addons, and labels the `default` namespace
   `istio-injection=enabled`.

Verify (run on the control node, or copy its `~/.kube/config` to the orchestrator):
```bash
ssh vm@10.0.0.48 kubectl get nodes                  # all 5 Ready
ssh vm@10.0.0.48 kubectl get pods -n istio-system   # istiod + prometheus Running
ssh vm@10.0.0.48 'kubectl get ns default --show-labels'   # istio-injection=enabled
```

---

## 3. Deploy the boutique services

`deploy.sh` (in `scripts/cloudlab/`, but environment-agnostic via env vars) copies
the manifests to the control node and applies them:
```bash
cd /home/pentium3/Desktop/ubench
CONTROL_HOST=10.0.0.48 SSH_USER=vm ./scripts/cloudlab/deploy.sh boutique
```

> **Expected with Istio:** the final "heartbeat sweep" prints `[FAIL]` for every
> service and `deploy.sh` exits non-zero. This is **not** a real failure — the
> sweep uses a raw `echo | nc` HTTP request, which Istio's Envoy sidecar rejects.
> The services are deployed fine. Confirm with:
> ```bash
> ssh vm@10.0.0.48 kubectl get pods -o wide
> ```
> Each boutique pod should be **`2/2 Running`** (app container + injected Envoy
> sidecar) and spread across the workers (the control node is tainted).

Do **not** use `deploy.sh --run` under Istio: `--run` calls `scripts/run.sh`,
whose connectivity gate uses the same `nc` heartbeat and loops forever. Use the
manual `wrk` run in the next step instead.

---

## 4. Run the load (wrk)

The load generator is the `ubuntu-client` pod (image `yizhengx/mucache:client`,
which bundles `wrk` + the boutique `mix.lua` script). It is deployed with
`sidecar.istio.io/inject: "false"`, so the client itself stays out of the mesh and
does not pollute the measurement.

```bash
cd /home/pentium3/Desktop/ubench
scp client/client.yaml vm@10.0.0.48:~/client.yaml
ssh vm@10.0.0.48 '
  kubectl apply -f ~/client.yaml
  kubectl wait --for=condition=Ready pod -l app=ubuntu-client --timeout=120s
  CLIENT=$(kubectl get pod -l app=ubuntu-client -o jsonpath="{.items[0].metadata.name}")
  kubectl exec "$CLIENT" -- /wrk/wrk --timeout 20s -t4 -c16 -d30s -L \
      -s /wrk/scripts/online-boutique/mix.lua http://frontend:80
'
```
Parameters mirror `k8s/boutique/run.sh`: `mix` workload, 4 threads, 16 connections,
30 s. The `mix` workload is ~10% home / 10% set-currency / 50% browse / 10%
add-to-cart / 15% view-cart / 5% checkout.

`wrk` prints client-side throughput and a latency distribution, e.g.:
```
Requests/sec:   1667.00
Latency Distribution  50% 8.56ms  90% 17.15ms  99% 25.25ms
50045 requests in 30.02s
```

---

## 5. Read the metrics

### 5a. Client-side (wrk) — overall latency & throughput
Already printed by the `wrk` command above: `Requests/sec`, the latency
percentiles, total requests, errors. This is the black-box, edge view.

### 5b. Per-pod CPU / memory (metrics-server)
```bash
ssh vm@10.0.0.48 kubectl top pods
ssh vm@10.0.0.48 kubectl top nodes
```

### 5c. Per-service metrics (Istio → Prometheus) — the reason Istio is here
Istio's Envoy sidecars export `istio_requests_total` and
`istio_request_duration_milliseconds`, scraped by the in-cluster Prometheus. These
give per-service request counts, error codes, and latency distributions — i.e. the
internal call graph that wrk and `kubectl top` cannot see.

**Option 1 — Prometheus UI (interactive):**
```bash
ssh -L 9090:localhost:9090 vm@10.0.0.48 \
    kubectl -n istio-system port-forward svc/prometheus 9090:9090
# then open http://localhost:9090 and run the PromQL below
```

**Option 2 — query from the orchestrator (no port-forward).** The `ubuntu-client`
pod has `curl` and can reach Prometheus; this snippet prints three tables:
```bash
cd /home/pentium3/Desktop/ubench
python3 - <<'PY'
import subprocess, json, urllib.parse
CTRL="vm@10.0.0.48"
POD=subprocess.run(["ssh","-o","BatchMode=yes",CTRL,
    "kubectl get pod -l app=ubuntu-client -o jsonpath='{.items[0].metadata.name}'"],
    capture_output=True,text=True).stdout.strip()
def q(p):
    url="http://prometheus.istio-system:9090/api/v1/query?query="+urllib.parse.quote(p)
    r=subprocess.run(["ssh","-o","BatchMode=yes",CTRL,f"kubectl exec {POD} -- curl -s '{url}'"],
                     capture_output=True,text=True)
    return json.loads(r.stdout)["data"]["result"]

print("\n# requests per service (+ response code)")
for r in sorted(q('sum by (destination_service_name,response_code)(istio_requests_total)'),
                key=lambda x:-float(x['value'][1])):
    m=r['metric']; print(f"  {m.get('destination_service_name','?'):<16}"
                         f"{m.get('response_code','?'):<5}{float(r['value'][1]):>10.0f}")

print("\n# avg latency (ms) per service")
for r in sorted(q('sum by(destination_service_name)(istio_request_duration_milliseconds_sum)'
                  '/sum by(destination_service_name)(istio_request_duration_milliseconds_count)'),
                key=lambda x:-float(x['value'][1])):
    print(f"  {r['metric'].get('destination_service_name','?'):<16}{float(r['value'][1]):>8.2f}")

print("\n# p99 latency (ms) per service, rate over last 10m")
for r in sorted(q('histogram_quantile(0.99, sum by(le,destination_service_name)'
                  '(rate(istio_request_duration_milliseconds_bucket[10m])))'),
                key=lambda x:-(float(x['value'][1]) if x['value'][1] not in ('NaN','') else -1)):
    print(f"  {r['metric'].get('destination_service_name','?'):<16}{r['value'][1]}")
PY
```

Useful PromQL one-liners:
| Goal | Query |
|------|-------|
| Requests per service | `sum by (destination_service_name)(istio_requests_total)` |
| Error rate per service | `sum by (destination_service_name)(rate(istio_requests_total{response_code!="200"}[5m]))` |
| p99 latency per service | `histogram_quantile(0.99, sum by(le,destination_service_name)(rate(istio_request_duration_milliseconds_bucket[5m])))` |
| Call graph (who calls whom) | `sum by (source_workload,destination_service_name)(istio_requests_total)` |

> Note: `rate(...[5m])` needs traffic inside the window — query soon after a run,
> or widen the window. Cumulative counters (`istio_requests_total`,
> `..._sum`/`..._count`) persist and can be read any time.

### 5d. Full catalog — everything Istio can collect

(From the official docs: [Standard Metrics](https://istio.io/latest/docs/reference/config/metrics/),
[Observability](https://istio.io/latest/docs/concepts/observability/).)

**Standard service-level metrics — HTTP/HTTP2/gRPC** (this experiment uses the
first two):

| Metric | Type | Measures |
|--------|------|----------|
| `istio_requests_total` | Counter | every request handled by a proxy (volume, error rate) |
| `istio_request_duration_milliseconds` | Histogram | request latency distribution (p50/p99/...) |
| `istio_request_bytes` | Histogram | HTTP request body sizes |
| `istio_response_bytes` | Histogram | HTTP response body sizes |
| `istio_request_messages_total` | Counter | gRPC messages sent by clients |
| `istio_response_messages_total` | Counter | gRPC messages sent by servers |

**Standard service-level metrics — TCP** (non-HTTP traffic, e.g. databases):

| Metric | Type | Measures |
|--------|------|----------|
| `istio_tcp_sent_bytes_total` / `istio_tcp_received_bytes_total` | Counter | bytes sent/received on TCP connections |
| `istio_tcp_connections_opened_total` / `istio_tcp_connections_closed_total` | Counter | TCP connections opened/closed |

**Labels (dimensions) on all of the above** — every metric can be sliced by:
`reporter` (source/destination side), `source_workload`/`source_workload_namespace`,
`destination_workload`/`destination_service_name`/`destination_service_namespace`,
app/version (canonical service), `request_protocol`, `response_code`,
`grpc_response_status`, `response_flags` (failure cause: timeouts, circuit
breaking, no healthy upstream — great for failure attribution),
`connection_security_policy` (whether mTLS was used), and source/destination
principals/cluster. The call graph in 5c is just `istio_requests_total` sliced by
`source_workload` → `destination_service_name`.

**Proxy-level (raw Envoy) stats** — each sidecar internally tracks much more:
connection-pool usage, circuit-breaker/retry counters, listener/cluster traffic,
TLS handshakes, etc. Only a small subset is exported by default (overhead);
enable more selectively when debugging (e.g. "is the connection pool saturated?").

**Control-plane metrics** — istiod self-monitoring: xDS push counts/latency,
sidecar injection counts, certificate issuance. For monitoring the mesh itself.

**Beyond metrics — two more telemetry types (not enabled in this experiment):**

- **Distributed traces**: sidecars generate a span per request hop, with no app
  changes — shows where a *single* request spends its time across
  frontend→checkout→payment. Backends: Jaeger / Zipkin / OpenTelemetry;
  sampling rate is configurable. This is the natural next step to decompose
  checkout's p99 into per-hop latency (metrics only give per-service averages).
- **Access logs**: one configurable log line per request, for per-request audit.

**Customization (Telemetry API)**: add custom dimensions to the standard metrics
(e.g. split `frontend` metrics by URL path), or drop unneeded dimensions to save
storage.

---

## 6. Re-run / change the workload

- Different workload size: change `-t/-c/-d` in the `wrk` command (step 4).
- Different benchmark: replace `boutique` in step 3 and point `wrk` at that
  benchmark's entrypoint (see `k8s/<bench>/run.sh`).
- Tear down a benchmark's services:
  ```bash
  CONTROL_HOST=10.0.0.48 SSH_USER=vm ./scripts/cloudlab/deploy.sh boutique --down
  ```

---

## 7. Istio in one paragraph

Istio is a **service mesh**: it injects an Envoy sidecar proxy next to every
service pod (that is the `2/2`), so all service-to-service traffic flows through a
proxy. Without changing application code this gives observability (the per-service
request/latency metrics in 5c, plus the call graph), and optionally traffic
management (timeouts, retries, canary) and security (mutual TLS). This experiment
uses only the observability part. The load-generator client opts out of injection
so its own traffic is not measured as mesh traffic.

---

## 8. Baseline vs mesh — turning Istio on/off for A/B runs

Injecting the Envoy sidecar adds a hop to every call, so "with Istio"
latency/CPU is **not** directly comparable to a bare run. Because Istio attaches
purely via the namespace label + sidecar injection (the benchmark code in `app/`
and the manifests in `k8s/` are never modified), you switch between the two by
toggling the label and recreating the pods — nothing in the benchmark changes.

**Mesh OFF (baseline, pods become `1/1`, no Istio per-service metrics):**
```bash
ssh vm@10.0.0.48 '
  kubectl label namespace default istio-injection-      # remove the label
  kubectl rollout restart deployment                     # recreate pods without sidecar
  kubectl get pods                                       # verify 1/1 Running
'
```

**Mesh ON (pods become `2/2` = app + Envoy, Istio metrics available):**
```bash
ssh vm@10.0.0.48 '
  kubectl label namespace default istio-injection=enabled --overwrite
  kubectl rollout restart deployment                     # recreate pods with sidecar
  kubectl get pods                                       # verify 2/2 Running
'
```

Run the `wrk` workload (step 4) under each setting and record them separately;
comparing wrk latency/throughput and `kubectl top` between the two quantifies the
mesh overhead. Toggling the label changes nothing in `app/` or `k8s/` — only how
pods are admitted to the cluster.

---

## 9. Troubleshooting (issues seen bringing this up on Ubuntu 24.04)

| Symptom | Cause | Fix |
|---------|-------|-----|
| `kube.sh` exits 2, `curl: command not found` | minimal image lacks curl | `kube.sh` now installs `curl ca-certificates gnupg apt-transport-https` |
| `kubeadm init` fails / kubelet won't start | cgroup v2 driver mismatch; docker.io's containerd ships with CRI disabled | `kube.sh` regenerates `/etc/containerd/config.toml` with CRI enabled + `SystemdCgroup=true`, and sets kubelet to systemd |
| One node stuck, `Could not get lock /var/lib/dpkg/lock-frontend` | `unattended-upgrades` holds the apt lock | stop/disable it (step 1.4), then re-run `kube.sh` on that node |
| A node `NotReady`, flannel pod `Init:ImagePullBackOff` | transient `ghcr.io` 502 pulling the flannel image | `sudo crictl pull ghcr.io/flannel-io/flannel:<ver>` on that node, then `kubectl delete pod -n kube-flannel <pod>` |
| heartbeat sweep `[FAIL]` for all services / `run.sh` hangs | the `echo \| nc` heartbeat is not valid HTTP for Envoy | ignore it under Istio; drive the load with the manual `wrk` step (4); the app and `wrk` use real HTTP and work |
