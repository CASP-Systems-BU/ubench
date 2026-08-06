#!/bin/bash
#
# Deploy (or tear down) a ubench workload on the CloudLab k8s cluster and,
# with --run, drive a rate-controlled wrk2 experiment against it.
#
# Run this from the SAME machine you run bootstrap.sh from (your laptop / dev
# box). It renders the benchmark manifests for the requested experiment
# (scripts/render_manifests.py -> build/<name>/), copies them up to the control
# node (node-0), applies them there, waits for rollout, and heartbeat-sweeps
# the services. With --down it deletes the currently deployed workload instead.
#
# The cluster must already be up (./bootstrap.sh). Cluster size is whatever you
# instantiated on CloudLab (register it with register_cluster.py); deploy fails
# fast if the experiment needs more workers than the cluster has.
#
#   Usage:
#     ./deploy.sh                                        # deploy boutique defaults
#     ./deploy.sh movie                                  # deploy another workload
#     ./deploy.sh --experiment ../../experiments/foo.yaml --run
#                                                        # render+deploy+run a spec
#     ./deploy.sh boutique --run                         # one 60s segment, defaults
#     ./deploy.sh boutique --down                        # tear down a workload
#
#   Env overrides (precedence: built-in default < spec file < env var):
#     CONTROL_HOST=apt190.apt.emulab.net   # control node (default: 1st in nodes.sh)
#     SSH_USER=yuhang                      # ssh user (default: config.json nodes_user)
#     REQUEST=mix THREADS=4 CONNS=16       # load shape
#     RATE=1000                            # wrk2 -R, total offered req/s
#     TOTAL_S=3600 SEGMENT_S=600           # continuous load; one run dir per segment
#     CLIENT_IMAGE=<registry>/ubench-client:<tag>   # load-generator image
#
# Prereqs: `ssh <user>@<control-host>` works with your CloudLab key in the
# ssh-agent; python3 + PyYAML locally (for the manifest renderer).
set -euo pipefail

# Args: an optional workload name, --experiment <spec.yaml>, and --down/--run.
BENCH=""
SPEC=""
DOWN=0
RUN=0
expect_spec=0
for arg in "$@"; do
	if [[ "${expect_spec}" -eq 1 ]]; then
		SPEC="${arg}"; expect_spec=0; continue
	fi
	case "$arg" in
		--experiment)   expect_spec=1 ;;
		--experiment=*) SPEC="${arg#--experiment=}" ;;
		--down) DOWN=1 ;;
		--run)  RUN=1 ;;
		-*)     echo "[!] Unknown option: $arg (supported: --experiment <spec>, --down, --run)" >&2; exit 1 ;;
		*)      BENCH="$arg" ;;
	esac
done
if [[ "${expect_spec}" -eq 1 ]]; then
	echo "[!] --experiment needs a spec file argument" >&2; exit 1
fi
if [[ "${DOWN}" -eq 1 && "${RUN}" -eq 1 ]]; then
	echo "[!] --down and --run are mutually exclusive" >&2; exit 1
fi
if [[ -n "${SPEC}" && "${DOWN}" -eq 1 ]]; then
	echo "[!] --down takes a workload name, not --experiment" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)

# ssh user: config.json `nodes_user` is the single source of truth
# (register_cluster.py writes it); SSH_USER env still overrides.
CFG_USER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodes_user"])' \
	"${SCRIPT_DIR}/config.json" 2>/dev/null || true)"
SSH_USER="${SSH_USER:-${CFG_USER:-yuhang}}"

# Control node: the first hostname in nodes.sh (the shared node list, node-0).
# Override with CONTROL_HOST if you need to target a different node.
source "${SCRIPT_DIR}/nodes.sh"
MAIN="${CONTROL_HOST:-${NODES[0]:-}}"
if [[ -z "${MAIN}" ]]; then
	echo "[!] Could not determine the control node hostname. Set CONTROL_HOST=..." >&2
	exit 1
fi

