# Benchmark metrics & fields — what we collect, where it lives, what each number means


**Contents**
1. [At a glance — file inventory](#1-at-a-glance--file-inventory)
3. [The unifying idea: one window, four altitudes](#3-the-unifying-idea-one-window-four-altitudes)
4. [Units cheat-sheet](#4-units-cheat-sheet)
5. [File-by-file reference](#5-file-by-file-reference)
6. [Cross-referencing the layers (worked example)](#6-cross-referencing-the-layers-worked-example)
7. [Rate vs. total quick reference](#7-rate-vs-total-quick-reference)
8. [Known gaps & TODO](#8-known-gaps--todo)

---

## 1. At a glance — file inventory

Every `deploy.sh <bench> --run` produces one self-contained run directory:

```
results/<bench>-<request>_<RUN_ID>/
├── meta.json            run parameters + the exact time window everything is scoped to
├── run.log              full stdout/stderr of run.sh (deploy → heartbeat → wrk → top)
├── wrk.txt              just the wrk client report (client-side throughput & latency)
├── resources.csv        per-pod CPU/mem time-series, sampled every 5s
├── istio/               service-mesh (L7/HTTP) view, from Envoy sidecars + Prometheus
│   ├── summary.json         per-service request rate / error rate / p50-p90-p99 latency
│   ├── edges.json           per-run call graph: source_workload → destination_workload
│   ├── requests_total.json      raw time-series: cumulative request counter
│   ├── request_duration_ms.json raw time-series: latency histogram buckets
│   ├── request_bytes.json       raw time-series: request body bytes
│   ├── response_bytes.json      raw time-series: response body bytes
│   ├── tcp_sent_bytes.json      raw time-series: TCP bytes sent (non-HTTP services)
│   ├── tcp_received_bytes.json  raw time-series: TCP bytes received
│   └── access_logs/<pod>.log    one structured line per HTTP request (per-request trace)
└── cilium/              network (L3/L4 + DNS) view, from Cilium/Hubble
    ├── flows.jsonl          every packet-level flow, one JSON object per line (live capture)
    ├── edges.json           per-run network graph: src → dst:port, verdict, count
    ├── dns.jsonl            the subset of flows carrying an L7 DNS record
    ├── hubble_metrics.prom  Hubble's own Prometheus counters (flows/drops/DNS, snapshot)
    └── _capture.err         stderr of the live `hubble observe` capture (empty = clean)
```

| File | Altitude | What it holds | Source |
|---|---|---|---|
| `meta.json` | — | run params + the time window all files are scoped to | `run_and_collect.sh` |
| `run.log` | — | full run.sh stdout/stderr | `run_and_collect.sh` |
| `wrk.txt` | client | client-side throughput & latency (black-box) | wrk |
| `resources.csv` | infra | per-pod CPU/mem, 5s samples | `kubectl top` / metrics-server |
| `istio/summary.json` | L7 per-service | req rate, error rate, p50/p90/p99 | Prometheus |
| `istio/edges.json` | L7 per-service | HTTP call graph (src→dst, count) | Prometheus |
| `istio/requests_total.json` | L7 per-service | raw cumulative request counter | Prometheus |
| `istio/request_duration_ms.json` | L7 per-service | raw latency histogram buckets | Prometheus |
| `istio/request_bytes.json` / `response_bytes.json` | L7 per-service | raw body-byte sums | Prometheus |
| `istio/tcp_sent_bytes.json` / `tcp_received_bytes.json` | L7 per-service | raw TCP byte counters (non-HTTP svcs) | Prometheus |
| `istio/access_logs/<pod>.log` | L7 per-request | one Envoy line per HTTP request | CRI rotated logs |
| `cilium/flows.jsonl` | L3/L4 per-flow | every network flow, one JSON/line | Hubble (live) |
| `cilium/edges.json` | L3/L4 per-flow | network graph (src→dst:port, verdict, count) | derived from flows |
| `cilium/dns.jsonl` | L7 DNS | flows carrying a parsed DNS record | Hubble |
| `cilium/hubble_metrics.prom` | L3/L4 | Hubble's own counters (snapshot, not window-scoped) | Hubble metrics |
| `cilium/_capture.err` | — | stderr of the live capture (empty = clean) | Hubble |

---

## 3. One window, Four altitudes

`run_and_collect.sh` scopes every metric file to the **wrk load phase** — the window
`start_epoch`/`end_epoch` in `meta.json`, anchored to wrk's end and sized by wrk's own
measured runtime (the `N requests in 30.02s` line). **Every metric file is scoped to that
same window**, so they all describe *this run's load phase only* — even though the underlying
counters and pod logs are cumulative and contain traffic from setup and earlier runs. This is
what makes the files comparable to each other. (The full run_and_collect span — setup,
heartbeat sweep, populate, sleeps — is recorded separately as `capture_start_epoch`/
`capture_end_epoch` for reference.)

The data sources are the **same traffic observed at four altitudes**:

| Altitude | Source | Granularity | Files |
|---|---|---|---|
| Client-side | wrk (load generator) | aggregate over whole run | `wrk.txt` |
| L7 / HTTP per-service | Istio Prometheus | aggregated rates & percentiles | `istio/summary.json`, `istio/*.json` |
| L7 / HTTP per-request | Envoy sidecar access logs | one line per request | `istio/access_logs/*.log` |
| L3/L4 + DNS per-flow | Cilium/Hubble | one record per network flow | `cilium/flows.jsonl`, `cilium/edges.json` |

How they connect, top to bottom: wrk fires N requests at `frontend`; each request fans out
into many internal service-to-service HTTP calls (visible in `istio/edges.json` and the
per-pod `access_logs`); each of those HTTP calls is carried over one or more TCP connections
plus DNS lookups (visible in `cilium/edges.json` and `flows.jsonl`). So
`wrk Requests/sec` < sum of Istio edge rates < count of Cilium flows — each layer sees more
events than the one above it.

---

## 4. Units cheat-sheet

Two unit systems show up everywhere; mixing them up is the most common mistake.

### CPU — millicores (`m`)

`79m` means **79 millicores = 0.079 of one CPU core = 7.9% of a single core's time.**

- `1000m` = `1` = one full vCPU/core, busy for one wall-clock second per second.
- `1280m` (frontend's peak this run) = **1.28 cores** — more than one full core, so it was
  using time on multiple cores simultaneously.
- `8m` = 0.8% of a core (essentially idle).

It is a **rate**, not a quantity: CPU-seconds consumed per wall-clock second, averaged over
the metrics-server sampling interval. There is no such thing as "total CPU used" here —
only "how many cores' worth it was burning at sample time".

### Memory — mebibytes (`Mi`), binary

`43Mi` means **43 mebibytes = 43 × 2²⁰ bytes = 43 × 1,048,576 = ~45.1 million bytes.**

- `Mi` (mebibyte, 1024²) ≠ `MB` (megabyte, 1000²). Kubernetes always reports the binary
  `Mi`/`Gi`/`Ki` form. `43Mi` ≈ `45.1 MB`.
- It is the pod's **working set** (resident memory the kernel can't trivially reclaim ≈
  actual RAM in use), an instantaneous quantity, not a rate.
- `Ki` = kibibyte (1024 B), `Gi` = gibibyte (1024 Mi) — same scheme, if a pod ever grows.


---

## 5. File-by-file reference

### meta.json — the run manifest

```json
{ "benchmark":"boutique", "request":"mix", "threads":4, "connections":16,
  "duration_s":30, "run_id":"20260616-225513",
  "start_epoch":1781650638, "end_epoch":1781650669,
  "start_iso":"...Z", "end_iso":"...Z",
  "capture_start_epoch":1781650515, "capture_end_epoch":1781650669,
  "capture_start_iso":"...Z", "capture_end_iso":"...Z",
  "istio_enabled":true, "cilium_enabled":true, "run_status":0 }
```

- `threads`/`connections`/`duration_s`/`request` — the wrk parameters (`request` = which
  Lua workload script, e.g. `mix`).
- `start_epoch`/`end_epoch` — the **metric window = the wrk load phase**. Its length is wrk's
  own measured runtime (the `N requests in 30.02s` line, rounded up to 31s here), anchored to
  the instant wrk finished. Every metric file (Istio queries, Envoy access-log filter, Cilium
  flow aggregation) is scoped to this window, so `summary.json` rates/percentiles reflect peak
  load and line up with wrk's numbers. Falls back to `duration_s` if wrk's report is missing.
- `capture_start_epoch`/`capture_end_epoch` — the **full run_and_collect span** (deploy
  verification, the heartbeat connectivity sweep, populate, inter-step sleeps, and the wrk
  load). Wider than the metric window (~154s vs. 31s here); kept for reference and for matching
  against the raw `cilium/flows.jsonl`, which is captured over this whole span.
- `istio_enabled`/`cilium_enabled` — whether each collector ran; if false, that subdir is empty.
- `run_status` — run.sh exit code (0 = wrk finished cleanly).

### wrk.txt — client-side ground truth

The load generator's own report — the only **black-box, client-observed** measurement
(everything else is server-side instrumentation):

```
Latency    11.28ms    8.11ms 155.76ms   87.07%   ← avg / stdev / max / ±1σ%
Req/Sec   384.02 ...                              ← per-thread, per-second
Latency Distribution  50% 8.67ms ... 99% 38.40ms ← end-to-end percentiles (incl. network)
45895 requests in 30.02s, 34.38MB read
Requests/sec:   1529.00                           ← aggregate throughput
```

This is **end-to-end latency from the client pod to `frontend` and back**, including the
full downstream fan-out. `istio/summary.json` latency, by contrast, is per-service and
server-measured, so frontend's Istio p50 ≈ wrk p50, while leaf services read much lower.

### resources.csv — per-pod CPU/memory samples

```
epoch,pod,cpu,mem
1781650515,cart-7699b96c8f-zj9zw,79m,43Mi
```

One row per pod **per 5-second sample**, from `kubectl top pods` (served by
`metrics-server`). This is the only resource source: the Istio Prometheus does not scrape
cAdvisor, which is why we sample separately. Join to the other files on `epoch` (same clock
as `meta.json`).

| Column | Example | Meaning |
|---|---|---|
| `epoch` | `1781650515` | sample time, Unix seconds UTC (groups all pods in one sweep) |
| `pod` | `cart-7699b96c8f-zj9zw` | pod name = `<deployment>-<replicaset-hash>-<pod-hash>` |
| `cpu` | `79m` | millicores in use at sample time (see units) — a **rate** |
| `mem` | `43Mi` | working-set memory at sample time — a **quantity** |

Notes specific to this data:
- A pod only appears in a sweep once metrics-server has a reading for it, so early sweeps
  have fewer rows (you'll see cart/email/shipping at `...515` but checkout only from `...521`).
- The values are a short rolling average over the kubelet's cAdvisor window, not an
  instantaneous spike. Brief sub-second bursts are smoothed out.
- To get a per-service utilization curve, filter rows by `pod` prefix and plot against `epoch`.

---

### istio/ — service-mesh (HTTP / L7) view

Generated by `collect_metrics.py` querying the in-cluster Prometheus (via a temporary
port-forward) plus pulling Envoy sidecar logs. **Key correctness detail:** every metric
filters `reporter="destination"`. Istio emits `istio_requests_total` from *both* the sending
and receiving sidecar, so summing across reporters double-counts every edge; the destination
view is the canonical "requests received by D". External ingress appears as
`source_workload="unknown"`.

#### The Istio metric label set (on every series)

`istio_requests_total` and friends carry ~30 labels. The ones that matter:

| Label | Example | Meaning |
|---|---|---|
| `source_workload` | `checkout` | the calling service (`unknown` = outside the mesh, e.g. wrk client / ingress) |
| `destination_workload` | `cart` | the receiving service |
| `destination_service_name` | `cart` | the k8s Service that was addressed |
| `response_code` | `200` | HTTP status returned |
| `response_flags` | `-` | Envoy response flag; `-` = clean (`UH`,`UF`,`DC`…) |
| `reporter` | `destination` | **which sidecar emitted it.** We keep only `destination` so each request is counted once |
| `request_protocol` | `http` | L7 protocol |
| `connection_security_policy` | `mutual_tls` | **whether the hop used mTLS** — confirms Istio is encrypting service-to-service traffic |
| `source_principal`/`destination_principal` | `spiffe://cluster.local/ns/default/sa/default` | the SPIFFE workload identities of each end |
| `pod`, `instance` | `cart-...:15020` | the specific pod/sidecar that reported |
| `*_namespace`, `*_canonical_service`, `app` | `default`, `cart` | namespace / canonical naming — mostly redundant for single-namespace runs |

#### summary.json — the per-service scorecard (vector)

Five point-in-time vectors, each `destination_workload → value`, computed over the run window:

| Field | Unit | Meaning | PromQL |
|---|---|---|---|
| `request_rate` | requests/sec | requests received | `rate(istio_requests_total{reporter=destination}[w])` |
| `error_rate` | non-2xx/sec | error responses | same, filtered `response_code!~"2.."` |
| `p50_ms` / `p90_ms` / `p99_ms` | ms | server-side latency percentiles | `histogram_quantile(q, rate(..._bucket[w]))` |

Latency here is **measured at the receiving sidecar** (server-side service time), not
end-to-end. `error_rate / request_rate` = the service's error fraction. Example: cart
`request_rate ≈ 113.9` means cart received ~114 req/s averaged over the window. Because the
window is now the wrk load phase (not the whole run), these rates reflect peak load and line
up with wrk's numbers.

#### edges.json — the per-run call graph (vector)

`sum by (source_workload, destination_workload, destination_service_name, response_code)
(increase(istio_requests_total{reporter="destination"}[w]))`. Each result is one directed
edge with a request count *for this run*. This is the **HTTP/service dependency graph** — the
central artifact for understanding who-calls-whom. (`source→source` self-edges with count `0`
are empty label buckets; ignore them.)

#### Raw time-series — `requests_total`, `request_duration_ms`, `*_bytes`, `tcp_*` (matrix)

`query_range` dumps at 15s step over the window — the raw Prometheus JSON of the underlying
**cumulative** counters/histograms. Kept verbatim so downstream analysis can diff/derive its
own rates; `summary.json` and `edges.json` are pre-derived conveniences over these. Each
result has `metric` (the labels above) + `values`: an array of `[epoch, "value"]` pairs.
Values are **always JSON strings** (`"853"`) even though they're numbers — parse accordingly.

- **`requests_total.json`** — `istio_requests_total`, a monotonically increasing counter per
  unique label combination (155 series this run). `[1781650650, "853"]` = "by that epoch this
  src→dst→code series had seen 853 requests total." **Diff consecutive samples** (or apply
  `rate()`) to get throughput; it resets to 0 on a sidecar restart.
- **`request_duration_ms.json`** — `istio_request_duration_milliseconds_bucket`, a cumulative
  histogram. Each series carries an `le` ("less-or-equal") label = a bucket's upper bound in
  **ms**; the value is the count of requests that completed in `≤ le` ms. Buckets:
  `0.5, 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000, 60000, 300000,
  600000, 1800000, 3600000, +Inf`. Cumulative-by-bucket, so `le=10` includes `le=5`, and
  `le=+Inf` = total requests. `histogram_quantile()` interpolates across these for the
  percentiles in `summary.json` — bucket edges cap resolution, so treat single-digit-ms
  percentiles as approximate.
- **`request_bytes.json` / `response_bytes.json`** — `istio_request_bytes_sum` /
  `istio_response_bytes_sum`, cumulative sum of HTTP body bytes. Diff for bytes/sec, or divide
  by request count for mean payload size.
- **`tcp_sent_bytes.json` / `tcp_received_bytes.json`** — `istio_tcp_sent_bytes_total` /
  `istio_tcp_received_bytes_total`, cumulative bytes for connections Istio sees as **plain
  TCP** (no HTTP semantics), e.g. gRPC-over-TCP or non-HTTP services. Zero/absent for
  purely-HTTP services.

#### access_logs/<pod>.log — per-request provenance traces

One structured Envoy line per HTTP request handled by that pod's sidecar — the **most
granular Istio data**; `summary.json`/`edges.json` are its aggregation. Read off the worker's
rotated CRI log files (not `kubectl logs`, which only keeps the current `0.log` and silently
drops everything a busy sidecar already rotated away), then filtered to the window.

Example line and field map (Istio's default access-log format):

```
[2026-06-16T22:56:49.749Z] "GET /heartbeat HTTP/1.1" 200 - via_upstream - "-" 0 10 1 0 "-" "Wget" "e9c7fe77-..." "frontend:80" "10.244.2.245:3000" inbound|3000|| 127.0.0.6:51197 10.244.2.245:3000 10.244.1.224:38018 outbound_.80_._.frontend...svc.cluster.local default
```

| Token | Field | Notes |
|---|---|---|
| `[...Z]` | start time | UTC; used to window-filter the log |
| `"GET /heartbeat HTTP/1.1"` | method / path / protocol | |
| `200` | response code | |
| `-` | response flags | e.g. `UH`,`UF`,`DC` on failures; `-` = none |
| `via_upstream` | response code details | |
| `-` `"-"` | conn-termination / transport-failure | `-` when clean |
| `0` `10` | bytes received / sent | request & response body bytes |
| `1` `0` | duration / upstream service time | **ms**; duration − upstream = sidecar overhead |
| `"-"` `"Wget"` | X-Forwarded-For / User-Agent | |
| `"e9c7fe77-..."` | **X-Request-ID** | **same ID propagates across hops → stitch one request's full call tree across pods** |
| `"frontend:80"` | authority (`:authority`) | the requested host |
| `"10.244.2.245:3000"` | upstream host | actual pod IP:port serving it |
| `inbound\|3000\|\|` | upstream cluster | `inbound`/`outbound` + port |
| `127.0.0.6:51197` | upstream local addr | |
| `10.244.2.245:3000` | downstream local addr | this pod |
| `10.244.1.224:38018` | downstream remote addr | the caller |
| `outbound_.80_._.frontend...` | requested server name (SNI) | |
| `default` | route name | |

`X-Request-ID` is the join key: grep the same ID across every `*.log` to reconstruct one
client request's complete server-to-server call tree with per-hop latency.

---

### cilium/ — network (L3/L4 + DNS) view

The **packet/connection-level analog** to the Istio HTTP view. Captured by streaming Hubble
flows *live* for the whole run (`hubble observe -f`) — Hubble's relay keeps only a small
in-memory ring buffer, so querying after the fact would lose high-traffic flows.

#### flows.jsonl — every network flow, one JSON per line

One JSON object per line: `{"flow": {...}, "node_name": ..., "time": ...}`. The `flow` object
is the payload (the outer `node_name`/`time` just duplicate inner fields). This is the raw
network trace — the L3/L4 counterpart to `access_logs/`. It includes traffic the mesh never
sees: DNS, health probes, cross-node overlay (VXLAN), ICMP. **Note:** `flows.jsonl` is the
raw live capture over the whole run (the `capture_*` span, setup included); the derived
`edges.json`/`dns.jsonl` are scoped to the wrk window. Every key observed this run:

**Identity & verdict**
| Field | Example | Meaning |
|---|---|---|
| `time` | `2026-06-16T22:55:16.051589773Z` | when the flow was observed (UTC, ns precision) |
| `uuid` | `b59689ef-...` | unique id for this flow event |
| `emitter` | `{name:Hubble, version:1.19.3...}` | which Hubble produced it |
| `verdict` | `FORWARDED` / `DROPPED` | **was the packet allowed or dropped** (also `ERROR`, `AUDIT` possible) |
| `drop_reason` | `139` | numeric drop code (only on DROPPED) |
| `drop_reason_desc` | `UNSUPPORTED_L3_PROTOCOL` | human-readable drop cause (only on DROPPED) |
| `Type` | `L3_L4` / `L7` | flow granularity. `L3_L4` = packet/connection level; `L7` = an app-protocol event — with the `dns-visibility` policy, DNS lookups now appear as `L7` flows carrying `l7.dns`. HTTP/Kafka L7 are not captured by Cilium here (Istio owns HTTP) |
| `Summary` | `TCP Flags: ACK` | Hubble's one-line human summary |

**Layer 2 / 3 / 4 — the packet headers**
| Field | Example | Meaning |
|---|---|---|
| `ethernet.source/destination` | `0e:6d:d5:66:1a:a9` | MAC addresses (L2) |
| `IP.source/destination` | `10.244.0.180` → `10.244.4.29` | pod/node IP addresses (L3). `10.244.0.0/16` is the pod CIDR |
| `IP.ipVersion` | `IPv4` / `IPv6` | IP version |
| `l4.TCP` | `{source_port, destination_port, flags:{ACK:true}}` | TCP segment: ports + flags (`SYN`/`ACK`/`FIN`/`RST`/`PSH`) |
| `l4.UDP` | `{source_port, destination_port}` | UDP datagram (e.g. DNS uses dst port 53) |
| `l4.ICMPv4`/`l4.ICMPv6` | `{type: 135}` | ICMP message (135 = IPv6 Neighbor Solicitation) |

`destination_port` is the meaningful one for identifying *what service*: `:53`=DNS,
`:3000`=frontend, `:15020`=Istio sidecar health, `:4240`=Cilium health, `:10250`=kubelet.

**Endpoints — who is talking (source / destination objects)**
Both `source` and `destination` carry the **Cilium identity** of each end:
| Field | Example | Meaning |
|---|---|---|
| `identity` | `8117` | Cilium's numeric security identity (a hash of the label set). Reserved: `1`=host, `2`=world, `6`=remote-node |
| `cluster_name` | `kubernetes` | which cluster the endpoint is in |
| `namespace` | `kube-system` | k8s namespace (absent for non-pod endpoints) |
| `pod_name` | `metrics-server-7f65d98447-vz2tb` | the pod, if it is one |
| `labels` | `["k8s:app=...","reserved:remote-node"]` | the full label identity. `reserved:*` mark non-pod entities: `host`, `remote-node`, `world` (off-cluster), `unknown`, `health` |
| `workloads` | `[{name, kind}]` | owning workload (Deployment/DaemonSet), when known |

`collect_metrics.py` reduces each endpoint to a single label via `_flow_endpoint_label`
(workload name → pod stem → `namespace/*` → `reserved:` name) to build `cilium/edges.json`.

**Topology & tracing — where in the datapath**
| Field | Example | Meaning |
|---|---|---|
| `node_name` | `kubernetes/node-0...` | which cluster node observed the flow |
| `node_labels` | `[...control-plane...]` | that node's k8s labels |
| `traffic_direction` | `EGRESS` / `INGRESS` | relative to the reporting endpoint: leaving (10825×) vs entering (4928×) |
| `trace_observation_point` | `TO_ENDPOINT` / `TO_STACK` / `TO_OVERLAY` | **where in the datapath** the packet was seen: `TO_ENDPOINT`=delivered to a pod's veth (8663×), `TO_STACK`=handed to host stack (3933×), `TO_OVERLAY`=sent into the VXLAN tunnel (3604×) |
| `trace_reason` | `NEW` / `ESTABLISHED` / `REPLY` | connection-tracking state of the packet |
| `interface` | `{index, name: cilium_vxlan}` | the netdev it traversed (`cilium_vxlan` = cross-node overlay tunnel) |
| `is_reply` / `reply` | `true` | whether this packet is a reply in its connection |
| `event_type` | `{type:4, sub_type:4}` | raw Cilium monitor event code. `type:4`=trace, `type:1`=drop (its `sub_type` mirrors `drop_reason`) |
| `file` | `{name: bpf_lxc.c, line: 1831}` | the BPF source location that emitted the event (mainly for drops) |

**Worked drop example** from this run: source `ubuntu-client`, dst `reserved:unknown`,
`l4.ICMPv6.type=135` (Neighbor Solicitation), `verdict=DROPPED`,
`drop_reason_desc=UNSUPPORTED_L3_PROTOCOL`, `event_type={type:1,sub_type:139}`. Reading: the
client pod sent an IPv6 neighbor-discovery packet that Cilium's IPv4-only datapath dropped.
All 29 drops this run are this benign IPv6 ND noise — **not** policy denials.

#### edges.json — the per-run network graph

```json
{ "total_flows": 4102, "captured_flows": 16229,
  "edges": [ {"source":"frontend","destination":"coredns",
              "destination_port":"53","verdict":"FORWARDED","count":406}, ... ] }
```

Flows **in the wrk window** aggregated to `(source, destination, destination_port, verdict) →
count`, sorted by count. This is the **network dependency graph** — compare it to
`istio/edges.json`: the Istio
graph shows HTTP calls by service, this shows every TCP/UDP/DNS/probe flow by port, so it's
strictly broader (e.g. the `*:53` edges to `coredns` and `*:4240` health-check edges have no
Istio counterpart).

| Field | Meaning |
|---|---|
| `total_flows` | flow lines aggregated into the graph (in the wrk window) |
| `captured_flows` | flow lines in the raw capture (whole run, setup included) — `total_flows` is the in-window subset |
| `source` / `destination` | endpoint labels from `_flow_endpoint_label` |
| `destination_port` | the L4 dst port (the service identifier; `""` if no L4) |
| `verdict` | `FORWARDED` or `DROPPED` (same edge can appear once per verdict) |
| `count` | number of flows matching that 4-tuple in the window |

#### dns.jsonl — DNS flows

The subset of `flows.jsonl` (in the wrk window) whose records carry a parsed `l7.dns` object —
i.e. the actual hostname each pod resolved. Populated by the `dns-visibility`
`CiliumClusterwideNetworkPolicy` (observation-only) that routes DNS through Cilium's DNS proxy;
see `k8s/cilium/dns-visibility.yaml`. Without that policy this file is empty (port-53 traffic is
seen at L3/L4 only). **Empty in the example run above**, which predates the policy.

#### hubble_metrics.prom — Hubble's own counters

Prometheus text format: `metric_name{label="v",...} value`. Point-in-time scrape of
`hubble-metrics:9965`. **Cumulative since the Cilium agent started — NOT scoped to the run
window** (unlike everything else), so diffing this across runs is meaningless. Useful keys:

| Metric | Meaning |
|---|---|
| `hubble_flows_processed_total{protocol,type,subtype,verdict}` | flows seen, by protocol (TCP/ICMPv4…), event type (`Trace`), datapath subtype (`to-endpoint`/`to-overlay`/`to-stack`), verdict |
| `hubble_drop_total{...}` | dropped packets by reason/direction (absent/zero here ⇒ no policy drops) |
| `hubble_icmp_total{family,type}` | ICMP messages, e.g. `EchoRequest`/`EchoReply` (ping) |
| `hubble_lost_events_total{source="hubble_ring_buffer"}` | **events Hubble dropped because its ring buffer overflowed** — `12` this run, meaning `flows.jsonl` is missing ~12 flows. A capture-fidelity caveat for exact counts |
| `grpc_server_handled_total{...}` | Hubble's own gRPC API serving stats — internal, ignorable |
| `hubble_metrics_http_handler_request_duration_seconds_bucket{le}` | latency histogram of the `/metrics` endpoint itself — internal, ignorable |

---

## 6. Cross-referencing the layers (worked example)

For one `mix` request to `frontend`:
1. **`wrk.txt`** — it counts as 1 request; end-to-end latency lands in the distribution.
2. **`istio/edges.json`** — that request fans out to `frontend→cart`, `frontend→productcatalog`,
   `frontend→currency`, … each an HTTP edge with its own count.
3. **`istio/access_logs/*.log`** — each hop is one line; all share the request's
   `X-Request-ID`, so you can rebuild the exact call tree and per-hop timing.
4. **`cilium/edges.json` + `flows.jsonl`** — those HTTP calls ride TCP flows, preceded by
   `*→coredns:53` DNS lookups and interleaved with `:4240` health probes — none of which
   appear at the Istio layer.
5. **`resources.csv`** — the CPU/mem cost of serving it, per pod, on the same `epoch` clock.

In short: **Istio answers "which service called which, and how fast" (L7);
Cilium answers "which pod opened which connection to which port" (L3/L4).** They agree on the
application call graph and diverge exactly where infrastructure traffic (DNS, probes, overlay)
lives.



