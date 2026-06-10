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
mkdir -p "${DIR}/istio/access_logs"

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

# The actual benchmark. Tee so the operator still sees live output while we
# keep the full record. PIPESTATUS[0] is run.sh's exit code (not tee's).
bash "${SCRIPT_DIR}/run.sh" "${bench}" "${request}" "${thread}" "${conn}" "${duration}" \
	2>&1 | tee "${DIR}/run.log"
STATUS="${PIPESTATUS[0]}"

kill "${SAMPLER}" 2>/dev/null
wait "${SAMPLER}" 2>/dev/null

END_EPOCH="$(date -u +%s)"
END_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Slice the wrk stats block out of the combined log for convenience.
awk '/Running .* test @/{p=1} p{print} /Transfer\/sec/{p=0}' \
	"${DIR}/run.log" > "${DIR}/wrk.txt"

ISTIO_ON=false
kubectl get ns istio-system >/dev/null 2>&1 && ISTIO_ON=true

cat > "${DIR}/meta.json" <<JSON
{
  "benchmark": "${bench}",
  "request": "${request}",
  "threads": ${thread},
  "connections": ${conn},
  "duration_s": ${duration},
  "run_id": "${RUN_ID}",
  "start_epoch": ${START_EPOCH},
  "end_epoch": ${END_EPOCH},
  "start_iso": "${START_ISO}",
  "end_iso": "${END_ISO}",
  "istio_enabled": ${ISTIO_ON},
  "run_status": ${STATUS}
}
JSON

# Istio metrics + access logs (self-skips if Istio is absent).
python3 "${SCRIPT_DIR}/collect_metrics.py" \
	--dir "${DIR}" --start "${START_EPOCH}" --end "${END_EPOCH}" \
	--start-iso "${START_ISO}" || echo "[run_and_collect] WARN: metric collection failed"

echo "[run_and_collect] run dir: ${DIR}"
# Last line is the absolute run dir, so the caller can locate it to copy back.
echo "${DIR}"
exit "${STATUS}"
