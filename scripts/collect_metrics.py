#!/usr/bin/env python3
"""
Collect Istio service-mesh metrics + Envoy access logs for a single benchmark
run and write them under <results-dir>/istio/.

Runs ON the control node (it shells out to kubectl). The in-cluster Prometheus
is only reachable from inside the cluster, so we open a temporary
`kubectl port-forward` to it rather than relying on a NodePort.

Two kinds of metric data are captured:

  * time-series (query_range, 15s step) of the raw Istio counters/histograms
    over the run window  -> requests_total.json, request_duration_ms.json, ...
    Raw cumulative series are kept verbatim; downstream analysis diffs/derives
    rates from them.

  * point-in-time summaries computed over the exact run window via increase()/
    rate() at the END instant, so they describe THIS run only and are immune to
    traffic from earlier runs sitting in the same cumulative counters:
        edges.json    source_workload -> destination_workload request counts
        summary.json  per-service request rate, error rate, p50/p90/p99 latency

Plus the Envoy sidecar access logs (one structured line per request) for every
mesh pod, sliced to the run window -> access_logs/<pod>.log. These are the
per-request provenance traces; the metrics above are their aggregation.

If the cluster has no Istio (no istio-system namespace) this is a no-op so the
caller can run it unconditionally on bare clusters.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

PROM_NS = "istio-system"
PROM_SVC = "svc/prometheus"
PROM_PORT = 9090
PROM_CONTAINER = "prometheus-server"  # demo-profile addon pod has 2 containers

# Raw counters/histograms captured as a time-series over the whole window.
RANGE_METRICS = {
    "requests_total": "istio_requests_total",
    "request_duration_ms": "istio_request_duration_milliseconds_bucket",
    "request_bytes": "istio_request_bytes_sum",
    "response_bytes": "istio_response_bytes_sum",
    "tcp_sent_bytes": "istio_tcp_sent_bytes_total",
    "tcp_received_bytes": "istio_tcp_received_bytes_total",
}


def kubectl(*args, check=True, **kw):
    return subprocess.run(["kubectl", *args], text=True,
                          capture_output=True, check=check, **kw)


def istio_present():
    return kubectl("get", "ns", PROM_NS, check=False).returncode == 0


def cilium_present():
    return kubectl("-n", "kube-system", "get", "ds", "cilium",
                   check=False).returncode == 0


def prom_query(base, path, params):
    url = f"{base}/api/v1/{path}?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def wait_for_prom(base, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            prom_query(base, "query", {"query": "vector(1)"})
            return True
        except Exception:
            time.sleep(1)
    return False


def dump(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)


def collect_metrics(base, out_dir, start, end, step):
    window = max(1, end - start)
    win = f"{window}s"

    # --- raw time-series ---------------------------------------------------
    for name, metric in RANGE_METRICS.items():
        try:
            res = prom_query(base, "query_range",
                             {"query": metric, "start": start,
                              "end": end, "step": step})
        except Exception as e:
            res = {"status": "error", "error": str(e), "query": metric}
        dump(os.path.join(out_dir, f"{name}.json"), res)

    # --- per-run call graph (edges) ---------------------------------------
    # Filter reporter='destination': istio_requests_total is emitted by BOTH the
    # source and destination sidecar for every request, so summing across
    # reporters double-counts each edge. The destination view is the canonical
    # "requests received by D from S" (external ingress shows as source
    # 'unknown', which is correct).
    edge_q = (f"sum by (source_workload,destination_workload,destination_service_name,"
              f"response_code) (increase(istio_requests_total{{reporter='destination'}}[{win}]))")
    try:
        edges = prom_query(base, "query", {"query": edge_q, "time": end})
    except Exception as e:
        edges = {"status": "error", "error": str(e), "query": edge_q}
    dump(os.path.join(out_dir, "edges.json"), edges)

    # --- per-service summary ----------------------------------------------
    # All destination-reported (see edge query note) so counts/rates aren't
    # doubled and percentiles reflect the receiving service's own histogram.
    summary_qs = {
        "request_rate":
            f"sum by (destination_workload)(rate(istio_requests_total{{reporter='destination'}}[{win}]))",
        "error_rate":
            f'sum by (destination_workload)(rate(istio_requests_total{{reporter="destination",response_code!~"2.."}}[{win}]))',
        "p50_ms":
            f"histogram_quantile(0.50, sum by (destination_workload,le)"
            f"(rate(istio_request_duration_milliseconds_bucket{{reporter='destination'}}[{win}])))",
        "p90_ms":
            f"histogram_quantile(0.90, sum by (destination_workload,le)"
            f"(rate(istio_request_duration_milliseconds_bucket{{reporter='destination'}}[{win}])))",
        "p99_ms":
            f"histogram_quantile(0.99, sum by (destination_workload,le)"
            f"(rate(istio_request_duration_milliseconds_bucket{{reporter='destination'}}[{win}])))",
    }
    summary = {}
    for name, q in summary_qs.items():
        try:
            summary[name] = prom_query(base, "query", {"query": q, "time": end})
        except Exception as e:
            summary[name] = {"status": "error", "error": str(e), "query": q}
    dump(os.path.join(out_dir, "summary.json"), summary)


def collect_access_logs(out_dir, start_iso):
    """Dump each mesh pod's Envoy sidecar access log, sliced to the run window."""
    os.makedirs(out_dir, exist_ok=True)
    pods = kubectl("get", "pods", "-o",
                   "jsonpath={range .items[*]}{.metadata.name}{\" \"}"
                   "{range .spec.containers[*]}{.name}{\",\"}{end}{\"\\n\"}{end}",
                   check=False).stdout.strip().splitlines()
    found_any = False
    for line in pods:
        if not line.strip():
            continue
        pod, _, containers = line.partition(" ")
        if "istio-proxy" not in containers.split(","):
            continue  # no sidecar (e.g. ubuntu-client) -> nothing to pull
        logs = kubectl("logs", pod, "-c", "istio-proxy",
                       f"--since-time={start_iso}", check=False)
        with open(os.path.join(out_dir, f"{pod}.log"), "w") as f:
            f.write(logs.stdout)
        if logs.stdout.strip():
            found_any = True
    if not found_any:
        # Access logging is off in some Istio profiles; leave a breadcrumb.
        with open(os.path.join(out_dir, "_README.txt"), "w") as f:
            f.write("Envoy access logs were empty.\n"
                    "Enable with: istioctl install --set meshConfig.accessLogFile=/dev/stdout\n")


