#!/bin/bash
#
# Run an LLM-driven (hackingBuddyGPT) post-compromise red-team assessment against
# the CloudLab cluster while a benign wrk2 load is captured, then write the attack
# ground truth so gnnid can label the telemetry. The attack-aware sibling of
# `deploy.sh --run`.
#
# Flow (from the dev box):
#   1. ensure the benchmark is deployed (deploy.sh) + node labels exist
#   2. deploy the attacker launchpad (k8s/redteam/) and read its pod name / IP
#   3. start a benign capture in the background (deploy.sh --run)
#   4. after a warmup, run the hackingBuddyGPT agent from the foothold pod for the
#      attack window (its transcript -> redteam/logs/log-*.jsonl)
#   5. wait for the capture to finish and copy back the run dirs
#   6. write attack/attack.json (attacker ns/IP/SA + session window) into every
#      returned run dir that overlaps the attack -> ready for `gnnid ingest --labels`
#   7. tear the attacker down (unless --keep)
#
#   Usage:
#     ./redteam.sh                      # boutique, recon RBAC profile
#     ./redteam.sh boutique --keep      # leave the attacker deployed afterwards
#     ./redteam.sh boutique --no-deploy # skip (re)deploying the benchmark
#
#   Env:
#     RBAC_PROFILE=recon|secrets|exec|breakout|token|rbac|escalated
#                                    which attack technique SUCCEEDS (default recon). Each builds
#                                    on the read-only base; exec/token/escalated also plant the
#                                    ci-runner cluster-admin decoy as a pivot target.
#     FOOTHOLD=normal|privileged     normal pod, or a privileged host-mounted pod that is node-root
#                                    from step 1 (models a compromised privileged workload)
#     DEPLOY_VICTIM=0|1              also deploy victim-host (a sacrificial box with a weak root
#                                    password) as a credential-change / lockout target
#     GOAL="..."                     specific objective appended to the agent's prompt, e.g.
#                                    "change the root password of the victim-host pod in ns redteam"
#     WARMUP_S=45                    seconds of benign load before the attack starts
#     RATE=500 TOTAL_S=600 SEGMENT_S=600   benign capture knobs (deploy.sh --run)
#     SSH_USER / CONTROL_HOST        as in deploy.sh
#   The LLM (OpenRouter key, model, limits) comes from redteam/.env — copy
#   redteam/.env.example to redteam/.env and set llm.api_key first.
set -euo pipefail

BENCH="boutique"
DEPLOY=1
KEEP=0
for arg in "$@"; do
	case "$arg" in
		--no-deploy) DEPLOY=0 ;;
		--keep)      KEEP=1 ;;
		-*) echo "[!] Unknown option: $arg (supported: --no-deploy, --keep)" >&2; exit 1 ;;
		*)  BENCH="$arg" ;;
	esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REDTEAM_DIR="${REPO_ROOT}/redteam"
RBAC_PROFILE="${RBAC_PROFILE:-recon}"
WARMUP_S="${WARMUP_S:-45}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)

CFG_USER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodes_user"])' \
	"${SCRIPT_DIR}/config.json" 2>/dev/null || true)"
SSH_USER="${SSH_USER:-${CFG_USER:-yuhang}}"
source "${SCRIPT_DIR}/nodes.sh"
MAIN="${CONTROL_HOST:-${NODES[0]:-}}"
[ -z "${MAIN}" ] && { echo "[!] no control node; set CONTROL_HOST" >&2; exit 1; }

ATTACKER_SA="system:serviceaccount:redteam:redteam-agent"

# --- 0. preflight: LLM key + uv + venv -------------------------------------
if [ ! -f "${REDTEAM_DIR}/.env" ]; then
	echo "[!] ${REDTEAM_DIR}/.env not found. Copy .env.example to .env and set your" >&2
	echo "    OpenRouter key (llm.api_key) before running the attack." >&2
	exit 1
fi
if grep -qE "^llm.api_key=['\"]?(sk-or-\.\.\.|your-api-key)" "${REDTEAM_DIR}/.env"; then
	echo "[!] ${REDTEAM_DIR}/.env still has the placeholder llm.api_key — set a real key." >&2
	exit 1
fi
command -v uv >/dev/null 2>&1 || export PATH="$HOME/.local/bin:$PATH"
command -v uv >/dev/null 2>&1 || { echo "[!] uv not found (needed to run the agent)" >&2; exit 1; }

# --- 1. ensure benchmark + node labels --------------------------------------
if [ "${DEPLOY}" -eq 1 ]; then
	echo "[*] Ensuring '${BENCH}' is deployed (deploy.sh)"
	"${SCRIPT_DIR}/deploy.sh" "${BENCH}"
fi

