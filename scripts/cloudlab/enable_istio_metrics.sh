#!/bin/bash
#
# Enable Istio service-level metric collection. Runs on the MAIN node (it owns
# the kubeconfig from after_join.sh). setup_kube.py executes this after the
# workers join, gated by "enable_istio_metrics" in config.json. Idempotent.
#
# Installs the Istio control plane (demo profile -> telemetry on), deploys the
# Prometheus addon, and turns on sidecar auto-injection for the default
# namespace. After (re)deploying a benchmark, each microservice pod gets an
# Envoy sidecar exporting:
#   istio_requests_total                  (per-service request count / errors)
#   istio_request_duration_milliseconds   (per-service latency histogram)
#   istio_request_bytes / istio_response_bytes
#
# The load-generator client (client/client.yaml) sets
# sidecar.istio.io/inject: "false", so its traffic stays out of the mesh.
# metrics-server (kubectl top) keeps working independently for CPU/memory.

set -euo pipefail

ISTIO_VERSION="${ISTIO_VERSION:-1.18.0}"
NAMESPACE="${NAMESPACE:-default}"

cd "$(dirname "$0")"

# istiod doesn't tolerate the control-plane taint, so it needs a Ready worker.
echo "[enable_istio_metrics] Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s || \
    echo "[enable_istio_metrics] WARN: not all nodes Ready, continuing anyway"

# 1. Control plane. `istioctl install` is reconciling/idempotent, so it runs
#    unconditionally: on a fresh cluster it installs, on an existing one it
#    applies config drift (e.g. switching access logs to JSON encoding — the
#    setting is pushed to sidecars via xDS, no pod restarts needed). Only the
#    istioctl download itself is gated.
#    JSON access logs give the GNN ingest pipeline a stable per-request record
#    (start_time, method, path, response_code, upstream_cluster, x-request-id)
#    instead of the fragile default text format.
if ! command -v istioctl >/dev/null 2>&1; then
    echo "[enable_istio_metrics] Downloading Istio $ISTIO_VERSION"
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" sh -
    istio_dir=$(ls -d istio-"$ISTIO_VERSION" 2>/dev/null || ls -d istio-*)
    sudo mv "$istio_dir"/bin/istioctl /usr/local/bin
fi
echo "[enable_istio_metrics] Installing/reconciling Istio (profile=demo, JSON access logs)"
istioctl install --set profile=demo \
    --set meshConfig.accessLogFile=/dev/stdout \
    --set meshConfig.accessLogEncoding=JSON \
    -y

# 2. Prometheus addon (+ optional dashboards).
addon_dir=""
if compgen -G "istio-*/samples/addons" >/dev/null; then
    addon_dir=$(ls -d istio-*/samples/addons | head -n1)
else
    echo "[enable_istio_metrics] Fetching Istio addons ($ISTIO_VERSION)"
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" sh -
    addon_dir=$(ls -d istio-*/samples/addons | head -n1)
fi
echo "[enable_istio_metrics] Applying Prometheus / Grafana / Kiali addons"
kubectl apply -f "$addon_dir/prometheus.yaml"
kubectl apply -f "$addon_dir/grafana.yaml"
kubectl apply -f "$addon_dir/kiali.yaml"

# 3. Sidecar auto-injection for the benchmark namespace.
echo "[enable_istio_metrics] Labelling namespace '$NAMESPACE' for sidecar injection"
kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite

echo "[enable_istio_metrics] Done."
echo
echo "Query metrics from the control node (or copy ~/.kube/config to your laptop):"
echo "  kubectl -n istio-system port-forward svc/prometheus 9090:9090"
echo "  # http://localhost:9090 -> e.g. istio_requests_total"
echo "  # histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket[1m])) by (le, destination_service))"
