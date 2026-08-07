#!/bin/bash
#
# Drive one continuous wrk2 experiment and harvest its telemetry into
# time-segment run directories.
#
# Runs ON the control node. run.sh does the setup (client pod, readiness,
# populate) and starts the load detached inside the client pod; this script
# then loops over segments — each segment gets a normal, self-contained run
# directory identical in layout to a single short run:
#
#   * k8s object/node snapshot at segment start
#   * resources.csv + cilium/flows.jsonl sliced from experiment-wide streams
#   * collect_metrics.py for the segment window (Istio time-series, call graph,
#     Envoy access logs, audit slice — all already window-filtered)
#   * meta.json (params + window + segment index + rate offered/achieved)
#
# Segments exist because the log sources rotate with hard caps (kubelet
# ~10Mi x 5 per container, apiserver 4 x 100M audit backups): harvesting every
# segment collects each slice while it still exists, a failure costs one
# segment instead of the experiment, and the run dirs are contiguous time
# slices of one uninterrupted load.
#
#   run_and_collect.sh <bench> <request> <threads> <conns> <total_s> [rate] [segment_s]
#
# Env:
#   RESULTS_ROOT  where run dirs live on the control node (default ~/ubench/results)
#   RUN_ID        experiment id (default: UTC timestamp); names the manifest file
#                 ${RESULTS_ROOT}/manifest_${RUN_ID}.txt that lists every segment
#                 dir for the caller (deploy.sh) to copy back
#   RATE          rate fallback when $6 is not given
#   EXPERIMENT    experiment/spec name for meta.json (optional)
#   WORKERS       worker count for meta.json (optional)
#   CLIENT_IMAGE  forwarded to run.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bench="${1:-boutique}"
request="${2:-mix}"
thread="${3:-4}"
conn="${4:-16}"
total_s="${5:-60}"
rate="${6:-${RATE:-1000}}"
segment_s="${7:-${total_s}}"

# Validate the numeric knobs BEFORE anything can write a meta.json: these are
# interpolated as bare JSON numbers, so a typo'd THREADS=all would otherwise
# produce unparseable meta.json files that break downstream ingest of the
# whole results tree.
for v in thread conn total_s rate segment_s; do
	if ! [[ "${!v}" =~ ^[0-9]+$ ]] || [[ "${!v}" -eq 0 ]]; then
		echo "[run_and_collect] ${v} must be a positive integer, got '${!v}'" >&2
		exit 2
	fi
done

RESULTS_ROOT="${RESULTS_ROOT:-$HOME/ubench/results}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
EXPERIMENT="${EXPERIMENT:-}"
WORKERS="${WORKERS:-}"

MANIFEST="${RESULTS_ROOT}/manifest_${RUN_ID}.txt"
EXP_DIR="${RESULTS_ROOT}/.exp_${RUN_ID}"     # experiment-wide scratch (streams)
mkdir -p "${EXP_DIR}" "${RESULTS_ROOT}"
: > "${MANIFEST}"

if [[ "${segment_s}" -gt "${total_s}" ]]; then segment_s="${total_s}"; fi
NSEG=$(( (total_s + segment_s - 1) / segment_s ))

ISTIO_ON=false
kubectl get ns istio-system >/dev/null 2>&1 && ISTIO_ON=true
CILIUM_ON=false
kubectl -n kube-system get ds cilium >/dev/null 2>&1 && CILIUM_ON=true
AUDIT_ON=false
sudo test -s /var/log/kubernetes/audit/audit.log 2>/dev/null && AUDIT_ON=true

# ---- experiment-wide streams ------------------------------------------------
# Background resource sampler: per-pod CPU/mem every 5s, for the whole
# experiment; sliced per segment by the epoch column. metrics-server is the
# only resource source here (the Istio Prometheus does not scrape cAdvisor).
{
	echo "epoch,pod,cpu,mem"
	while true; do
		ts="$(date -u +%s)"
		kubectl top pods --no-headers 2>/dev/null \
			| awk -v t="${ts}" '{print t","$1","$2","$3}'
		sleep 5
	done
} > "${EXP_DIR}/resources.csv" &
SAMPLER=$!

