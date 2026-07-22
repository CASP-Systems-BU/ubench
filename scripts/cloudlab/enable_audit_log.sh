#!/bin/bash
#
# Enable kube-apiserver audit logging. Runs on the MAIN node (it hosts
# /etc/kubernetes/manifests). setup_kube.py executes this, gated by
# "enable_audit_log" in config.json (default off). Idempotent.
#
# What it does:
#   1. writes an audit policy to /etc/kubernetes/audit-policy.yaml
#      (Metadata level for everything except known control-plane noise)
#   2. patches the kube-apiserver static-pod manifest with the audit flags
#      and hostPath mounts (structural PyYAML edit, atomic swap)
#   3. waits for the apiserver to come back and verifies events are flowing
#
# NOTE: patching the static-pod manifest RESTARTS the apiserver (~30-60s);
# this script blocks until it is back and /var/log/kubernetes/audit/audit.log
# is non-empty. The policy file is read only at apiserver startup — if you
# later edit the POLICY CONTENT, force a restart (e.g. temporarily move the
# manifest out of /etc/kubernetes/manifests for ~20s and back).
#
# Rollback: sudo cp /etc/kubernetes/kube-apiserver.yaml.pre-audit.bak \
#                   /etc/kubernetes/manifests/kube-apiserver.yaml

set -euo pipefail

POLICY=/etc/kubernetes/audit-policy.yaml
MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
LOG_DIR=/var/log/kubernetes/audit

# PyYAML for the manifest edit (present on CloudLab Ubuntu 22.04; guard anyway).
python3 -c 'import yaml' 2>/dev/null || sudo apt-get install -yq python3-yaml

# --- 1. audit policy (rewritten every run; content is deterministic) --------
sudo mkdir -p "$LOG_DIR"
sudo tee "$POLICY" >/dev/null <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
# One event per request at its final stage; RequestReceived would double every
# event without adding information.
omitStages:
  - "RequestReceived"
rules:
  # -- noise suppression ------------------------------------------------------
  - level: None
    users: ["system:kube-proxy", "system:apiserver"]
  - level: None
    resources:
      - group: "coordination.k8s.io"
        resources: ["leases"]          # node/controller heartbeats, ~10/s
  - level: None
    resources:
      - group: ""
        resources: ["events"]
  - level: None
    nonResourceURLs: ["/healthz*", "/readyz*", "/livez*", "/metrics", "/version"]
  # -- everything else: who did what to which object, from where ---------------
  - level: Metadata                    # verb, user, objectRef, sourceIPs, status
EOF

# --- 2. patch the static-pod manifest (only once) ----------------------------
if sudo grep -q -- '--audit-policy-file=' "$MANIFEST"; then
    echo "[enable_audit_log] manifest already patched, skipping"
else
    sudo cp "$MANIFEST" /etc/kubernetes/kube-apiserver.yaml.pre-audit.bak
    sudo python3 - "$MANIFEST" <<'PYEOF'
import os, sys, yaml

path = sys.argv[1]
with open(path) as f:
    doc = yaml.safe_load(f)

c = doc["spec"]["containers"][0]
c["command"] += [
    "--audit-policy-file=/etc/kubernetes/audit-policy.yaml",
    "--audit-log-path=/var/log/kubernetes/audit/audit.log",
    "--audit-log-maxage=7",
    "--audit-log-maxbackup=4",
    "--audit-log-maxsize=100",
]
c.setdefault("volumeMounts", []).extend([
    {"name": "audit-policy",
     "mountPath": "/etc/kubernetes/audit-policy.yaml", "readOnly": True},
    {"name": "audit-log",
     "mountPath": "/var/log/kubernetes/audit"},
])
doc["spec"].setdefault("volumes", []).extend([
    {"name": "audit-policy",
     "hostPath": {"path": "/etc/kubernetes/audit-policy.yaml", "type": "File"}},
    {"name": "audit-log",
     "hostPath": {"path": "/var/log/kubernetes/audit", "type": "DirectoryOrCreate"}},
])

# Write the temp file OUTSIDE /etc/kubernetes/manifests: kubelet watches that
# dir and would try to run a half-written pod spec. os.replace on the same
# filesystem is an atomic swap into the watched dir.
tmp = "/etc/kubernetes/.kube-apiserver.yaml.tmp"
with open(tmp, "w") as f:
    yaml.safe_dump(doc, f, default_flow_style=False)
os.replace(tmp, path)
PYEOF
    echo "[enable_audit_log] manifest patched; kubelet is restarting the apiserver"
fi

# --- 3. wait for the apiserver + verify audit is flowing ---------------------
sleep 10   # give kubelet time to notice the changed manifest
ok=0
for _ in $(seq 1 60); do
    kubectl get --raw /readyz >/dev/null 2>&1 && { ok=1; break; }
    sleep 3
done
if [ "$ok" -ne 1 ]; then
    echo "[enable_audit_log] ERROR: apiserver not back after 180s" >&2
    echo "[enable_audit_log] rollback: sudo cp /etc/kubernetes/kube-apiserver.yaml.pre-audit.bak $MANIFEST" >&2
    exit 1
fi
for _ in $(seq 1 30); do
    # a non-empty audit.log proves the new flags actually took effect
    if sudo test -s "$LOG_DIR/audit.log"; then
        echo "[enable_audit_log] audit events flowing -> $LOG_DIR/audit.log"
        exit 0
    fi
    sleep 2
done
echo "[enable_audit_log] ERROR: apiserver up but audit.log still empty — check flags" >&2
exit 1