# --- teardown ---------------------------------------------------------------
# Tears down from the manifests of the LAST deploy (kept on the control node),
# so it removes exactly what was applied — including rendered per-replica
# Deployments that don't exist in the checked-in yamls.
# NOTE: workloads share generic service names (every one has a "frontend"), so
# only tear down the workload that is actually deployed.
if [[ "${DOWN}" -eq 1 ]]; then
	BENCH="${BENCH:-boutique}"
	REMOTE_YAMLS="~/ubench/k8s/${BENCH}/yamls"
	echo "[*] Tearing down '${BENCH}' on ${SSH_USER}@${MAIN}"
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
		"test -d ${REMOTE_YAMLS} || { echo '[!] no deployed manifests at ${REMOTE_YAMLS}' >&2; exit 1; }
		 kubectl delete --ignore-not-found -f ${REMOTE_YAMLS}/"
	echo
	echo "=== remaining workload resources (default namespace) ==="
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "kubectl get deploy,svc"
	echo
	echo "[*] '${BENCH}' torn down on ${MAIN}."
	exit 0
fi

# --- render the manifests for this experiment --------------------------------
# Always render (the no-spec path renders the checked-in defaults: workers=4,
# replicas=1 — semantically identical to the source yamls) so the deploy path
# is uniform and chain-*'s ${PROCESSING_TIME_*} placeholders get substituted.
if [[ -n "${SPEC}" ]]; then
	RENDER_ARGS=(--spec "${SPEC}")
else
	RENDER_ARGS=(--bench "${BENCH:-boutique}")
fi
echo "[*] Rendering manifests: render_manifests.py ${RENDER_ARGS[*]}"
BUILD_DIR="$(python3 "${REPO_ROOT}/scripts/render_manifests.py" "${RENDER_ARGS[@]}" | tail -n 1)"
if [[ ! -f "${BUILD_DIR}/spec.env" ]]; then
	echo "[!] Rendering failed (no ${BUILD_DIR}/spec.env)" >&2; exit 1
fi
source "${BUILD_DIR}/spec.env"
BENCH="${SPEC_BENCH}"

# Experiment knobs (precedence: built-in default < spec < env var). DURATION is
# accepted as a legacy alias for TOTAL_S.
REQUEST="${REQUEST:-${SPEC_REQUEST}}"
THREADS="${THREADS:-${SPEC_THREADS}}"
CONNS="${CONNS:-${SPEC_CONNS}}"
RATE="${RATE:-${SPEC_RATE}}"
TOTAL_S="${TOTAL_S:-${DURATION:-${SPEC_TOTAL_S}}}"
SEGMENT_S="${SEGMENT_S:-${SPEC_SEGMENT_S}}"
CLIENT_IMAGE="${CLIENT_IMAGE:-}"

# Copy the rendered manifests up to the control node, staged: if a previous
# render of this benchmark is deployed and its yamls differ (e.g. a service
# went from 1 replica to per-replica Deployments), the old objects are deleted
# first — `kubectl apply -f dir/` never prunes, so a stale Deployment would
# otherwise keep running behind the Service. Identical re-renders skip the
# delete (no pod churn on self-healing redeploys).
echo "[*] Copying ${BUILD_DIR} -> ${MAIN}:~/ubench/k8s/${BENCH}/"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
	"rm -rf ~/ubench/k8s/.incoming_${BENCH} && mkdir -p ~/ubench/k8s/.incoming_${BENCH}"