# --- 2. deploy the attacker launchpad ---------------------------------------
# RBAC_PROFILE selects which technique SUCCEEDS. Every profile builds on the base
# (namespace + rbac-recon.yaml = SA + in-ns Role + cluster topology read) and adds
# one tier file. exec/token/escalated also plant the ci-runner cluster-admin decoy
# as a pivot target; FOOTHOLD=privileged swaps in the host-mounted attacker pod.
BASE_FILES="namespace.yaml rbac-recon.yaml"
case "${RBAC_PROFILE}" in
	recon)     TIER_FILES="" ;;
	secrets)   TIER_FILES="rbac-secrets.yaml" ;;
	exec)      TIER_FILES="rbac-exec.yaml" ;;
	breakout)  TIER_FILES="rbac-breakout.yaml" ;;
	token)     TIER_FILES="rbac-token.yaml" ;;
	rbac)      TIER_FILES="rbac-rbac.yaml" ;;
	escalated) TIER_FILES="rbac-escalated.yaml" ;;
	*) echo "[!] unknown RBAC_PROFILE '${RBAC_PROFILE}' (recon|secrets|exec|breakout|token|rbac|escalated)" >&2; exit 1 ;;
esac
EXTRA_FILES=""
case "${RBAC_PROFILE}" in
	exec|token|escalated) EXTRA_FILES="decoy-privileged-sa.yaml" ;;
esac
[ "${DEPLOY_VICTIM:-0}" = "1" ] && EXTRA_FILES="${EXTRA_FILES} victim-host.yaml"
ATTACKER_FILE="attacker.yaml"
[ "${FOOTHOLD:-normal}" = "privileged" ] && ATTACKER_FILE="attacker-privileged.yaml"

echo "[*] Deploying red-team launchpad (ns redteam; profile=${RBAC_PROFILE}, foothold=${FOOTHOLD:-normal}, extras=[${EXTRA_FILES# }])"
# Concatenate with explicit `---` separators between files (cat alone would merge
# the last doc of one file with the first of the next).
{ for f in ${BASE_FILES} ${TIER_FILES} ${EXTRA_FILES} ${ATTACKER_FILE}; do
	cat "${REPO_ROOT}/k8s/redteam/${f}"; printf '\n---\n'
  done; } | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "kubectl apply -f -"

echo "[*] Waiting for the attacker pod to become Ready"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
	"kubectl -n redteam rollout status deploy/redteam-agent --timeout=180s"
POD="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
	"kubectl -n redteam get pod -l app=redteam-agent -o jsonpath='{.items[0].metadata.name}'")"
POD_IP="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
	"kubectl -n redteam get pod -l app=redteam-agent -o jsonpath='{.items[0].status.podIP}'")"
echo "    attacker pod: ${POD}  ip: ${POD_IP}  sa: ${ATTACKER_SA}"
[ -z "${POD}" ] && { echo "[!] could not find the attacker pod" >&2; exit 1; }

# --- 3. start the benign capture in the background --------------------------
RESULTS_DIR="${REPO_ROOT}/results"
mkdir -p "${RESULTS_DIR}"
BEFORE="$(mktemp)"; ls -1 "${RESULTS_DIR}" 2>/dev/null | sort > "${BEFORE}"
export RATE="${RATE:-500}" TOTAL_S="${TOTAL_S:-600}" SEGMENT_S="${SEGMENT_S:-600}"
CAP_LOG="$(mktemp)"
echo "[*] Starting benign capture in background: deploy.sh ${BENCH} --run "
echo "    (RATE=${RATE} TOTAL_S=${TOTAL_S} SEGMENT_S=${SEGMENT_S}); log: ${CAP_LOG}"
( "${SCRIPT_DIR}/deploy.sh" "${BENCH}" --run >"${CAP_LOG}" 2>&1 ) &
CAP_PID=$!

# --- 4. run the LLM agent for the attack window -----------------------------
echo "[*] Warmup ${WARMUP_S}s before detonation..."
sleep "${WARMUP_S}"
ATTACK_LOG="$(mktemp)"
SESSION_START="$(date -u +%s)"
echo "[*] Running hackingBuddyGPT K8sPostCompromise from pod ${POD} (ts ${SESSION_START})"
set +e
AGENT_ARGS=(K8sPostCompromise --pod "${POD}" --node0 "${MAIN}" --node0_user "${SSH_USER}" --namespace redteam)
[ -n "${GOAL:-}" ] && AGENT_ARGS+=(--goal "${GOAL}")
[ -n "${GOAL:-}" ] && echo "[*] Agent goal: ${GOAL}"
( cd "${REDTEAM_DIR}" && uv run redteam-agent "${AGENT_ARGS[@]}" ) 2>&1 | tee "${ATTACK_LOG}"
set -e
SESSION_END="$(date -u +%s)"
echo "[*] Attack session finished (ts ${SESSION_END}, ${SESSION_END}-${SESSION_START}=$((SESSION_END-SESSION_START))s)"
HBGPT_LOG="$(ls -1t "${REDTEAM_DIR}"/logs/log-*.jsonl 2>/dev/null | head -1 || true)"

