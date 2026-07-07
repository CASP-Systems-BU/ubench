#!/bin/bash
#
# Run a benign benchmark load AND a Stratus Red Team attack at the same time,
# capturing the full metric/provenance bundle plus a ground-truth attack label.
#
# This is the attack-aware sibling of run_and_collect.sh. It runs ON the control
# node and produces the SAME run directory layout (resources.csv, istio/,
# cilium/, meta.json) so the existing tooling keeps working, and adds:
#
#   * audit/   — the kube-apiserver audit log sliced to the window (the
#                control-plane provenance trace; enable_audit.sh must have run)
#   * attack/  — per-technique detonation records with precise timestamps, plus
#                the attacker namespaces/pods/IPs, i.e. the ground truth needed to
#                label every flow / request / audit event as benign or malicious.
#
# Timeline (mixed run, AssureMOSS "hour 2" style):
#   start capture -> launch benign wrk load -> when wrk actually starts, wait
#   ATTACK_DELAY, then detonate the Stratus technique(s) mid-load -> wrk finishes
#   -> stop capture -> slice everything to the window -> clean up the attack.
#
#   Usage (positional args mirror run_and_collect.sh):
#     attack_and_collect.sh <bench> <request> <threads> <conns> <duration>
#
#   Env:
#     TECHNIQUES    space-separated Stratus k8s technique IDs to detonate
#                   (default: k8s.privilege-escalation.privileged-pod)
#     ATTACK_DELAY  seconds to wait after wrk starts before detonating (default 25)
#     STRATUS       stratus binary (default: ~/.local/bin/stratus)
#     AUDIT_GLOB    audit log glob to slice (default /var/log/kubernetes/audit/*.log)
#     RESULTS_ROOT  where run dirs live (default ~/ubench/results)
#     RUN_ID        run-dir suffix (default UTC ts; set by attack.sh)
#     KEEP_ATTACK   1 = skip stratus cleanup at the end (leave residue; default 0)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bench="${1:-boutique}"
request="${2:-mix}"
thread="${3:-4}"
conn="${4:-16}"
duration="${5:-90}"

TECHNIQUES="${TECHNIQUES:-k8s.privilege-escalation.privileged-pod}"
ATTACK_DELAY="${ATTACK_DELAY:-25}"
STRATUS="${STRATUS:-$HOME/.local/bin/stratus}"
AUDIT_GLOB="${AUDIT_GLOB:-/var/log/kubernetes/audit/*.log}"
RESULTS_ROOT="${RESULTS_ROOT:-$HOME/ubench/results}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
KEEP_ATTACK="${KEEP_ATTACK:-0}"

DIR="${RESULTS_ROOT}/attack-${bench}-${request}_${RUN_ID}"
mkdir -p "${DIR}/istio/access_logs" "${DIR}/cilium" "${DIR}/audit" "${DIR}/attack"

# MITRE ATT&CK tactic per technique (for the label metadata). Keep in sync with
# `stratus list --platform kubernetes`.
mitre_for() {
	case "$1" in
		k8s.credential-access.dump-secrets)               echo "Credential Access" ;;
		k8s.credential-access.steal-serviceaccount-token) echo "Credential Access" ;;
		k8s.persistence.create-admin-clusterrole)         echo "Persistence, Privilege Escalation" ;;
		k8s.persistence.create-client-certificate)        echo "Persistence" ;;
		k8s.persistence.create-token)                     echo "Persistence" ;;
		k8s.privilege-escalation.hostpath-volume)         echo "Privilege Escalation" ;;
		k8s.privilege-escalation.nodes-proxy)             echo "Privilege Escalation" ;;
		k8s.privilege-escalation.privileged-pod)          echo "Privilege Escalation" ;;
		*)                                                echo "Unknown" ;;
	esac
}

START_EPOCH="$(date -u +%s)"
START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- background resource sampler (per-pod CPU/mem every 5s) -----------------
{
	echo "epoch,pod,cpu,mem"
	while true; do
		ts="$(date -u +%s)"
		kubectl top pods -A --no-headers 2>/dev/null \
			| awk -v t="${ts}" '{print t","$1"/"$2","$3","$4}'
		sleep 5
	done
} > "${DIR}/resources.csv" &
SAMPLER=$!