scp "${SSH_OPTS[@]}" -r "${BUILD_DIR}"/* "${SSH_USER}@${MAIN}:~/ubench/k8s/.incoming_${BENCH}/"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "bash -s" "${BENCH}" <<'EOF'
set -e
BENCH="$1"
OLD="${HOME}/ubench/k8s/${BENCH}"
NEW="${HOME}/ubench/k8s/.incoming_${BENCH}"
if [ -d "${OLD}/yamls" ] && ! diff -rq "${OLD}/yamls" "${NEW}/yamls" >/dev/null 2>&1; then
	echo "[*] Rendered manifests changed since last deploy — deleting the old objects first"
	# A failed delete must abort BEFORE the swap below: OLD/yamls is the only
	# record of what was applied, and swapping it away would orphan whatever
	# the delete missed (an undeleted frontend-2 would keep serving forever).
	kubectl delete --ignore-not-found -f "${OLD}/yamls/" || {
		echo "[!] drift delete failed; keeping the old manifests so the next deploy retries" >&2
		exit 1
	}
fi
rm -rf "${OLD}"
mv "${NEW}" "${OLD}"
EOF

REMOTE_YAMLS="~/ubench/k8s/${BENCH}/yamls"

# --- deterministic node labels + worker validation ---------------------------
# Manifests pin pods to nodes with `nodeSelector: ubench.io/node-index: "<N>"`
# so the pod->node layout — and therefore the cross-node network flow graph —
# is identical on every run. Those labels have to exist first. We key them off
# the stable node-<N> ordinal (the CloudLab hostname embeds the experiment name,
# e.g. node-3.ubench-7..., which changes between experiments; the ordinal does
# not). Idempotent (`--overwrite`), so it re-applies and self-heals each deploy.
# The experiment needs worker indices 1..SPEC_WORKERS; fail fast if any is
# missing rather than leaving pods Pending.
echo "[*] Labeling nodes with ubench.io/node-index=<ordinal> on ${MAIN}"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "bash -s" "${SPEC_WORKERS}" <<'EOF'
set -e
WORKERS="$1"
for node in $(kubectl get nodes -o name); do
	name="${node#node/}"
	idx="$(printf '%s' "${name}" | sed -nE 's/^node-([0-9]+).*/\1/p')"
	if [ -n "${idx}" ]; then
		kubectl label node "${name}" "ubench.io/node-index=${idx}" --overwrite >/dev/null
	else
		echo "  [!] ${name} doesn't match node-<N>; not labeling (pods selecting it stay Pending)" >&2
	fi
done
kubectl get nodes -L ubench.io/node-index
for i in $(seq 1 "${WORKERS}"); do
	if ! kubectl get nodes -l "ubench.io/node-index=${i}" --no-headers 2>/dev/null | grep -q .; then
		echo "[!] experiment needs ${WORKERS} workers but no node has ubench.io/node-index=${i}" >&2
		exit 1
	fi
done
EOF

# --- apply + wait + verify, all on the control node ---------------------------
# Heredoc is quoted ('EOF') so it is sent verbatim; the benchmark name and kind
# are passed as $1/$2 to the remote bash. The synthetic mesh emulator (chain-*)
# has no /heartbeat endpoint, so the sweep is skipped for kind=synthetic — its
# readiness probes already gate the rollout.
echo "[*] Applying manifests + verifying on ${MAIN}"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "bash -s" "${BENCH}" "${SPEC_KIND}" <<'EOF'
set -e
BENCH="$1"
KIND="$2"
YAMLS="${HOME}/ubench/k8s/${BENCH}/yamls"

# Benchmarks share object names (every one has a `frontend`), so applying over
# a DIFFERENT deployed benchmark would silently mutate its objects in place and
# leave the rest of it running — a mixed topology that poisons the telemetry.
# Rendered objects carry ubench.io/bench=<bench>; tear down any other bench's
# objects before applying this one.
FOREIGN=$(kubectl get deploy,svc,cm -l "ubench.io/bench,ubench.io/bench!=${BENCH}" \
	-o name 2>/dev/null || true)
if [ -n "${FOREIGN}" ]; then
	echo "[*] Another benchmark's objects are deployed — tearing them down first:"
	echo "${FOREIGN}" | sed 's/^/      /'
	kubectl delete -l "ubench.io/bench,ubench.io/bench!=${BENCH}" deploy,svc,cm
fi

kubectl apply -f "${YAMLS}/"

echo
echo "[*] Waiting for this benchmark's deployments to become available (timeout 180s)..."
kubectl wait --for=condition=available --timeout=180s deploy -l "ubench.io/bench=${BENCH}"

echo
echo "=== deployments ==="
kubectl get deploy

if [ "${KIND}" = "synthetic" ]; then
	echo
	echo "=== heartbeat sweep skipped (synthetic emulator has no /heartbeat) ==="
	exit 0
fi

