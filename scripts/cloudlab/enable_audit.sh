#!/bin/bash
#
# Enable (or revert) kube-apiserver audit logging on the CloudLab control node.
#
# The richest provenance signal for control-plane attacks (Stratus Red Team's
# k8s techniques: "list all secrets", "create a privileged pod", "create an
# admin clusterrole", "steal a service-account token", ...) lives in the
# kube-apiserver AUDIT LOG, which kubeadm does not enable by default. This script
# patches the static-pod manifest to turn it on, writing JSON audit events to
# /var/log/kubernetes/audit/ on node-0 (host path; the collector reads it there).
#
# It is idempotent and reversible:
#   * the manifest is backed up to /etc/kubernetes/audit-backup/ (OUTSIDE the
#     manifests dir — a backup inside it would be run as a second static pod) BEFORE
#     any edit, and `--revert` restores it,
#   * the editor is a no-op if the audit flags are already present,
#   * after every change it waits for the apiserver to come back healthy.
#
# Run from your dev box (same place you run bootstrap.sh / deploy.sh).
#
#   Usage:
#     ./enable_audit.sh           # enable audit logging (default)
#     ./enable_audit.sh status    # show whether it's on + tail the audit log
#     ./enable_audit.sh revert    # restore the pre-audit manifest
#
#   Env:
#     CONTROL_HOST=...   control node (default: 1st entry in nodes.sh)
#     SSH_USER=yuhang    ssh user
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/nodes.sh"
SSH_USER="${SSH_USER:-yuhang}"
MAIN="${CONTROL_HOST:-${NODES[0]:-}}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)

ACTION="${1:-enable}"

AUDIT_DIR="/var/log/kubernetes/audit"
AUDIT_LOG="${AUDIT_DIR}/kube-apiserver-audit.log"
POLICY_DST="/etc/kubernetes/audit-policy.yaml"
MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
BACKUP_DIR="/etc/kubernetes/audit-backup"

# Wait until the apiserver answers again after a static-pod restart.
remote_wait_apiserver() {
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" 'bash -s' <<'EOF'
echo -n "[*] waiting for kube-apiserver to come back "
for i in $(seq 1 60); do
	if kubectl get --raw=/readyz >/dev/null 2>&1; then echo " ok"; exit 0; fi
	echo -n "."; sleep 2
done
echo " TIMEOUT"; exit 1
EOF
}

case "${ACTION}" in
status)
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "bash -s" <<EOF
set -e
echo "=== audit flags in manifest ==="
sudo grep -E 'audit-' ${MANIFEST} 2>/dev/null || echo "(none — audit logging is OFF)"
echo
echo "=== audit log ==="
if sudo test -f ${AUDIT_LOG}; then
	echo "file: ${AUDIT_LOG}  size: \$(sudo du -h ${AUDIT_LOG} | cut -f1)  lines: \$(sudo cat ${AUDIT_LOG} | wc -l)"
	echo "--- last 2 events (resource + verb + user) ---"
	sudo tail -n 2 ${AUDIT_LOG} | python3 -c 'import sys,json
for l in sys.stdin:
    try: e=json.loads(l)
    except: continue
    o=e.get("objectRef",{})
    print(e.get("verb"), o.get("resource"), o.get("namespace",""), "by", e.get("user",{}).get("username"))'
else
	echo "(no audit log file yet at ${AUDIT_LOG})"
fi
EOF
	exit 0
	;;
revert)
	echo "[*] Reverting audit logging on ${MAIN}"
	ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "bash -s" <<EOF
set -e
LATEST=\$(sudo ls -1t ${BACKUP_DIR}/kube-apiserver.yaml.* 2>/dev/null | head -1 || true)
if [ -z "\${LATEST}" ]; then echo "[!] no backup found in ${BACKUP_DIR}" >&2; exit 1; fi
echo "[*] restoring \${LATEST} -> ${MANIFEST}"
sudo cp "\${LATEST}" ${MANIFEST}
EOF
	remote_wait_apiserver
	echo "[*] Audit logging reverted. (Audit logs left in place under ${AUDIT_DIR}.)"
	exit 0
	;;
