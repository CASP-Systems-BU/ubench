#!/bin/bash
#
# Deploy a benchmark, drive a wrk2 --run load, and interleave Stratus Red Team
# attack detonations mid-run -- so the collected telemetry (audit.jsonl always;
# cilium/flows.jsonl for techniques that cross the control-plane -> worker-node
# network boundary, e.g. nodes-proxy/exec-based ones) actually has real attack
# activity inside its collection window instead of the attack happening outside
# any --run and leaving no trace (see README "Kubernetes attack simulation" +
# Cilium's live-only capture).
#
# Prereqs: cluster bootstrapped (./bootstrap.sh) AND Stratus installed on node-0
# (./bootstrap.sh stratus). This script only drives deploy.sh + ssh's stratus
# commands to node-0 -- it never touches bootstrap.
#
# Usage:
#   ./attack_run.sh [bench] [technique-id ...]
#
#   ./attack_run.sh                                   # boutique, default 3 techniques
#   ./attack_run.sh boutique k8s.privilege-escalation.nodes-proxy
#   RATE=500 TOTAL_S=300 SEGMENT_S=300 ./attack_run.sh boutique \
#       k8s.credential-access.dump-secrets k8s.persistence.create-token
#
# Env (same load knobs as deploy.sh --run, plus the attack-timing ones):
#   RATE/TOTAL_S/SEGMENT_S/REQUEST/THREADS/CONNS   passed straight to deploy.sh
#   ATTACK_OFFSET_S   wait after load is confirmed running before the first
#                     detonation (default 20s -- lets wrk2 past its warmup)
#   ATTACK_DELAY_S    gap between successive detonations (default 30s -- keeps
#                     each technique's audit/flow footprint in a distinguishable
#                     window instead of overlapping)
#   ATTACK_CLEANUP    1 (default) passes --cleanup to every detonate; 0 leaves
#                     artifacts in place (you then `stratus cleanup <id>` by hand)
#
# Output: besides the normal results/<bench>-<request>_<seg>/ dirs deploy.sh
# already produces, every segment dir whose window overlaps a detonation gets
# an attacks.json listing which technique(s) and exact [start,end] epoch window
# -- the correlation key for grepping audit.jsonl / cilium flows / Istio data.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${SCRIPT_DIR}"

BENCH="${1:-boutique}"
shift || true
TECHNIQUES=("$@")
if [ "${#TECHNIQUES[@]}" -eq 0 ]; then
	TECHNIQUES=(
		k8s.credential-access.dump-secrets
		k8s.persistence.create-token
		k8s.privilege-escalation.privileged-pod
	)
fi

RATE="${RATE:-300}"
TOTAL_S="${TOTAL_S:-180}"
SEGMENT_S="${SEGMENT_S:-${TOTAL_S}}"
ATTACK_OFFSET_S="${ATTACK_OFFSET_S:-20}"
ATTACK_DELAY_S="${ATTACK_DELAY_S:-30}"
ATTACK_CLEANUP="${ATTACK_CLEANUP:-1}"

CFG_USER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodes_user"])' \
	"${SCRIPT_DIR}/config.json" 2>/dev/null || true)"
SSH_USER="${SSH_USER:-${CFG_USER:-WillG}}"
source "${SCRIPT_DIR}/nodes.sh"
MAIN="${NODES[0]}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)