echo
echo "=== heartbeat sweep (this benchmark's services, from inside the cluster) ==="
POD=$(kubectl get pods -o jsonpath='{.items[0].metadata.name}')
rc=0
for svc in $(kubectl get svc -l "ubench.io/bench=${BENCH}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -vx kubernetes); do
	ok=0
	for _ in 1 2 3; do
		# Proper HTTP client (not a raw `echo | nc` request): behaves identically
		# without Istio, and also works when the pods carry an Envoy sidecar,
		# which rejects the half-formed nc request. -t 1: single attempt (GNU
		# wget retries by default), -T 3: same timeout as the old nc -w 3.
		if kubectl exec "$POD" -- wget -qO- -T 3 -t 1 "http://${svc}:80/heartbeat" 2>/dev/null | grep -qi heartbeat; then
			ok=1; break
		fi
		sleep 2
	done
	if [ "$ok" -eq 1 ]; then echo "  [OK]   $svc"; else echo "  [FAIL] $svc"; rc=1; fi
done
exit $rc
EOF

echo
echo "[*] '${BENCH}' deployed and verified on ${MAIN}."

# --- run the wrk2 experiment + collect telemetry (optional) -------------------
# run_and_collect.sh wraps scripts/run.sh (client pod + detached wrk2) with a
# segmented collector: one continuous load of TOTAL_S seconds, telemetry
# harvested every SEGMENT_S into its own run directory (k8s snapshots, Hubble
# flow slice, resources.csv slice, Istio metrics/access logs, audit slice,
# meta.json). The remote writes a manifest of segment dirs; every listed dir is
# copied back — including failed ones (their run_status != 0 excludes them from
# ingest but preserves the evidence).
if [[ "${RUN}" -eq 1 ]]; then
	echo
	echo "[*] Copying run.sh + collectors + client/ to ${MAIN}"
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "mkdir -p ~/ubench/scripts ~/ubench/results"
	scp "${SSH_OPTS[@]}" \
		"${REPO_ROOT}/scripts/run.sh" \
		"${REPO_ROOT}/scripts/run_and_collect.sh" \
		"${REPO_ROOT}/scripts/collect_metrics.py" \
		"${SSH_USER}@${MAIN}:~/ubench/scripts/"
	scp "${SSH_OPTS[@]}" -r "${REPO_ROOT}/client" "${SSH_USER}@${MAIN}:~/ubench/"

	# One experiment id names the remote manifest file; each segment dir gets
	# its own timestamp id (that trailing timestamp is what downstream sorts on).
	RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
	REMOTE_HOME="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" 'echo $HOME')"
	REMOTE_MANIFEST="${REMOTE_HOME}/ubench/results/manifest_${RUN_ID}.txt"
	LOCAL_RESULTS="${REPO_ROOT}/results"
	mkdir -p "${LOCAL_RESULTS}"

	echo "[*] Running wrk2 + collecting: ${BENCH} request=${REQUEST} threads=${THREADS} conns=${CONNS} rate=${RATE}rps total=${TOTAL_S}s segment=${SEGMENT_S}s (experiment ${SPEC_NAME}, id ${RUN_ID})"
	# -A forwards the ssh-agent so the collector can SSH control->worker to read
	# the rotated Envoy access logs off each node's /var/log/pods (kubelet rotates
	# busy sidecars mid-run, and `kubectl logs` only returns the current file).
	set +e
	ssh -A "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" \
		"RUN_ID=${RUN_ID} EXPERIMENT='${SPEC_NAME}' WORKERS=${SPEC_WORKERS} CLIENT_IMAGE='${CLIENT_IMAGE}' \
		 bash ~/ubench/scripts/run_and_collect.sh ${BENCH} ${REQUEST} ${THREADS} ${CONNS} ${TOTAL_S} ${RATE} ${SEGMENT_S}"
	RUN_RC=$?
	set -e

	echo
	echo "[*] Copying segment dirs back -> ${LOCAL_RESULTS}/"
	MANIFEST_LOCAL="$(mktemp)"
	if ! scp "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}:${REMOTE_MANIFEST}" "${MANIFEST_LOCAL}"; then
		echo "[!] No segment manifest on ${MAIN} — nothing to copy back" >&2
		rm -f "${MANIFEST_LOCAL}"
		exit "${RUN_RC:-1}"
	fi
	while IFS= read -r dir; do
		[ -n "${dir}" ] || continue
		scp "${SSH_OPTS[@]}" -r "${SSH_USER}@${MAIN}:${dir}" "${LOCAL_RESULTS}/" \
			|| echo "[!] copy failed for ${dir}" >&2
	done < "${MANIFEST_LOCAL}"
	echo "[*] Experiment finished (rc=${RUN_RC}); segments:"
	sed "s|.*/|    ${LOCAL_RESULTS}/|" "${MANIFEST_LOCAL}"
	rm -f "${MANIFEST_LOCAL}"
	exit "${RUN_RC}"
fi
