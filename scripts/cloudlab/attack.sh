#!/bin/bash
#
# Run a Stratus Red Team attack simulation against the CloudLab k8s cluster while
# a benign workload runs, capturing the full labeled metric/provenance bundle.
#
# This is the attack-aware sibling of deploy.sh's `--run` path. From your dev box
# it: (1) ensures the benchmark is deployed, (2) ships the attack harness up to
# the control node, (3) runs attack_and_collect.sh there (benign load + Stratus
# detonation + metric/audit capture + labeling), (4) copies the labeled run dir
# back to results/.
#
# Prereqs:
#   * cluster up (scripts/cloudlab/bootstrap.sh)
#   * Stratus installed on the control node (~/.local/bin/stratus) and audit
#     logging enabled (scripts/cloudlab/enable_audit.sh enable)
#
#   Usage:
#     ./attack.sh                       # boutique + default technique (privileged-pod)
#     ./attack.sh boutique              # explicit benchmark
#     ./attack.sh boutique --no-deploy  # skip the deploy step (already running)
#
#   Env:
#     CONTROL_HOST=...   control node (default: 1st in nodes.sh)
#     SSH_USER=yuhang
#     REQUEST=mix THREADS=4 CONNS=16 DURATION=90   # benign wrk load
#     TECHNIQUES="k8s.privilege-escalation.privileged-pod ..."  # space-separated
#     ATTACK_DELAY=25    # seconds into the load before detonation
#     KEEP_ATTACK=0      # 1 = leave the attack resources (skip stratus cleanup)
set -euo pipefail

BENCH="boutique"
DEPLOY=1
for arg in "$@"; do
	case "$arg" in
		--no-deploy) DEPLOY=0 ;;
		-*) echo "[!] Unknown option: $arg (supported: --no-deploy)" >&2; exit 1 ;;
		*)  BENCH="$arg" ;;
	esac
done

SSH_USER="${SSH_USER:-yuhang}"
REQUEST="${REQUEST:-mix}"
THREADS="${THREADS:-4}"
CONNS="${CONNS:-16}"
DURATION="${DURATION:-90}"
TECHNIQUES="${TECHNIQUES:-k8s.privilege-escalation.privileged-pod}"
ATTACK_DELAY="${ATTACK_DELAY:-25}"
KEEP_ATTACK="${KEEP_ATTACK:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)

source "${SCRIPT_DIR}/nodes.sh"
MAIN="${CONTROL_HOST:-${NODES[0]:-}}"
[ -z "${MAIN}" ] && { echo "[!] no control node; set CONTROL_HOST" >&2; exit 1; }

# 1. Ensure the benchmark is deployed.
if [[ "${DEPLOY}" -eq 1 ]]; then
	echo "[*] Ensuring '${BENCH}' is deployed (deploy.sh)"
	"${SCRIPT_DIR}/deploy.sh" "${BENCH}"
fi

# 2. Verify prereqs on the control node (stratus + audit logging).
echo "[*] Checking attack prereqs on ${MAIN}"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" 'bash -s' <<'EOF'
test -x "$HOME/.local/bin/stratus" || { echo "[!] stratus not installed at ~/.local/bin/stratus" >&2; exit 1; }
sudo sh -c 'ls /var/log/kubernetes/audit/*.log' >/dev/null 2>&1 \
	|| echo "[!] WARN: no audit log found — run scripts/cloudlab/enable_audit.sh enable for control-plane capture" >&2
echo "[+] stratus: $($HOME/.local/bin/stratus version 2>/dev/null | head -1 || echo present)"
EOF

# 3. Ship the harness up.
echo "[*] Copying attack harness + collectors + client/ to ${MAIN}"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "mkdir -p ~/ubench/scripts ~/ubench/results"
scp "${SSH_OPTS[@]}" \
	"${REPO_ROOT}/scripts/run.sh" \
	"${REPO_ROOT}/scripts/attack_and_collect.sh" \
	"${REPO_ROOT}/scripts/collect_metrics.py" \
	"${REPO_ROOT}/scripts/label_attack.py" \
	"${SSH_USER}@${MAIN}:~/ubench/scripts/"
scp "${SSH_OPTS[@]}" -r "${REPO_ROOT}/client" "${SSH_USER}@${MAIN}:~/ubench/"

# 4. Run the attack + capture on the control node.
RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
REMOTE_HOME="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" 'echo $HOME')"
REMOTE_DIR="${REMOTE_HOME}/ubench/results/attack-${BENCH}-${REQUEST}_${RUN_ID}"
LOCAL_RESULTS="${REPO_ROOT}/results"
mkdir -p "${LOCAL_RESULTS}"

echo "[*] Running attack+collect on ${MAIN}: ${BENCH}/${REQUEST} d=${DURATION}s"
echo "    techniques: ${TECHNIQUES}  attack_delay=${ATTACK_DELAY}s  (run ${RUN_ID})"
# -A forwards the agent so collect_metrics can SSH control->worker for rotated
# Envoy logs (same as deploy.sh --run).
ssh -A "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
	"RUN_ID=${RUN_ID} TECHNIQUES='${TECHNIQUES}' ATTACK_DELAY=${ATTACK_DELAY} KEEP_ATTACK=${KEEP_ATTACK} \
	 bash ~/ubench/scripts/attack_and_collect.sh ${BENCH} ${REQUEST} ${THREADS} ${CONNS} ${DURATION}"

# 5. Pull the labeled run dir back.
echo "[*] Copying run dir back -> ${LOCAL_RESULTS}/"
scp "${SSH_OPTS[@]}" -r "${SSH_USER}@${MAIN}:${REMOTE_DIR}" "${LOCAL_RESULTS}/"
echo "[*] Attack run finished. Labeled bundle in ${LOCAL_RESULTS}/attack-${BENCH}-${REQUEST}_${RUN_ID}/"