# Cilium/Hubble flow capture (only if Cilium is the CNI). Hubble's relay keeps
# just a small in-memory ring buffer, so a high-traffic run would overflow it —
# we must STREAM flows live for the whole experiment, then slice per segment
# by each flow's own timestamp.
HUBBLE_PF_PID=""
HUBBLE_OBS_PID=""
if [[ "${CILIUM_ON}" == true ]]; then
	cilium hubble port-forward >/dev/null 2>&1 &
	HUBBLE_PF_PID=$!
	for _ in $(seq 1 10); do
		if hubble status --server localhost:4245 >/dev/null 2>&1; then break; fi
		sleep 1
	done
	# jsonpb is Hubble's newline-delimited JSON (one {"flow":{...}} per line).
	hubble observe -f -o jsonpb --server localhost:4245 \
		> "${EXP_DIR}/flows.jsonl" 2>"${EXP_DIR}/_capture.err" &
	HUBBLE_OBS_PID=$!
fi

cleanup_streams() {
	kill "${SAMPLER}" 2>/dev/null; wait "${SAMPLER}" 2>/dev/null
	[ -n "${HUBBLE_OBS_PID}" ] && { kill "${HUBBLE_OBS_PID}" 2>/dev/null; wait "${HUBBLE_OBS_PID}" 2>/dev/null; }
	[ -n "${HUBBLE_PF_PID}" ]  && { kill "${HUBBLE_PF_PID}"  2>/dev/null; wait "${HUBBLE_PF_PID}"  2>/dev/null; }
}

client_pod() { kubectl get pod 2>/dev/null | grep ubuntu-client- | cut -f 1 -d " "; }

# Tri-state load probe. A kubectl exec that fails to REACH the pod (apiserver
# hiccup, network blip) is indistinguishable from "file absent" if probed
# naively — and mistaking a transient blip for a dead generator would abort a
# healthy multi-hour experiment. So the remote answers explicitly, and an empty
# answer means UNKNOWN, which callers never treat as dead.
#   echoes: "done <rc>" | "running" | "absent" | "unknown"
wrk_state() {
	# Process liveness via /proc, not pgrep (procps isn't in every client
	# image). The [/] bracket keeps the probe from matching its own cmdline.
	local pod out
	pod="$(client_pod)"
	[ -z "${pod}" ] && { echo "unknown"; return; }
	out="$(kubectl exec "${pod}" -- sh -c \
		'if [ -f /tmp/wrk.rc ]; then echo "done $(cat /tmp/wrk.rc)"; elif grep -aq "[/]wrk2/wrk" /proc/[0-9]*/cmdline 2>/dev/null; then echo running; else echo absent; fi' \
		2>/dev/null)"
	[ -z "${out}" ] && echo "unknown" || echo "${out}"
}
# Only this many CONSECUTIVE definitive "absent" answers declare the load dead
# (~40s at the poll cadence). "unknown" resets nothing and confirms nothing.
ABSENT_LIMIT=4

# Slice EXP flows.jsonl into [start_epoch, end_epoch) by each flow's own time.
slice_flows() {
	local out="$1" start="$2" end="$3"
	if [[ "${CILIUM_ON}" != true ]]; then return 0; fi
	python3 - "${EXP_DIR}/flows.jsonl" "${out}" "${start}" "${end}" <<'PYEOF'
import calendar, json, sys, time
src, out, start, end = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
kept = 0
with open(src, errors="replace") as fin, open(out, "w") as fout:
    for line in fin:
        try:
            t = json.loads(line).get("flow", {}).get("time", "")
            # "2026-08-12T01:00:00.123456789Z" -> epoch at second precision
            epoch = calendar.timegm(time.strptime(t[:19], "%Y-%m-%dT%H:%M:%S"))
        except Exception:
            continue  # partial last line of the live stream / non-flow record
        if start <= epoch < end:
            fout.write(line)
            kept += 1
print(f"[run_and_collect] flows: kept {kept} in window", file=sys.stderr)
PYEOF
}

