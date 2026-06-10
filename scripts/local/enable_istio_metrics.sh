#!/bin/bash
#
# Enable Istio service-level metric collection. Runs on the MAIN node (it owns
# the kubeconfig from after_join.sh). setup_kube.py executes this after the
# workers join, gated by "enable_istio_metrics" in config.json. Idempotent.
#
# Installs the Istio control plane (demo profile -> telemetry on), deploys the
# Prometheus + Jaeger addons, and turns on sidecar auto-injection for the
# default namespace. After (re)deploying a benchmark, each microservice pod gets
# an Envoy sidecar exporting:
#   istio_requests_total                  (per-service request count / errors)
#   istio_request_duration_milliseconds   (per-service latency histogram)
#   istio_request_bytes / istio_response_bytes
# and emitting distributed-tracing spans to Jaeger (per-request, per-hop
# latency timeline — decomposes a slow request across the call DAG, which the
# aggregate metrics above cannot).
#
# The load-generator client (client/client.yaml) sets
# sidecar.istio.io/inject: "false", so its traffic stays out of the mesh.
# metrics-server (kubectl top) keeps working independently for CPU/memory.
#
# NOTE on traces: Envoy generates a span per hop automatically, but stitching a
# multi-hop trace requires the app to propagate the trace headers (b3 /
# traceparent, x-request-id) from each inbound request to its outbound calls. If
# a benchmark doesn't propagate them, Jaeger shows disconnected single-hop spans
# rather than one end-to-end trace. Verify per benchmark.

set -euo pipefail

ISTIO_VERSION="${ISTIO_VERSION:-1.18.0}"
NAMESPACE="${NAMESPACE:-default}"
# Trace sampling percentage (0-100). 100 = trace every request, appropriate for
# a controlled benchmark; lower it for production-like load.
TRACING_SAMPLING="${TRACING_SAMPLING:-100}"

cd "$(dirname "$0")"

# istiod doesn't tolerate the control-plane taint, so it needs a Ready worker.
echo "[enable_istio_metrics] Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s || \
    echo "[enable_istio_metrics] WARN: not all nodes Ready, continuing anyway"

# 1. Control plane.
if ! kubectl get namespace istio-system >/dev/null 2>&1; then
    if ! command -v istioctl >/dev/null 2>&1; then
        echo "[enable_istio_metrics] Downloading Istio $ISTIO_VERSION"
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" sh -
        istio_dir=$(ls -d istio-"$ISTIO_VERSION" 2>/dev/null || ls -d istio-*)
        sudo mv "$istio_dir"/bin/istioctl /usr/local/bin
    fi
    echo "[enable_istio_metrics] Installing Istio control plane (profile=demo, tracing -> Jaeger, sampling=${TRACING_SAMPLING}%)"
    # Point the tracer at the Jaeger addon's zipkin-compatible collector
    # (zipkin.istio-system:9411, created by jaeger.yaml below) and set sampling.
    istioctl install --set profile=demo -y \
        --set meshConfig.enableTracing=true \
        --set meshConfig.defaultConfig.tracing.sampling="${TRACING_SAMPLING}" \
        --set meshConfig.defaultConfig.tracing.zipkin.address=zipkin.istio-system:9411
else
    echo "[enable_istio_metrics] istio-system already present, skipping control-plane install"
fi

# 2. Prometheus addon (+ optional dashboards).
addon_dir=""
if compgen -G "istio-*/samples/addons" >/dev/null; then
    addon_dir=$(ls -d istio-*/samples/addons | head -n1)
else
    echo "[enable_istio_metrics] Fetching Istio addons ($ISTIO_VERSION)"
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" sh -
    addon_dir=$(ls -d istio-*/samples/addons | head -n1)
fi
echo "[enable_istio_metrics] Applying Prometheus / Grafana / Kiali / Jaeger addons"
kubectl apply -f "$addon_dir/prometheus.yaml"
kubectl apply -f "$addon_dir/grafana.yaml"
kubectl apply -f "$addon_dir/kiali.yaml"
# Jaeger: distributed-tracing backend. Its addon creates the istio-system
# "zipkin" service (port 9411) the tracer above points at, plus the "tracing"
# service (Jaeger UI on port 80 -> 16686).
kubectl apply -f "$addon_dir/jaeger.yaml"

# 3. Sidecar auto-injection for the benchmark namespace.
echo "[enable_istio_metrics] Labelling namespace '$NAMESPACE' for sidecar injection"
kubectl label namespace "$NAMESPACE" istio-injection=enabled --overwrite

echo "[enable_istio_metrics] Done."
echo
echo "Query metrics from the control node (or copy ~/.kube/config to your laptop):"
echo "  kubectl -n istio-system port-forward svc/prometheus 9090:9090"
echo "  # http://localhost:9090 -> e.g. istio_requests_total"
echo "  # histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket[1m])) by (le, destination_service))"
echo "View traces in Jaeger:"
echo "  kubectl -n istio-system port-forward svc/tracing 16686:80"
echo "  # http://localhost:16686 -> pick service 'checkout.default' to see per-hop timelines"