# --- Cilium/Hubble live flow capture (network provenance) -------------------
HUBBLE_PF_PID=""
HUBBLE_OBS_PID=""
if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
	cilium hubble port-forward >/dev/null 2>&1 &
	HUBBLE_PF_PID=$!
	for _ in $(seq 1 10); do
		if hubble status --server localhost:4245 >/dev/null 2>&1; then break; fi
		sleep 1
	done
	hubble observe -f -o jsonpb --server localhost:4245 \
		> "${DIR}/cilium/flows.jsonl" 2>"${DIR}/cilium/_capture.err" &
	HUBBLE_OBS_PID=$!
fi

# ---------------------------------------------------------------------------
# Background attacker: wait for wrk to actually start, hold ATTACK_DELAY so the
# detonation lands in the middle of the load, then detonate each technique while
# recording tight per-technique windows and the entities it creates. Writes:
#   attack/techniques.jsonl  one record per technique (id, mitre, ts window, rc)
#   attack/entities.json     the stratus namespaces/pods/IPs (for flow labeling)
#   attack/detonate_<id>.log raw stratus output
# ---------------------------------------------------------------------------
attacker() {
	# Wait (<=180s) for wrk's load phase to begin (run.sh echoes the wrk cmd /
	# wrk prints "Running <dur>s test @" exactly when load starts).
	for _ in $(seq 1 180); do
		if grep -qE 'Running [0-9].*test @|/wrk/wrk --timeout' "${DIR}/run.log" 2>/dev/null; then
			break
		fi
		sleep 1
	done
	echo "[attacker] wrk load detected; holding ${ATTACK_DELAY}s before detonation"
	sleep "${ATTACK_DELAY}"

	: > "${DIR}/attack/techniques.jsonl"
	for tech in ${TECHNIQUES}; do
		echo "[attacker] === detonating ${tech} ==="
		ts_start="$(date -u +%s)"; ts_start_iso="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
		"${STRATUS}" detonate "${tech}" > "${DIR}/attack/detonate_${tech}.log" 2>&1
		rc=$?
		ts_end="$(date -u +%s)"; ts_end_iso="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
		mitre="$(mitre_for "${tech}")"
		printf '{"id":"%s","mitre":"%s","ts_start_epoch":%s,"ts_end_epoch":%s,"ts_start_iso":"%s","ts_end_iso":"%s","detonate_rc":%s}\n' \
			"${tech}" "${mitre}" "${ts_start}" "${ts_end}" "${ts_start_iso}" "${ts_end_iso}" "${rc}" \
			>> "${DIR}/attack/techniques.jsonl"
		echo "[attacker] ${tech} done rc=${rc} (${ts_start}..${ts_end})"
	done

	# Wait (<=30s) for the detonated pods to get IPs — pod-creating techniques
	# return before the pod is scheduled/networked, and the pod IP is how its
	# flows get labeled. Best-effort: a technique with no pods just falls through.
	for _ in $(seq 1 15); do
		pending="$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.status.podIP}{"\n"}{end}' 2>/dev/null \
			| grep '^stratus-red-team' | grep -c '|$' || true)"
		[ "${pending:-0}" -eq 0 ] && break
		sleep 2
	done

	# Snapshot the attacker entities (namespaces + pods + pod IPs) while the
	# detonated resources still exist — these IPs are how flows get labeled.
	kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
		| grep '^stratus-red-team' > "${DIR}/attack/_ns.txt" || true
	kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.podIP}{"|"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
		| grep '^stratus-red-team' > "${DIR}/attack/_pods.txt" || true
	python3 - "${DIR}/attack" <<'PY'
import json, os, sys
d = sys.argv[1]
ns = [l.strip() for l in open(os.path.join(d, "_ns.txt")) if l.strip()] \
    if os.path.exists(os.path.join(d, "_ns.txt")) else []
pods = []
pf = os.path.join(d, "_pods.txt")
if os.path.exists(pf):
    for l in open(pf):
        p = l.strip().split("|")
        if len(p) == 4:
            pods.append({"namespace": p[0], "name": p[1], "ip": p[2], "node": p[3]})
json.dump({"namespaces": ns, "pods": pods},
          open(os.path.join(d, "entities.json"), "w"), indent=2)
PY
	echo "[attacker] entities: $(wc -l < "${DIR}/attack/_ns.txt" 2>/dev/null || echo 0) ns, $(wc -l < "${DIR}/attack/_pods.txt" 2>/dev/null || echo 0) pods"
}

