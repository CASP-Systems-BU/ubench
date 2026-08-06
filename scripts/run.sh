#!/bin/bash
#
# Deploy the load-generator client and drive one wrk2 run against a benchmark.
#
#   run.sh <benchmark> <request> <threads> <conns> <total_s> [rate]
#
#   benchmark  boutique | hotel | movie | social | synthetic | mutex |
#              chain-d2-http-sync | chain-d8-http-sync
#   request    boutique: client/lua/<request>.lua (via the wrk-scripts ConfigMap)
#              chain-*/synthetic: URL path on service0
#              hotel/movie/social: ignored (mix lives in the rust proxy)
#   rate       wrk2 -R, total offered req/s (default $RATE or 1000). wrk2 is
#              open-loop: this is REQUIRED load, not a cap — see experiments/README.md
#
# Env:
#   RATE          rate fallback when $6 is not given
#   CLIENT_IMAGE  load-generator image (default: the pinned tag below)
#   LOAD_MODE     block (default): wait for wrk2 to finish, exit with its status
#                 detach: return once wrk2 is confirmed running (run_and_collect.sh
#                 uses this and harvests telemetry in segments while it runs)
#   WARMUP_S      settle time before starting the load (default 10)
#
# wrk2 writes inside the client pod: /tmp/wrk.log (output) and /tmp/wrk.rc
# (exit code, written when it finishes) — that is the contract run_and_collect.sh
# polls. Latency numbers are coordinated-omission-corrected; they are NOT
# comparable with numbers from the old closed-loop wrk.

cd "$(dirname "$0")"

benchmark=${1:-boutique}
request=${2:-mix}
thread=${3:-4}
conn=${4:-16}
total_s=${5:-60}
rate=${6:-${RATE:-1000}}

LOAD_MODE="${LOAD_MODE:-block}"
WARMUP_S="${WARMUP_S:-10}"
# The one place the blessed client image lives. Update on each image release
# (scripts/BUILD.md); override per-run with CLIENT_IMAGE=...
export CLIENT_IMAGE="${CLIENT_IMAGE:-<REGISTRY>/ubench-client:latest}"

YAML_PATH=../k8s/$benchmark/yamls
if [[ $benchmark == "synthetic" ]]; then
    YAML_PATH=../k8s/$request/yamls
fi

supported_benchmarks=("boutique" "social" "movie" "hotel" "synthetic" "mutex"
                      "chain-d2-http-sync" "chain-d8-http-sync")

check_benchmark_supported() {
    local benchmark=$1
    for b in "${supported_benchmarks[@]}"; do
        if [[ $b == $benchmark ]]; then
            return 0
        fi
    done
    return 1
}

# ---- parameter guards (fail before touching the cluster) -------------------
check_benchmark_supported $benchmark
if [ $? -ne 0 ]; then
    echo "[run.sh] Benchmark $benchmark is not supported"
    exit 1
fi
if ! [[ "$rate" =~ ^[0-9]+$ ]] || [[ "$rate" -eq 0 ]]; then
    echo "[run.sh] wrk2 is open-loop: RATE (req/s) must be a positive integer, got '$rate'" >&2
    exit 1
fi
if ! [[ "$total_s" =~ ^[0-9]+$ ]] || [[ "$total_s" -eq 0 ]]; then
    echo "[run.sh] duration must be a positive integer (seconds), got '$total_s'" >&2
    exit 1
fi
# [[ x -lt y ]] silently coerces non-numerics to 0, so validate explicitly.
if ! [[ "$thread" =~ ^[0-9]+$ ]] || ! [[ "$conn" =~ ^[0-9]+$ ]] \
        || [[ "$thread" -eq 0 ]] || [[ "$conn" -eq 0 ]]; then
    echo "[run.sh] threads ('$thread') and connections ('$conn') must be positive integers" >&2
    exit 1
fi
if [[ "$conn" -lt "$thread" ]]; then
    echo "[run.sh] connections ($conn) must be >= threads ($thread) — wrk2 splits conns over threads" >&2
    exit 1
fi
if [[ "$total_s" -lt 60 ]]; then
    echo "[run.sh] WARN: wrk2 spends its first 10s calibrating; ${total_s}s < 60s gives unreliable latency" >&2
fi

check_connectivity() {
    local pod_name=$1
    local service_name=$2
    # if service name is the same as the pod name (prefix), skip the check
    if [[ $1 == $2* ]]; then
        return 0
    fi
    # if the pod is ubuntu client
    if [[ $pod_name == *"ubuntu-client"* ]]; then
        kubectl exec $pod_name -- curl $service_name:80/heartbeat --max-time 1 | grep Heartbeat > /dev/null
        return $?
    fi
    # Proper HTTP client (not a raw `echo | nc` request): behaves identically
    # without Istio, and also works when the pods carry an Envoy sidecar, which
    # rejects the half-formed nc request. -t 1: single attempt, -T 1: same
    # timeout as the old nc -w 1.
    kubectl exec $pod_name -- wget -qO- -T 1 -t 1 http://$service_name:80/heartbeat 2>/dev/null | grep Heartbeat > /dev/null
    return $?
}