# --- 5. wait for the benign capture to finish + copy back -------------------
echo "[*] Waiting for the benign capture to finish..."
wait "${CAP_PID}" || echo "[!] benign capture exited non-zero (see ${CAP_LOG})" >&2
AFTER="$(mktemp)"; ls -1 "${RESULTS_DIR}" 2>/dev/null | sort > "${AFTER}"
NEW_DIRS="$(comm -13 "${BEFORE}" "${AFTER}" || true)"

# --- 6. write attack ground truth into overlapping run dirs -----------------
MODEL="$(sed -nE "s/^llm.model=['\"]?([^'\"]+).*/\1/p" "${REDTEAM_DIR}/.env" | head -1)"
echo "[*] Writing attack.json into run dirs overlapping [${SESSION_START},${SESSION_END}]"
python3 - "$RESULTS_DIR" "$SESSION_START" "$SESSION_END" "$POD" "$POD_IP" \
	"$ATTACKER_SA" "$RBAC_PROFILE" "${MODEL:-}" "${HBGPT_LOG:-}" "$NEW_DIRS" <<'PY'
import json, os, sys
results, s0, s1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
pod, pod_ip, sa, profile, model, hblog = sys.argv[4:10]
new_dirs = [l.strip() for l in sys.argv[10].splitlines() if l.strip()]
attack = {
    "is_attack": True, "attacker_tool": "hackingBuddyGPT",
    "attacker_namespace": "redteam", "attacker_namespaces": ["redteam"],
    "attacker_pod": pod, "attacker_ips": [pod_ip] if pod_ip else [],
    "attacker_sa": sa, "rbac_profile": profile, "llm_model": model,
    "session_start_epoch": s0, "session_end_epoch": s1,
    "hbgpt_log": os.path.basename(hblog) if hblog else None,
}
wrote = 0
for name in new_dirs:
    d = os.path.join(results, name)
    mp = os.path.join(d, "meta.json")
    if not os.path.isdir(d) or not os.path.exists(mp):
        continue
    try:
        meta = json.load(open(mp))
    except Exception:
        continue
    a, b = meta.get("start_epoch"), meta.get("end_epoch")
    # overlap of the run window with the attack session
    if a is not None and b is not None and not (b < s0 or a > s1):
        os.makedirs(os.path.join(d, "attack"), exist_ok=True)
        json.dump(attack, open(os.path.join(d, "attack", "attack.json"), "w"), indent=2)
        # copy the agent transcript alongside for provenance
        if hblog and os.path.exists(hblog):
            import shutil
            shutil.copy(hblog, os.path.join(d, "attack", os.path.basename(hblog)))
        wrote += 1
        print(f"    + {name}  ({a}..{b})")
print(f"[redteam] wrote attack.json into {wrote} run dir(s)")
if wrote == 0:
    print("[redteam] WARN: no run dir overlapped the attack window — check TOTAL_S/WARMUP_S")
PY

# --- 7. teardown ------------------------------------------------------------
# Cluster-scoped objects any profile may have created (ns delete does NOT remove
# these). ci-runner-admin is the decoy cluster-admin binding — it MUST go.
CLUSTER_RBAC="redteam-agent-read redteam-agent-secrets redteam-agent-rbac redteam-agent-escalated"
if [ "${KEEP}" -ne 1 ]; then
	echo "[*] Tearing down the attacker (ns redteam + cluster-scoped RBAC + decoys)"
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
		"kubectl delete ns redteam --ignore-not-found --wait=false; \
		 kubectl delete clusterrole ${CLUSTER_RBAC} --ignore-not-found; \
		 kubectl delete clusterrolebinding ${CLUSTER_RBAC} ci-runner-admin --ignore-not-found; \
		 kubectl delete clusterrole,clusterrolebinding -l 'ubench.io/role in (attacker,decoy)' --ignore-not-found"
	echo "[!] After an 'rbac'/'escalated' run, audit for bindings the agent created under NEW names"
	echo "    (they won't carry our labels): ssh ${SSH_USER}@${MAIN} 'kubectl get clusterrolebindings'"
else
	echo "[*] --keep: leaving the attacker + decoys up (ns redteam)."
	echo "[!] NOTE: the ci-runner-admin ClusterRoleBinding grants cluster-admin. Tear down when done:"
	echo "    ssh ${SSH_USER}@${MAIN} 'kubectl delete ns redteam --wait=false; \\"
	echo "        kubectl delete clusterrole ${CLUSTER_RBAC} --ignore-not-found; \\"
	echo "        kubectl delete clusterrolebinding ${CLUSTER_RBAC} ci-runner-admin --ignore-not-found; \\"
	echo "        kubectl delete clusterrole,clusterrolebinding -l \"ubench.io/role in (attacker,decoy)\" --ignore-not-found'"
fi

rm -f "${BEFORE}" "${AFTER}"
echo
echo "[*] Done. Label + evaluate from the gnnid repo root:"
echo "    uv run gnnid ingest --labels && uv run gnnid train && uv run gnnid score && uv run gnnid eval"