write_meta() {
	local dir="$1" seg_idx="$2" seg_start="$3" seg_end="$4" \
	      seg_start_iso="$5" seg_end_iso="$6" seg_id="$7" status="$8"
	local exp_json="null" workers_json="null"
	[ -n "${EXPERIMENT}" ] && exp_json="\"${EXPERIMENT}\""
	[ -n "${WORKERS}" ] && workers_json="${WORKERS}"
	cat > "${dir}/meta.json" <<JSON
{
  "benchmark": "${bench}",
  "request": "${request}",
  "threads": ${thread},
  "connections": ${conn},
  "duration_s": $(( seg_end - seg_start )),
  "run_id": "${seg_id}",
  "start_epoch": ${seg_start},
  "end_epoch": ${seg_end},
  "start_iso": "${seg_start_iso}",
  "end_iso": "${seg_end_iso}",
  "istio_enabled": ${ISTIO_ON},
  "cilium_enabled": ${CILIUM_ON},
  "audit_enabled": ${AUDIT_ON},
  "run_status": ${status},
  "generator": "wrk2",
  "rate_rps": ${rate},
  "achieved_rps": null,
  "experiment": ${exp_json},
  "workers": ${workers_json},
  "segment_index": ${seg_idx},
  "segments_total": ${NSEG},
  "total_duration_s": ${total_s}
}
JSON
}

# ---- setup + start the continuous load --------------------------------------
echo "[run_and_collect] ${bench}/${request}: ${total_s}s at ${rate} req/s, ${NSEG} segment(s) of <=${segment_s}s"
LOAD_MODE=detach RATE="${rate}" bash "${SCRIPT_DIR}/run.sh" \
	"${bench}" "${request}" "${thread}" "${conn}" "${total_s}" "${rate}" \
	2>&1 | tee "${EXP_DIR}/setup.log"
SETUP_STATUS="${PIPESTATUS[0]}"

if [[ "${SETUP_STATUS}" -ne 0 ]]; then
	# Preserve the evidence as a single failed run dir the caller still copies.
	SEG_ID="${RUN_ID}"
	DIR="${RESULTS_ROOT}/${bench}-${request}_${SEG_ID}"
	mkdir -p "${DIR}"
	cp "${EXP_DIR}/setup.log" "${DIR}/run.log"
	NOW="$(date -u +%s)"; NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	write_meta "${DIR}" 1 "${NOW}" "${NOW}" "${NOW_ISO}" "${NOW_ISO}" \
		"${SEG_ID}" "${SETUP_STATUS}"
	echo "${DIR}" >> "${MANIFEST}"
	cleanup_streams
	rm -rf "${EXP_DIR}"
	echo "[run_and_collect] setup failed (rc=${SETUP_STATUS}); evidence in ${DIR}"
	exit "${SETUP_STATUS}"
fi