enable) : ;;
*) echo "usage: $0 [enable|status|revert]" >&2; exit 1 ;;
esac

# --- enable -----------------------------------------------------------------
echo "[*] Copying audit policy to ${MAIN}"
scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/audit-policy.yaml" "${SSH_USER}@${MAIN}:/tmp/audit-policy.yaml"

echo "[*] Enabling kube-apiserver audit logging on ${MAIN}"
# The whole edit happens on the control node. The python block patches the
# manifest YAML in place (idempotent: it bails early if the flags already exist),
# adding the audit flags, the policy-file read-only mount, and the log-dir
# read-write mount + their hostPath volumes.
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "bash -s" <<EOF
set -e
sudo install -m 0600 /tmp/audit-policy.yaml ${POLICY_DST}
sudo mkdir -p ${AUDIT_DIR} ${BACKUP_DIR}

if sudo grep -q -- '--audit-policy-file' ${MANIFEST}; then
	echo "[=] audit flags already present; leaving manifest unchanged"
	exit 0
fi

STAMP=\$(date -u +%Y%m%d-%H%M%S)
sudo cp ${MANIFEST} ${BACKUP_DIR}/kube-apiserver.yaml.\${STAMP}
echo "[*] backed up manifest -> ${BACKUP_DIR}/kube-apiserver.yaml.\${STAMP}"

sudo python3 - ${MANIFEST} <<'PY'
import sys, yaml

path = sys.argv[1]
with open(path) as f:
    m = yaml.safe_load(f)

c = m["spec"]["containers"][0]

flags = [
    "--audit-policy-file=/etc/kubernetes/audit-policy.yaml",
    "--audit-log-path=/var/log/kubernetes/audit/kube-apiserver-audit.log",
    "--audit-log-format=json",
    "--audit-log-maxage=30",
    "--audit-log-maxbackup=10",
    "--audit-log-maxsize=200",
]
have = {a.split("=", 1)[0] for a in c["command"] if a.startswith("--")}
for fl in flags:
    if fl.split("=", 1)[0] not in have:
        c["command"].append(fl)

mounts = c.setdefault("volumeMounts", [])
mnames = {vm["name"] for vm in mounts}
if "audit-policy" not in mnames:
    mounts.append({"name": "audit-policy",
                   "mountPath": "/etc/kubernetes/audit-policy.yaml",
                   "readOnly": True})
if "audit-logs" not in mnames:
    mounts.append({"name": "audit-logs",
                   "mountPath": "/var/log/kubernetes/audit",
                   "readOnly": False})

vols = m["spec"].setdefault("volumes", [])
vnames = {v["name"] for v in vols}
if "audit-policy" not in vnames:
    vols.append({"name": "audit-policy",
                 "hostPath": {"path": "/etc/kubernetes/audit-policy.yaml",
                              "type": "File"}})
if "audit-logs" not in vnames:
    vols.append({"name": "audit-logs",
                 "hostPath": {"path": "/var/log/kubernetes/audit",
                              "type": "DirectoryOrCreate"}})

with open(path, "w") as f:
    yaml.safe_dump(m, f, sort_keys=False, default_flow_style=False)
print("[*] manifest patched with audit flags + mounts")
PY
EOF

# kubelet restarts the static pod automatically once the manifest mtime changes.
remote_wait_apiserver
echo
echo "[*] Audit logging enabled. Verifying the log is being written..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MAIN}" "bash -s" <<EOF
set -e
for i in \$(seq 1 15); do
	if sudo test -s ${AUDIT_LOG}; then
		echo "[+] audit log live: ${AUDIT_LOG} (\$(sudo cat ${AUDIT_LOG} | wc -l) events)"
		exit 0
	fi
	sleep 2
done
echo "[!] audit log not growing yet at ${AUDIT_LOG} — check 'enable_audit.sh status'" >&2
exit 1
EOF
echo "[*] Done. Audit events -> ${AUDIT_LOG} on ${MAIN}."