def _flow_endpoint_label(ep):
    """Best-effort stable node label for a Hubble flow endpoint, robust to the
    fields that may be missing (system flows, host traffic, world/CIDR)."""
    if not isinstance(ep, dict):
        return "unknown"
    wls = ep.get("workloads") or []
    if wls and wls[0].get("name"):
        return wls[0]["name"]
    pod = ep.get("pod_name") or ""
    if pod:  # strip the replicaset/pod hash suffixes -> deployment-ish name
        return "-".join(pod.split("-")[:-2]) if pod.count("-") >= 2 else pod
    ns = ep.get("namespace")
    if ns:
        return f"{ns}/*"
    ids = ep.get("labels") or []
    for lbl in ids:
        if lbl.startswith("reserved:"):
            return lbl.split(":", 1)[1]   # world / host / remote-node / ...
    return "unknown"


def collect_cilium(out_dir, flows_path):
    """Post-process the live-captured Hubble flows (flows.jsonl, written by
    run_and_collect.sh) into a network call graph + DNS slice, and snapshot the
    Hubble Prometheus metrics. The flow log is the L3/L4 (and DNS) analog to the
    Istio Envoy access logs; edges.json is the network analog to istio/edges.json."""
    os.makedirs(out_dir, exist_ok=True)

    # Hubble metrics endpoint (raw Prometheus text on :9965). Snapshot via a
    # short-lived port-forward; cumulative counters, so a point-in-time grab.
    pf = subprocess.Popen(
        ["kubectl", "-n", "kube-system", "port-forward",
         "svc/hubble-metrics", "9965:9965"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + 15
        text = None
        while time.time() < deadline:
            try:
                with urllib.request.urlopen(
                        "http://127.0.0.1:9965/metrics", timeout=10) as r:
                    text = r.read().decode("utf-8", "replace")
                break
            except Exception:
                time.sleep(1)
        if text is not None:
            with open(os.path.join(out_dir, "hubble_metrics.prom"), "w") as f:
                f.write(text)
        else:
            print("[collect_metrics] WARN: could not scrape hubble-metrics:9965",
                  file=sys.stderr)
    finally:
        pf.terminate()
        try:
            pf.wait(timeout=5)
        except Exception:
            pf.kill()

    # Derive the network graph + DNS flows from the captured jsonl.
    if not flows_path or not os.path.exists(flows_path):
        return
    edges = {}        # (src, dst, dport, verdict) -> count
    dns_lines = []
    n = 0
    with open(flows_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            flow = obj.get("flow", obj)
            n += 1
            src = _flow_endpoint_label(flow.get("source"))
            dst = _flow_endpoint_label(flow.get("destination"))
            verdict = flow.get("verdict", "UNKNOWN")
            l4 = flow.get("l4") or {}
            dport = ""
            for proto in ("TCP", "UDP", "ICMPv4", "ICMPv6"):
                if proto in l4:
                    dport = l4[proto].get("destination_port", proto)
                    break
            edges[(src, dst, str(dport), verdict)] = \
                edges.get((src, dst, str(dport), verdict), 0) + 1
            if (flow.get("l7") or {}).get("dns"):
                dns_lines.append(line)

    edge_list = [{"source": s, "destination": d, "destination_port": p,
                  "verdict": v, "count": c}
                 for (s, d, p, v), c in
                 sorted(edges.items(), key=lambda kv: -kv[1])]
    dump(os.path.join(out_dir, "edges.json"),
         {"total_flows": n, "edges": edge_list})
    with open(os.path.join(out_dir, "dns.jsonl"), "w") as f:
        f.write("\n".join(dns_lines))
    print(f"[collect_metrics] cilium: {n} flows -> {len(edge_list)} edges, "
          f"{len(dns_lines)} dns")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="run results dir (contains istio/)")
    ap.add_argument("--start", type=int, required=True, help="window start, epoch s")
    ap.add_argument("--end", type=int, required=True, help="window end, epoch s")
    ap.add_argument("--start-iso", required=True, help="window start, RFC3339 (for logs)")
    ap.add_argument("--step", default="15s", help="time-series step (default 15s)")
    args = ap.parse_args()

    # Istio and Cilium are independent sources; collect whichever is present.
    if istio_present():
        istio_dir = os.path.join(args.dir, "istio")
        os.makedirs(istio_dir, exist_ok=True)
        print("[collect_metrics] opening port-forward to Prometheus")
        pf = subprocess.Popen(
            ["kubectl", "-n", PROM_NS, "port-forward", PROM_SVC,
             f"{PROM_PORT}:{PROM_PORT}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            base = f"http://127.0.0.1:{PROM_PORT}"
            if not wait_for_prom(base):
                print("[collect_metrics] ERROR: Prometheus not reachable via port-forward",
                      file=sys.stderr)
            else:
                print("[collect_metrics] querying Istio metrics over window "
                      f"[{args.start}, {args.end}] ({args.end - args.start}s)")
                collect_metrics(base, istio_dir, args.start, args.end, args.step)
                print("[collect_metrics] dumping Envoy access logs")
                collect_access_logs(os.path.join(istio_dir, "access_logs"),
                                    args.start_iso)
        finally:
            pf.terminate()
            try:
                pf.wait(timeout=5)
            except Exception:
                pf.kill()
        print(f"[collect_metrics] done -> {istio_dir}")
    else:
        print("[collect_metrics] no istio-system namespace; skipping Istio collection")

    if cilium_present():
        cilium_dir = os.path.join(args.dir, "cilium")
        print("[collect_metrics] processing Cilium/Hubble flows + metrics")
        collect_cilium(cilium_dir, os.path.join(cilium_dir, "flows.jsonl"))
        print(f"[collect_metrics] done -> {cilium_dir}")
    else:
        print("[collect_metrics] no cilium DaemonSet; skipping Cilium collection")

    return 0


if __name__ == "__main__":
    sys.exit(main())