# ---- segment loop ------------------------------------------------------------
# Segment windows TILE: each segment's start is the previous segment's end, so
# the time spent slicing/collecting between boundaries still belongs to a
# window — no flow or sample ever falls between segments.
OVERALL=0
LOAD_STATE="running"   # running | done | dead
WRK_RC=""
LOAD_START="$(date -u +%s)"
NEXT_START="${LOAD_START}"
for (( seg=1; seg<=NSEG; seg++ )); do
	SEG_START="${NEXT_START}"
	SEG_START_ISO="$(date -u -d "@${SEG_START}" +%Y-%m-%dT%H:%M:%SZ)"
	SEG_ID="$(date -u -d "@${SEG_START}" +%Y%m%d-%H%M%S)"
	DIR="${RESULTS_ROOT}/${bench}-${request}_${SEG_ID}"
	mkdir -p "${DIR}/istio/access_logs" "${DIR}/cilium" "${DIR}/k8s_snapshot"
	SEG_STATUS=0

	# K8s entity snapshot at segment start — the GNN pipeline's entity table.
	kubectl get pods,services,endpoints,deployments,replicasets,statefulsets,daemonsets \
		-A -o json > "${DIR}/k8s_snapshot/objects.json" 2>/dev/null \
		|| echo "[run_and_collect] WARN: k8s object snapshot failed"
	kubectl get nodes -o json > "${DIR}/k8s_snapshot/nodes.json" 2>/dev/null \
		|| echo "[run_and_collect] WARN: k8s node snapshot failed"

	# Sit out the segment; wake early if the load finishes (or is truly gone —
	# never on a single failed probe, see wrk_state).
	SEG_TARGET=$(( SEG_START + segment_s ))
	ABSENT=0
	while [[ "$(date -u +%s)" -lt "${SEG_TARGET}" ]]; do
		remaining=$(( SEG_TARGET - $(date -u +%s) ))
		sleep $(( remaining < 10 ? (remaining > 0 ? remaining : 1) : 10 ))
		state="$(wrk_state)"
		case "${state}" in
			done*)
				LOAD_STATE="done"; WRK_RC="${state#done }"; break ;;
			absent)
				ABSENT=$(( ABSENT + 1 ))
				if [[ "${ABSENT}" -ge "${ABSENT_LIMIT}" ]]; then
					echo "[run_and_collect] WARN: wrk2 is gone without an exit code (${ABSENT} consecutive probes); failing segment ${seg}"
					SEG_STATUS=1; LOAD_STATE="dead"; break
				fi ;;
			*)  # running, or unknown (transient kubectl/apiserver failure)
				ABSENT=0 ;;
		esac
	done

	SEG_END="$(date -u +%s)"
	SEG_END_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	NEXT_START="${SEG_END}"
	sleep 3   # let the streams flush past SEG_END before slicing up to it

	slice_flows "${DIR}/cilium/flows.jsonl" "${SEG_START}" "${SEG_END}" \
		|| echo "[run_and_collect] WARN: flow slicing failed for segment ${seg}"
	awk -F, -v s="${SEG_START}" -v e="${SEG_END}" \
		'NR==1 || ($1+0 >= s && $1+0 < e)' \
		"${EXP_DIR}/resources.csv" > "${DIR}/resources.csv"
	[[ "${CILIUM_ON}" == true && -s "${EXP_DIR}/_capture.err" ]] \
		&& cp "${EXP_DIR}/_capture.err" "${DIR}/cilium/_capture.err"

	# Istio metrics + access logs + audit slice for this window (all
	# window-filtered inside collect_metrics.py; self-skips absent sources).
	python3 "${SCRIPT_DIR}/collect_metrics.py" \
		--dir "${DIR}" --start "${SEG_START}" --end "${SEG_END}" \
		--start-iso "${SEG_START_ISO}" \
		|| { echo "[run_and_collect] WARN: metric collection failed for segment ${seg}"; SEG_STATUS=1; }

	# Resolved-spec provenance, if deploy.sh shipped one with the manifests.
	[ -f "${HOME}/ubench/k8s/${bench}/resolved.json" ] \
		&& cp "${HOME}/ubench/k8s/${bench}/resolved.json" "${DIR}/experiment.json"

	write_meta "${DIR}" "${seg}" "${SEG_START}" "${SEG_END}" \
		"${SEG_START_ISO}" "${SEG_END_ISO}" "${SEG_ID}" "${SEG_STATUS}"
	echo "${DIR}" >> "${MANIFEST}"
	[[ "${SEG_STATUS}" -ne 0 ]] && OVERALL=1
	echo "[run_and_collect] segment ${seg}/${NSEG} -> ${DIR} (status ${SEG_STATUS})"

	if [[ "${LOAD_STATE}" != "running" ]]; then break; fi
done

cleanup_streams

