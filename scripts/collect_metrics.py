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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="run results dir (contains istio/)")
    ap.add_argument("--start", type=int, required=True, help="window start, epoch s")
    ap.add_argument("--end", type=int, required=True, help="window end, epoch s")
    ap.add_argument("--start-iso", required=True, help="window start, RFC3339 (for logs)")
    ap.add_argument("--step", default="15s", help="time-series step (default 15s)")
    args = ap.parse_args()

    istio_dir = os.path.join(args.dir, "istio")
    if not istio_present():
        print("[collect_metrics] no istio-system namespace; skipping Istio collection")
        return 0
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
            return 1
        print("[collect_metrics] querying metrics over window "
              f"[{args.start}, {args.end}] ({args.end - args.start}s)")
        collect_metrics(base, istio_dir, args.start, args.end, args.step)
        print("[collect_metrics] dumping Envoy access logs")
        collect_access_logs(os.path.join(istio_dir, "access_logs"), args.start_iso)
    finally:
        pf.terminate()
        try:
            pf.wait(timeout=5)
        except Exception:
            pf.kill()
    print(f"[collect_metrics] done -> {istio_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
