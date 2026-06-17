#!/bin/bash
#
# Wrap scripts/run.sh with metric/log collection for one benchmark run.
#
# Runs ON the control node. Leaves run.sh itself untouched (it is shared by the
# ec2/local deploy paths); all capture happens around it here:
#
#   * brackets the run with a start/end timestamp (the Istio query window)
#   * samples `kubectl top pods` every 5s -> resources.csv (CPU/mem time-series)
#   * tees the full run.sh output -> run.log, and slices out the wrk block -> wrk.txt
#   * writes meta.json (params + window + istio on/off)
#   * invokes collect_metrics.py for the Istio time-series, call graph, summary,
#     and Envoy access logs (no-op on a cluster without Istio)
#
# Everything lands under one self-contained run directory which the caller
# (deploy.sh) copies back to the host. Usage mirrors run.sh's positional args:
#
#   run_and_collect.sh <bench> <request> <threads> <conns> <duration>
#
# Env:
#   RESULTS_ROOT  where run dirs live on the control node (default ~/ubench/results)
#   RUN_ID        run-dir suffix (default: UTC timestamp); set by deploy.sh so the
#                 host knows which dir to pull back
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bench="${1:-boutique}"
request="${2:-mix}"
thread="${3:-4}"
conn="${4:-16}"
duration="${5:-30}"

RESULTS_ROOT="${RESULTS_ROOT:-$HOME/ubench/results}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
DIR="${RESULTS_ROOT}/${bench}-${request}_${RUN_ID}"
mkdir -p "${DIR}/istio/access_logs" "${DIR}/cilium"

START_EPOCH="$(date -u +%s)"
START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Background resource sampler: per-pod CPU/mem every 5s. metrics-server is the
# only resource source here (the Istio Prometheus does not scrape cAdvisor), so
# this is how we get a time-series rather than run.sh's single snapshot.
{
	echo "epoch,pod,cpu,mem"
	while true; do
		ts="$(date -u +%s)"
		kubectl top pods --no-headers 2>/dev/null \
			| awk -v t="${ts}" '{print t","$1","$2","$3}'
		sleep 5
	done
} > "${DIR}/resources.csv" &
SAMPLER=$!

# Cilium/Hubble flow capture (only if Cilium is the CNI). Hubble's relay keeps
# just a small in-memory ring buffer, so a high-traffic run would overflow it —
# we must STREAM flows live for the whole run rather than query after the fact.
# `cilium hubble port-forward` exposes the relay on :4245; `hubble observe -f`
# then tails every flow as JSON lines (the network-level analog to the Envoy
# access logs). Both are backgrounded and torn down with the run; best-effort.
HUBBLE_PF_PID=""
HUBBLE_OBS_PID=""
if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
	cilium hubble port-forward >/dev/null 2>&1 &
	HUBBLE_PF_PID=$!
	# Wait for the relay port before tailing (best-effort, ~10s cap).
	for _ in $(seq 1 10); do
		if hubble status --server localhost:4245 >/dev/null 2>&1; then break; fi
		sleep 1
	done
	# jsonpb is Hubble's newline-delimited JSON (one {"flow":{...}} per line);
	# there is no "jsonl" format. flows.jsonl keeps the .jsonl extension since
	# that is exactly the shape jsonpb emits.
	hubble observe -f -o jsonpb --server localhost:4245 \
		> "${DIR}/cilium/flows.jsonl" 2>"${DIR}/cilium/_capture.err" &
	HUBBLE_OBS_PID=$!
fi

# The actual benchmark. Tee so the operator still sees live output while we
# keep the full record. PIPESTATUS[0] is run.sh's exit code (not tee's).
bash "${SCRIPT_DIR}/run.sh" "${bench}" "${request}" "${thread}" "${conn}" "${duration}" \
	2>&1 | tee "${DIR}/run.log"
STATUS="${PIPESTATUS[0]}"

# wrk runs at the very end of run.sh and run.sh exits immediately after it, so
# "now" is effectively the wrk end. Capture it BEFORE teardown so the metric
# window is the load phase, not the whole run (deploy verification, the
# heartbeat connectivity sweep, populate, and the inter-step sleeps all happen
# inside START_EPOCH..END_EPOCH and would otherwise dilute every rate/percentile).
WRK_END_EPOCH="$(date -u +%s)"