check_connectivity_all(){
    echo "[run.sh] Checking heartbeat for all services"
    # if "grpc" in request, ignore
    if [[ $request == *grpc* ]]; then
        sleep 5
        return 0
    fi
    while true
    do
        all_connected=1
        for pod in $(kubectl get pods | grep -v -E 'NAME' | cut -f 1 -d " ")
        do
            for service in $(kubectl get svc | grep -v -E 'NAME|kube' | cut -f 1 -d " ")
            do
                check_connectivity $pod $service
                if [ $? -ne 0 ]
                then
                    echo "[run.sh] $pod cannot connect to $service"
                    all_connected=0
                    break
                fi
            done
            if [ $all_connected -eq 0 ]
            then
                break
            fi
        done
        if [ $all_connected -eq 1 ]
        then
            echo "[run.sh] All pods can connect to all services"
            break
        fi
    done
}

start_load() {
    local benchmark=$1
    local ubuntu_client=$(kubectl get pod | grep ubuntu-client- | cut -f 1 -d " ")

    if [[ $benchmark == "hotel" || $benchmark == "movie" || $benchmark == "social" ]]; then
        echo "[run.sh] Starting the rust proxy first for $benchmark"
        kubectl exec $ubuntu_client -- bash -c "/mucache/proxy/target/release/proxy ${benchmark} >/tmp/proxy.log 2>&1 &"
        sleep 3
        kubectl exec $ubuntu_client -- cat /tmp/proxy.log
    fi

    local common="--timeout 20s -t${thread} -c${conn} -d${total_s}s -R${rate} -L"
    local cmd
    if [[ $benchmark == "boutique" ]]; then
        cmd="/wrk2/wrk ${common} -s /lua/${request}.lua http://frontend:80"
    elif [[ $benchmark == "mutex" ]]; then
        cmd="/wrk2/wrk ${common} http://service1:80/"
    elif [[ $benchmark == "synthetic" ]]; then
        cmd="/wrk2/wrk ${common} http://service0:80/endpoint1"
    elif [[ $benchmark == chain-* ]]; then
        cmd="/wrk2/wrk ${common} http://service0:80/${request}"
    else
        cmd="/wrk2/wrk ${common} http://localhost:3000"
    fi

    # Detached inside the pod so the kubectl exec session is not the process's
    # lifeline: run_and_collect.sh harvests telemetry in segments while it runs
    # and polls /tmp/wrk.rc for completion. nohup reparents to the container's
    # PID 1 (`sleep 365d`), so the load survives exec-session drops too.
    echo "[run.sh] ${cmd}"
    kubectl exec $ubuntu_client -- bash -c \
        "rm -f /tmp/wrk.rc /tmp/wrk.log; nohup bash -c '${cmd} > /tmp/wrk.log 2>&1; echo \$? > /tmp/wrk.rc' >/dev/null 2>&1 &"

    # Fail fast on immediate errors (bad script path, bad flags): give wrk2 a
    # moment, then require either a live process or a zero exit code.
    sleep 3
    if kubectl exec $ubuntu_client -- test -f /tmp/wrk.rc 2>/dev/null; then
        local rc=$(kubectl exec $ubuntu_client -- cat /tmp/wrk.rc)
        if [[ "$rc" != "0" ]]; then
            echo "[run.sh] wrk2 exited immediately (rc=$rc):"
            kubectl exec $ubuntu_client -- cat /tmp/wrk.log
            return 1
        fi
    elif ! kubectl exec $ubuntu_client -- pgrep -f '/wrk2/wrk' >/dev/null 2>&1; then
        echo "[run.sh] wrk2 did not start:"
        kubectl exec $ubuntu_client -- cat /tmp/wrk.log 2>/dev/null
        return 1
    fi
    echo "[run.sh] load running (${total_s}s at ${rate} req/s)"
    return 0
}

wait_load() {
    # Block until wrk2 writes its exit code, then replay its output so the
    # caller's log (and the wrk.txt slice) contains the stats block.
    local ubuntu_client=$(kubectl get pod | grep ubuntu-client- | cut -f 1 -d " ")
    local deadline=$(( $(date +%s) + total_s + 90 ))
    while ! kubectl exec $ubuntu_client -- test -f /tmp/wrk.rc 2>/dev/null; do
        if [[ $(date +%s) -gt $deadline ]]; then
            echo "[run.sh] wrk2 did not finish within ${total_s}s + 90s grace" >&2
            return 1
        fi
        sleep 5
    done
    kubectl exec $ubuntu_client -- cat /tmp/wrk.log
    local rc=$(kubectl exec $ubuntu_client -- cat /tmp/wrk.rc)
    echo "[run.sh] Test finished with status $rc"
    return $rc
}