# ---- finalize: wrk2 exit code, stats, back-fill ------------------------------
# The grace deadline is anchored to the LOAD's own timeline (start + total +
# slack), not "now": if a transient probe failure broke the segment loop early,
# a healthy wrk2 may legitimately still have hours to run — killing it would
# destroy the experiment over a blip. (Its remaining segments are still lost —
# the loop has ended — but the collected ones stay valid and the process is
# given the chance to finish and report honest whole-run stats.)
DEADLINE=$(( LOAD_START + total_s + 120 ))
ABSENT=0
while [[ -z "${WRK_RC}" && "${LOAD_STATE}" != "dead" ]]; do
	state="$(wrk_state)"
	case "${state}" in
		done*)  WRK_RC="${state#done }"; break ;;
		absent)
			ABSENT=$(( ABSENT + 1 ))
			[[ "${ABSENT}" -ge "${ABSENT_LIMIT}" ]] && { LOAD_STATE="dead"; break; } ;;
		*)      ABSENT=0 ;;
	esac
	if [[ "$(date -u +%s)" -gt "${DEADLINE}" ]]; then
		echo "[run_and_collect] WARN: wrk2 still running past its deadline; killing it"
		CLIENT="$(client_pod)"
		[ -n "${CLIENT}" ] && kubectl exec "${CLIENT}" -- sh -c \
			'kill $(grep -la "[/]wrk2/wrk" /proc/[0-9]*/cmdline 2>/dev/null | cut -d/ -f3)' 2>/dev/null
		break
	fi
	sleep 10
done
if [[ -z "${WRK_RC}" ]]; then
	echo "[run_and_collect] WARN: wrk2 never reported an exit code"
	WRK_RC=1
	OVERALL=1
fi

CLIENT="$(client_pod)"
kubectl exec "${CLIENT}" -- cat /tmp/wrk.log > "${EXP_DIR}/wrk.log" 2>/dev/null \
	|| echo "[run_and_collect] WARN: could not retrieve /tmp/wrk.log"

# Per segment: run.log = setup + wrk output; wrk.txt = the sliced stats block;
# back-fill achieved_rps (and the last segment's status if wrk2 died unseen).
cat "${EXP_DIR}/setup.log" "${EXP_DIR}/wrk.log" > "${EXP_DIR}/run.log" 2>/dev/null
awk '/Running .* test @/{p=1} p{print} /Transfer\/sec/{p=0}' \
	"${EXP_DIR}/run.log" > "${EXP_DIR}/wrk.txt"
ACHIEVED="$(awk '/^Requests\/sec:/{print $2; exit}' "${EXP_DIR}/wrk.txt")"

while IFS= read -r dir; do
	[ -d "${dir}" ] || continue
	cp "${EXP_DIR}/run.log" "${dir}/run.log"
	cp "${EXP_DIR}/wrk.txt" "${dir}/wrk.txt"
done < "${MANIFEST}"

python3 - "${MANIFEST}" "${ACHIEVED:-}" "${WRK_RC}" <<'PYEOF'
import json, sys
manifest, achieved, wrk_rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
dirs = [l.strip() for l in open(manifest) if l.strip()]
for i, d in enumerate(dirs):
    try:
        with open(f"{d}/meta.json") as f:
            meta = json.load(f)
        meta["achieved_rps"] = float(achieved) if achieved else None
        # A nonzero wrk2 exit invalidates the segment it died in (the last one).
        if wrk_rc != 0 and i == len(dirs) - 1 and meta.get("run_status") == 0:
            meta["run_status"] = wrk_rc
        with open(f"{d}/meta.json", "w") as f:
            json.dump(meta, f, indent=2)
    except Exception as e:
        print(f"[run_and_collect] WARN: meta back-fill failed for {d}: {e}",
              file=sys.stderr)
PYEOF

[[ "${WRK_RC}" -ne 0 ]] && OVERALL=1
rm -rf "${EXP_DIR}"

echo "[run_and_collect] wrk2 rc=${WRK_RC}, offered ${rate} req/s, achieved ${ACHIEVED:-n/a}"
echo "[run_and_collect] segment dirs (also in ${MANIFEST}):"
cat "${MANIFEST}"
exit "${OVERALL}"
