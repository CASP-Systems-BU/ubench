#!/usr/bin/env bash
# Grant the flow-resolver (see kafka/flow_resolver.py) read-only access to
# the k8s API, and hand back a minimal, standalone kubeconfig it can use from
# a non-k8s host — the Kafka broker VMs are not cluster members (kafka.sh)
# and so have no kubelet credentials or in-cluster ServiceAccount mount of
# their own.
#
# Run ON node-0 (it already has ~/.kube/config from after_join.sh); kafka.sh
# invokes this over ssh and then copies the resulting kubeconfig out to each
# Kafka broker node. Safe to re-run — every object is created with
# --dry-run=client | kubectl apply, and the token Secret is left in place
# rather than recreated (so a re-run never invalidates kubeconfigs already
# distributed to brokers).
#
# Output: prints the kubeconfig to stdout. Nothing is written to disk here —
# the caller (kafka.sh) redirects it to wherever it needs to live.
set -euo pipefail

SA_NAME="flow-resolver"
SA_NAMESPACE="kube-system"
CLUSTERROLE_NAME="flow-resolver-read"
SECRET_NAME="${SA_NAME}-token"
CONTEXT_NAME="flow-resolver"

kubectl create serviceaccount "${SA_NAME}" -n "${SA_NAMESPACE}" \
	--dry-run=client -o yaml | kubectl apply -f - >&2

# get/list only — the resolver polls a point-in-time snapshot (see
# flow_resolver.py --refresh-interval-s); watch is granted too so a future
# move to an informer-based resolver needs no RBAC change.
cat <<EOF | kubectl apply -f - >&2
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CLUSTERROLE_NAME}
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
EOF

cat <<EOF | kubectl apply -f - >&2
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CLUSTERROLE_NAME}-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${CLUSTERROLE_NAME}
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${SA_NAMESPACE}
EOF

# A Secret-backed (non-expiring) token, not `kubectl create token` (which
# defaults to a 1h TTL meant for in-cluster use) — these VMs have no
# mechanism to refresh a short-lived token, and the topology is assumed
# mostly static for now (see flow_resolver.py docstring).
if ! kubectl get secret "${SECRET_NAME}" -n "${SA_NAMESPACE}" >/dev/null 2>&1; then
	cat <<EOF | kubectl apply -f - >&2
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${SA_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF
	# The token controller fills .data.token asynchronously after the Secret
	# is created; wait for it rather than racing the first read below.
	for _ in $(seq 1 20); do
		kubectl get secret "${SECRET_NAME}" -n "${SA_NAMESPACE}" \
			-o jsonpath='{.data.token}' 2>/dev/null | grep -q . && break
		sleep 1
	done
fi

TOKEN="$(kubectl get secret "${SECRET_NAME}" -n "${SA_NAMESPACE}" -o jsonpath='{.data.token}' | base64 -d)"
CA_CERT="$(kubectl get secret "${SECRET_NAME}" -n "${SA_NAMESPACE}" -o jsonpath='{.data.ca\.crt}')"
if [ -z "${TOKEN}" ] || [ -z "${CA_CERT}" ]; then
	echo "[!] token/CA not populated yet on secret ${SECRET_NAME} — re-run in a few seconds" >&2
	exit 1
fi

# node-0's own kubeconfig already points at a LAN-reachable API server
# address (brokers share the same 10.0.0.x network — see kafka.sh/README);
# reuse it instead of hardcoding node-0's IP here.
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

cat <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CONTEXT_NAME}
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_CERT}
contexts:
  - name: ${CONTEXT_NAME}
    context:
      cluster: ${CONTEXT_NAME}
      user: ${CONTEXT_NAME}
current-context: ${CONTEXT_NAME}
users:
  - name: ${CONTEXT_NAME}
    user:
      token: ${TOKEN}
EOF
