#!/bin/bash

cd $(dirname $0)

benchmark=${1:-boutique}
request=${2:-mix}
thread=${3:-16}
conn=${4:-512}
duration=${5:-10}

YAML_PATH=../k8s/$benchmark/yamls
if [[ $benchmark == "synthetic" ]]; then
    YAML_PATH=../k8s/$request/yamls
fi

supported_benchmarks=("boutique" "social" "movie" "hotel" "synthetic" "mutex")

echo "$YAML_PATH"
check_benchmark_supported() {
    local benchmark=$1
    for b in "${supported_benchmarks[@]}"; do
        if [[ $b == $benchmark ]]; then
            return 0
        fi
    done
    return 1
}

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

run_test() {
    local benchmark=$1
    local ubuntu_client=$(kubectl get pod | grep ubuntu-client- | cut -f 1 -d " ") 

    if [[ $benchmark != "boutique" && $benchmark != "synthetic" ]]; then
        echo "[run.sh] Starting the rust proxy first for $benchmark"
        kubectl exec $ubuntu_client -- bash -c "/mucache/proxy/target/release/proxy ${benchmark} >/tmp/proxy.log 2>&1 &"
        sleep 3
        kubectl exec $ubuntu_client -- cat /tmp/proxy.log
    fi

    echo "[run.sh] Running the test"
    sleep 10
    if [[ $benchmark == "boutique" ]]; then
        echo "[run.sh] /wrk/wrk --timeout 20s -t${thread} -c${conn} -d${duration}s -L -s /wrk/scripts/online-boutique/${request}.lua http://frontend:80"
        kubectl exec $ubuntu_client -- /wrk/wrk --timeout 20s -t${thread} -c${conn} -d${duration}s -L -s /wrk/scripts/online-boutique/${request}.lua http://frontend:80
    elif [[ $benchmark == "mutex" ]]; then
        echo "[run.sh] /wrk/wrk --timeout 20s -t${thread} -c${conn} -d${duration}s -L http://service1:80/"
        kubectl exec $ubuntu_client -- /wrk/wrk --timeout 20s -t${thread} -c${conn} -d${duration}s -L http://service1:80/
    elif [[ $benchmark == "synthetic" ]]; then
        echo "[run.sh] /wrk/wrk --timeout 20s -t${thread} -c${conn} -d${duration}s -L http://service0:80/endpoint1"
        # kubectl exec $ubuntu_client -- /wrk/wrk --timeout 20s -t${thread} -c${conn} -d20s -L http://service0:80/endpoint1
        kubectl exec $ubuntu_client -- /wrk/wrk --timeout 20s -t${thread} -c${conn} -d${duration}s -L http://service0:80/endpoint1
    else
        echo "[run.sh] /wrk/wrk --timeout 20s -t${thread} -c${conn} -d${duration}s -L http://localhost:3000"
        kubectl exec $ubuntu_client -- /wrk/wrk --timeout 20s -t${thread} -c${conn} -d${duration}s -L http://localhost:3000
    fi
}

populate() {
    local ubuntu_client=$(kubectl get pod | grep ubuntu-client- | cut -f 1 -d " ") 
    local benchmark=$1
    if [[ $benchmark == "boutique" ]]; then
        echo "[run.sh] No population needed for $benchmark"
        return
    fi
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

check_benchmark_supported $benchmark
if [ $? -ne 0 ]; then
    echo "[run.sh] Benchmark $benchmark is not supported"
    exit 1
fi

kubectl get pod | grep ubuntu-client- 
if [ $? -ne 0 ]
then
    echo "[run.sh] Client pod not found, deploying client"
    envsubst < ../client/client.yaml | kubectl apply -f -
fi

# wait until all pods are ready by checking the log to see if the "server started" message is printed
echo "[run.sh] Waiting for all pods to be running"
while [[ $(kubectl get pods | grep -v -E 'Running|Completed|STATUS' | wc -l) -ne 0 ]]; do
  sleep 1
done
# Ready when the READY column is N/N for every pod. Comparing the two counts
# (instead of matching the literal '1/1') keeps this working when Istio sidecar
# injection makes the benchmark pods 2/2.
while [[ $(kubectl get pods --no-headers | awk '{split($2,a,"/"); if (a[1]!=a[2]) print}' | wc -l) -ne 0 ]]; do
  sleep 1
done
echo "[run.sh] All pods are running"


if [[ $benchmark != "mutex" ]]; then
    check_connectivity_all
fi


if [[ $benchmark != "synthetic" && $benchmark != "mutex" ]]; then
    populate $benchmark
fi

sleep 5

run_test $benchmark &
pid=$!

# sleep 0.9*duration
sleep $(echo "$duration*0.8" | bc -l)
echo "[run.sh] Checking the resource usage"
kubectl top pods

wait $pid
status=$?
echo "[run.sh] Test finished with status $status"
exit $status