# --- launch benign load (background) + attacker (background) ----------------
echo "[attack_and_collect] launching benign load: ${bench} ${request} t=${thread} c=${conn} d=${duration}s"
bash "${SCRIPT_DIR}/run.sh" "${bench}" "${request}" "${thread}" "${conn}" "${duration}" \
	> "${DIR}/run.log" 2>&1 &
RUNPID=$!

attacker > "${DIR}/attack/attacker.log" 2>&1 &
ATKPID=$!
# Mirror the benign load to the operator's terminal so the run isn't silent.
tail -f "${DIR}/run.log" "${DIR}/attack/attacker.log" 2>/dev/null &
TAILPID=$!

wait "${RUNPID}"; STATUS=$?
WRK_END_EPOCH="$(date -u +%s)"
wait "${ATKPID}" 2>/dev/null
kill "${TAILPID}" 2>/dev/null

kill "${SAMPLER}" 2>/dev/null; wait "${SAMPLER}" 2>/dev/null
[ -n "${HUBBLE_OBS_PID}" ] && { kill "${HUBBLE_OBS_PID}" 2>/dev/null; wait "${HUBBLE_OBS_PID}" 2>/dev/null; }
[ -n "${HUBBLE_PF_PID}" ]  && { kill "${HUBBLE_PF_PID}"  2>/dev/null; wait "${HUBBLE_PF_PID}"  2>/dev/null; }

END_EPOCH="$(date -u +%s)"
END_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- compute the metric window ---------------------------------------------
# Start from the wrk load phase (as run_and_collect.sh does), then UNION it with
# the attack window so the detonation is always fully inside the window even if it
# slightly overruns the load.
awk '/Running .* test @/{p=1} p{print} /Transfer\/sec/{p=0}' \
	"${DIR}/run.log" > "${DIR}/wrk.txt"
WRK_SECONDS="$(sed -n 's/.*requests in \([0-9.]*\)s.*/\1/p' "${DIR}/wrk.txt" | head -1)"
if [ -z "${WRK_SECONDS}" ]; then WRK_WINDOW="${duration}"; else
	WRK_WINDOW="$(awk -v s="${WRK_SECONDS}" 'BEGIN{print int(s)+(s>int(s)?1:0)}')"
fi
WRK_START_EPOCH=$(( WRK_END_EPOCH - WRK_WINDOW ))

# Fold in the attack span (min start / max end) from techniques.jsonl.
read -r ATK_START ATK_END <<EOF
$(python3 - "${DIR}/attack/techniques.jsonl" <<'PY'
import json, sys
s, e = [], []
try:
    for l in open(sys.argv[1]):
        l = l.strip()
        if not l: continue
        r = json.loads(l); s.append(r["ts_start_epoch"]); e.append(r["ts_end_epoch"])
except FileNotFoundError:
    pass
print((min(s) if s else ""), (max(e) if e else ""))
PY
)
EOF
WIN_START="${WRK_START_EPOCH}"; WIN_END="${WRK_END_EPOCH}"
[ -n "${ATK_START}" ] && [ "${ATK_START}" -lt "${WIN_START}" ] && WIN_START="${ATK_START}"
[ -n "${ATK_END}" ]   && [ "${ATK_END}"   -gt "${WIN_END}" ]   && WIN_END="${ATK_END}"
WIN_START_ISO="$(date -u -d "@${WIN_START}" +%Y-%m-%dT%H:%M:%SZ)"
WIN_END_ISO="$(date -u -d "@${WIN_END}" +%Y-%m-%dT%H:%M:%SZ)"

ISTIO_ON=false;  kubectl get ns istio-system >/dev/null 2>&1 && ISTIO_ON=true
CILIUM_ON=false; kubectl -n kube-system get ds cilium >/dev/null 2>&1 && CILIUM_ON=true
AUDIT_ON=false;  sudo sh -c "ls ${AUDIT_GLOB}" >/dev/null 2>&1 && AUDIT_ON=true