# Fail before touching anything if the run isn't long enough to fit every
# detonation inside it with its own clear window.
MIN_NEEDED=$(( ATTACK_OFFSET_S + ATTACK_DELAY_S * (${#TECHNIQUES[@]} - 1) + 15 ))
if [ "${TOTAL_S}" -lt "${MIN_NEEDED}" ]; then
	echo "[attack_run] TOTAL_S=${TOTAL_S}s too short for ${#TECHNIQUES[@]} techniques spaced ${ATTACK_DELAY_S}s apart (need >= ${MIN_NEEDED}s)" >&2
	exit 1
fi

WORKDIR="$(mktemp -d)"
ATTACK_LOG="${WORKDIR}/attacks.jsonl"
DEPLOY_LOG="${WORKDIR}/deploy.log"
: > "${ATTACK_LOG}"
trap 'rm -rf "${WORKDIR}"' EXIT

log() { printf '\n[attack_run] %s\n' "$*"; }

# Bounded, low-frequency probe of whether wrk2 is actually running in the
# client pod -- mirrors run_and_collect.sh's own liveness check so we don't
# invent a second source of truth for "is the load up".
check_wrk_running() {
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" bash -s <<'EOF' 2>/dev/null
pod=$(kubectl get pod 2>/dev/null | grep ubuntu-client- | cut -f1 -d" ")
[ -z "$pod" ] && { echo absent; exit 0; }
if kubectl exec "$pod" -- sh -c 'grep -aq "[/]wrk2/wrk" /proc/[0-9]*/cmdline 2>/dev/null'; then
	echo running
else
	echo absent
fi
EOF
}

# ---- 1. kick off deploy.sh --run in the background --------------------------
log "Starting '${BENCH}' --run (rate=${RATE}rps total=${TOTAL_S}s segment=${SEGMENT_S}s) in the background"
( RATE="${RATE}" TOTAL_S="${TOTAL_S}" SEGMENT_S="${SEGMENT_S}" \
  ./deploy.sh "${BENCH}" --run > "${DEPLOY_LOG}" 2>&1 ) &
DEPLOY_PID=$!

# ---- 2. wait for wrk2 to actually be running on the client pod --------------
# Bounded poll (not unbounded): fails loudly instead of hanging forever if the
# load never starts (deploy failure, stuck rollout, etc).
log "Waiting for wrk2 to start on the client pod (bounded poll, <=240s)..."
WRK_DEADLINE=$(( $(date -u +%s) + 240 ))
LOAD_UP=0
while [ "$(date -u +%s)" -lt "${WRK_DEADLINE}" ]; do
	if ! kill -0 "${DEPLOY_PID}" 2>/dev/null; then
		log "deploy.sh exited before the load started -- see ${DEPLOY_LOG}:"
		cat "${DEPLOY_LOG}"
		exit 1
	fi
	if [ "$(check_wrk_running || echo unknown)" = "running" ]; then
		LOAD_UP=1
		break
	fi
	sleep 10
done
if [ "${LOAD_UP}" -ne 1 ]; then
	log "wrk2 never started within 240s -- aborting attacks, see ${DEPLOY_LOG}:"
	cat "${DEPLOY_LOG}"
	exit 1
fi
LOAD_START_EPOCH="$(date -u +%s)"
log "Load confirmed running at $(date -u -d "@${LOAD_START_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"

# ---- 3. detonate each technique at its offset --------------------------------
sleep "${ATTACK_OFFSET_S}"
for i in "${!TECHNIQUES[@]}"; do
	TECH="${TECHNIQUES[$i]}"
	CLEANUP_FLAG=""
	[ "${ATTACK_CLEANUP}" = "1" ] && CLEANUP_FLAG="--cleanup"

	T_START="$(date -u +%s)"
	log "Detonating ${TECH} ($(( i + 1 ))/${#TECHNIQUES[@]})"
	set +e
	OUT="$(ssh -A "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" bash -s "${TECH}" "${CLEANUP_FLAG}" <<'EOF' 2>&1
TECH="$1"; CLEANUP="$2"
stratus detonate "${TECH}" ${CLEANUP}
EOF
	)"
	RC=$?
	set -e
	T_END="$(date -u +%s)"
	echo "${OUT}" | sed 's/^/    /'

	python3 - "${ATTACK_LOG}" "${TECH}" "${T_START}" "${T_END}" "${RC}" "${ATTACK_CLEANUP}" <<'PYEOF'
import datetime, json, sys
log, tech, start, end, rc, cleanup = sys.argv[1:7]
tactic = tech.split(".")[1] if tech.count(".") >= 2 else "unknown"
def iso(e): return datetime.datetime.utcfromtimestamp(int(e)).strftime("%Y-%m-%dT%H:%M:%SZ")
rec = {
    "technique": tech,
    "tactic": tactic,
    "detonate_start_epoch": int(start),
    "detonate_end_epoch": int(end),
    "detonate_start_iso": iso(start),
    "detonate_end_iso": iso(end),
    "exit_code": int(rc),
    "cleanup": cleanup == "1",
}
with open(log, "a") as f:
    f.write(json.dumps(rec) + "\n")
PYEOF

	if [ "$(( i + 1 ))" -lt "${#TECHNIQUES[@]}" ]; then
		sleep "${ATTACK_DELAY_S}"
	fi
done
log "All ${#TECHNIQUES[@]} techniques detonated."

# ---- 4. wait for deploy.sh --run to finish collecting ------------------------
log "Waiting for deploy.sh --run to finish (load + collection)..."
set +e
wait "${DEPLOY_PID}"
DEPLOY_RC=$?
set -e
cat "${DEPLOY_LOG}"
[ "${DEPLOY_RC}" -eq 0 ] || log "deploy.sh exited with rc=${DEPLOY_RC}"

# ---- 5. stamp attacks.json into every segment dir whose window overlaps -----
log "Correlating detonations into results/ segment dirs..."
python3 - "${REPO_ROOT}/results" "${ATTACK_LOG}" "${LOAD_START_EPOCH}" <<'PYEOF'
import glob, json, os, sys

results_dir, attack_log, load_start = sys.argv[1], sys.argv[2], int(sys.argv[3])
attacks = [json.loads(l) for l in open(attack_log) if l.strip()]
if not attacks:
    sys.exit(0)

stamped = 0
for meta_path in glob.glob(os.path.join(results_dir, "*", "meta.json")):
    seg_dir = os.path.dirname(meta_path)
    try:
        meta = json.load(open(meta_path))
    except Exception:
        continue
    if meta.get("start_epoch") is None or meta.get("end_epoch") is None:
        continue
    if meta["start_epoch"] < load_start - 60:
        continue  # a segment dir from an earlier, unrelated run
    overlapping = [a for a in attacks
                   if a["detonate_start_epoch"] < meta["end_epoch"]
                   and a["detonate_end_epoch"] >= meta["start_epoch"]]
    if overlapping:
        with open(os.path.join(seg_dir, "attacks.json"), "w") as f:
            json.dump(overlapping, f, indent=2)
        stamped += 1
        print(f"[attack_run]   {seg_dir}: {len(overlapping)} attack(s)")

print(f"[attack_run] stamped attacks.json into {stamped} segment dir(s)")
PYEOF

log "Done. Raw attack log: ${ATTACK_LOG} (deleted on exit -- copy it out first if you want it)"
exit "${DEPLOY_RC}"