populate() {
    local ubuntu_client=$(kubectl get pod | grep ubuntu-client- | cut -f 1 -d " ")
    local benchmark=$1
    if [[ $benchmark == "hotel" || $benchmark == "movie" ]]; then
        echo "[run.sh] Copying ../k8s/$benchmark/analysis.txt to $ubuntu_client:/analysis.txt"
        kubectl cp ../k8s/$benchmark/data/analysis.txt $ubuntu_client:/analysis.txt
        echo "[run.sh] Finished populating $benchmark"
        return
    fi
    echo "[run.sh] Populating social benchmark"
    bash ../k8s/$benchmark/populate.sh
    echo "[run.sh] Copying ../k8s/$benchmark/data/analysis.txt to $ubuntu_client:/analysis.txt"
    kubectl cp ../k8s/$benchmark/data/analysis.txt $ubuntu_client:/analysis.txt
    echo "[run.sh] Finished populating $benchmark"
}

# ---- client pod: request-mix ConfigMap + the (possibly new) image ----------
# The Lua request mixes live in this repo (../client/lua/) and reach the pod
# via the wrk-scripts ConfigMap mounted at /lua — edit a mix, re-run, no image
# rebuild. Applied unconditionally so an edited mix or a bumped CLIENT_IMAGE
# actually rolls out (the old "deploy only if missing" kept stale pods forever).
# LUA_HASH is baked into the pod template as an annotation: a mounted ConfigMap
# only propagates on the kubelet's periodic sync (up to ~60-90s), and wrk2
# reads the script once at startup — without the annotation an edited mix could
# silently miss the whole run. Changing the hash changes the template, which
# forces a real rollout that `rollout status` then actually waits on.
export LUA_HASH="none"
if [[ -d ../client/lua ]]; then
    kubectl create configmap wrk-scripts --from-file=../client/lua/ \
        --dry-run=client -o yaml | kubectl apply -f -
    export LUA_HASH="$(cat ../client/lua/*.lua 2>/dev/null | md5sum | cut -d' ' -f1)"
fi
# envsubst restricted to these vars so any future $… token in the yaml is
# not silently blanked.
envsubst '${CLIENT_IMAGE} ${LUA_HASH}' < ../client/client.yaml | kubectl apply -f -
if ! kubectl rollout status deploy/ubuntu-client --timeout=300s; then
    echo "[run.sh] ubuntu-client rollout failed" >&2
    exit 1
fi

# Wait for every pod to be running and fully ready, bounded: a pod that never
# comes up must fail the run, not hang it forever. Completed/Succeeded pods
# (one-shot jobs, debug pods) are terminal and excluded from both checks.
echo "[run.sh] Waiting for all pods to be running"
READY_DEADLINE=$(( $(date +%s) + 600 ))
while [[ $(kubectl get pods --no-headers | awk '$3!="Completed" && $3!="Succeeded" && $3!="Running" {print}' | wc -l) -ne 0 ]]; do
  if [[ $(date +%s) -gt $READY_DEADLINE ]]; then
      echo "[run.sh] pods still not Running after 600s:" >&2
      kubectl get pods >&2
      exit 1
  fi
  sleep 1
done
# Ready when the READY column is N/N for every non-terminal pod. Comparing the
# two counts (instead of matching the literal '1/1') keeps this working when
# Istio sidecar injection makes the benchmark pods 2/2.
while [[ $(kubectl get pods --no-headers | awk '$3!="Completed" && $3!="Succeeded" {split($2,a,"/"); if (a[1]!=a[2]) print}' | wc -l) -ne 0 ]]; do
  if [[ $(date +%s) -gt $READY_DEADLINE ]]; then
      echo "[run.sh] pods still not Ready after 600s:" >&2
      kubectl get pods >&2
      exit 1
  fi
  sleep 1
done
echo "[run.sh] All pods are running"


# The synthetic mesh emulator (chain-*/synthetic) has no /heartbeat endpoint;
# its readiness probe on / already gates the pods Ready above.
if [[ $benchmark != "mutex" && $benchmark != "synthetic" && $benchmark != chain-* ]]; then
    check_connectivity_all
fi


if [[ $benchmark == "hotel" || $benchmark == "movie" || $benchmark == "social" ]]; then
    populate $benchmark
fi

echo "[run.sh] Warmup: sleeping ${WARMUP_S}s before starting the load"
sleep "${WARMUP_S}"

start_load $benchmark || exit 1

if [[ "${LOAD_MODE}" == "detach" ]]; then
    exit 0
fi
wait_load
exit $?