kill "${SAMPLER}" 2>/dev/null
wait "${SAMPLER}" 2>/dev/null
[ -n "${HUBBLE_OBS_PID}" ] && { kill "${HUBBLE_OBS_PID}" 2>/dev/null; wait "${HUBBLE_OBS_PID}" 2>/dev/null; }
[ -n "${HUBBLE_PF_PID}" ]  && { kill "${HUBBLE_PF_PID}"  2>/dev/null; wait "${HUBBLE_PF_PID}"  2>/dev/null; }

END_EPOCH="$(date -u +%s)"
END_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Slice the wrk stats block out of the combined log for convenience.
awk '/Running .* test @/{p=1} p{print} /Transfer\/sec/{p=0}' \
	"${DIR}/run.log" > "${DIR}/wrk.txt"

# Metric window = the wrk load phase only. wrk reports its own measured wall time
# ("N requests in 30.02s, ..."); use that as the window length (rounded up) and
# anchor it to WRK_END_EPOCH. Fall back to the requested duration if the line is
# missing (e.g. wrk crashed). This window is what the Istio queries, the Envoy
# access-log filter, and the Cilium flow aggregation are all scoped to.
# Portable extract (sed, not gawk's 3-arg match which mawk lacks) of "...in 30.02s".
WRK_SECONDS="$(sed -n 's/.*requests in \([0-9.]*\)s.*/\1/p' "${DIR}/wrk.txt" | head -1)"
if [ -z "${WRK_SECONDS}" ]; then
	WRK_WINDOW="${duration}"
else
	# ceil() so a 30.02s run yields a 31s window that fully contains the load.
	WRK_WINDOW="$(awk -v s="${WRK_SECONDS}" 'BEGIN{print int(s)+(s>int(s)?1:0)}')"
fi
WRK_START_EPOCH=$(( WRK_END_EPOCH - WRK_WINDOW ))
WRK_START_ISO="$(date -u -d "@${WRK_START_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
WRK_END_ISO="$(date -u -d "@${WRK_END_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"

ISTIO_ON=false
kubectl get ns istio-system >/dev/null 2>&1 && ISTIO_ON=true
CILIUM_ON=false
kubectl -n kube-system get ds cilium >/dev/null 2>&1 && CILIUM_ON=true

# start_epoch/end_epoch are the METRIC window (the wrk load phase); every metric
# file is scoped to it. capture_*_epoch is the full run_and_collect span (setup
# included) — kept for reference and for matching against the raw flows.jsonl.
cat > "${DIR}/meta.json" <<JSON
{
  "benchmark": "${bench}",
  "request": "${request}",
  "threads": ${thread},
  "connections": ${conn},
  "duration_s": ${duration},
  "run_id": "${RUN_ID}",
  "start_epoch": ${WRK_START_EPOCH},
  "end_epoch": ${WRK_END_EPOCH},
  "start_iso": "${WRK_START_ISO}",
  "end_iso": "${WRK_END_ISO}",
  "capture_start_epoch": ${START_EPOCH},
  "capture_end_epoch": ${END_EPOCH},
  "capture_start_iso": "${START_ISO}",
  "capture_end_iso": "${END_ISO}",
  "istio_enabled": ${ISTIO_ON},
  "cilium_enabled": ${CILIUM_ON},
  "run_status": ${STATUS}
}
JSON

# Istio metrics + access logs (self-skips if Istio is absent). Scoped to the wrk
# window so rates/percentiles reflect peak load, not the diluted whole-run span.
python3 "${SCRIPT_DIR}/collect_metrics.py" \
	--dir "${DIR}" --start "${WRK_START_EPOCH}" --end "${WRK_END_EPOCH}" \
	--start-iso "${WRK_START_ISO}" || echo "[run_and_collect] WARN: metric collection failed"

echo "[run_and_collect] run dir: ${DIR}"
# Last line is the absolute run dir, so the caller can locate it to copy back.
echo "${DIR}"
exit "${STATUS}"