# --- assemble attack/attack.json (the label ground truth) ------------------
# The attacker identity = the kubeconfig user Stratus authenticates as (the label
# gate that separates the attack's API calls from benign control-plane activity).
ATTACKER_USER="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.user}' 2>/dev/null)"
ATTACKER_USER="${ATTACKER_USER:-kubernetes-admin}"
python3 - "${DIR}/attack" "${WIN_START}" "${WIN_END}" "${ATK_START:-}" "${ATK_END:-}" "${ATTACKER_USER}" <<'PY'
import json, os, sys
d, win_s, win_e, atk_s, atk_e, attacker_user = (
    sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6])
techs = []
tf = os.path.join(d, "techniques.jsonl")
if os.path.exists(tf):
    techs = [json.loads(l) for l in open(tf) if l.strip()]
ent = {}
ef = os.path.join(d, "entities.json")
if os.path.exists(ef):
    ent = json.load(open(ef))
out = {
    "is_attack": True,
    "techniques": techs,
    "attacker_user": attacker_user,
    "attack_start_epoch": int(atk_s) if atk_s else None,
    "attack_end_epoch": int(atk_e) if atk_e else None,
    "namespace_prefix": "stratus-red-team",
    "namespaces": ent.get("namespaces", []),
    "pods": ent.get("pods", []),
    "attacker_ips": sorted({p["ip"] for p in ent.get("pods", []) if p.get("ip")}),
}
json.dump(out, open(os.path.join(d, "attack.json"), "w"), indent=2)
print("[attack_and_collect] wrote attack.json:", len(techs), "techniques,",
      len(out["pods"]), "attacker pods,", len(out["attacker_ips"]), "attacker IPs")
PY

# --- meta.json (adds attack fields on top of the run_and_collect schema) ---
TECH_JSON="$(printf '%s' "${TECHNIQUES}" | awk '{for(i=1;i<=NF;i++)printf "%s\"%s\"",(i>1?",":""),$i}')"
cat > "${DIR}/meta.json" <<JSON
{
  "benchmark": "${bench}",
  "request": "${request}",
  "threads": ${thread},
  "connections": ${conn},
  "duration_s": ${duration},
  "run_id": "${RUN_ID}",
  "is_attack": true,
  "attack_techniques": [${TECH_JSON}],
  "attack_delay_s": ${ATTACK_DELAY},
  "start_epoch": ${WIN_START},
  "end_epoch": ${WIN_END},
  "start_iso": "${WIN_START_ISO}",
  "end_iso": "${WIN_END_ISO}",
  "wrk_start_epoch": ${WRK_START_EPOCH},
  "wrk_end_epoch": ${WRK_END_EPOCH},
  "attack_start_epoch": ${ATK_START:-null},
  "attack_end_epoch": ${ATK_END:-null},
  "capture_start_epoch": ${START_EPOCH},
  "capture_end_epoch": ${END_EPOCH},
  "capture_start_iso": "${START_ISO}",
  "capture_end_iso": "${END_ISO}",
  "istio_enabled": ${ISTIO_ON},
  "cilium_enabled": ${CILIUM_ON},
  "audit_enabled": ${AUDIT_ON},
  "run_status": ${STATUS}
}
JSON

# --- collect Istio + Cilium + audit, all sliced to the window --------------
python3 "${SCRIPT_DIR}/collect_metrics.py" \
	--dir "${DIR}" --start "${WIN_START}" --end "${WIN_END}" \
	--start-iso "${WIN_START_ISO}" --audit-log "${AUDIT_GLOB}" \
	|| echo "[attack_and_collect] WARN: metric collection failed"

# --- label flows / access logs / audit as benign|malicious -----------------
if [ -f "${SCRIPT_DIR}/label_attack.py" ]; then
	python3 "${SCRIPT_DIR}/label_attack.py" --dir "${DIR}" \
		|| echo "[attack_and_collect] WARN: labeling failed"
fi

# --- tear down the attack (after capture, so its flows were recorded) -------
if [ "${KEEP_ATTACK}" != "1" ]; then
	for tech in ${TECHNIQUES}; do
		echo "[attack_and_collect] cleaning up ${tech}"
		"${STRATUS}" revert  "${tech}" >/dev/null 2>&1 || true
		"${STRATUS}" cleanup "${tech}" >/dev/null 2>&1 || true
	done
fi

echo "[attack_and_collect] run dir: ${DIR}"
echo "${DIR}"
exit "${STATUS}"
