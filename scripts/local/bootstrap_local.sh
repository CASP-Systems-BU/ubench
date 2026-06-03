#!/bin/bash
#
# Passwordless SSH + NOPASSWD sudo for a self-hosted cluster.
#
# Run ONCE from the orchestrator (your laptop / a box that can reach all the
# nodes). Reads the node list from config.json and, using the shared login
# password, sets up exactly what setup_kube.py needs:
#   1. a passphrase-less SSH key on the orchestrator (shell_helper.py requires it)
#   2. that key pushed to every node            -> passwordless SSH
#   3. NOPASSWD sudo on every node              -> non-interactive sudo
#
# Prereqs: nodes run Ubuntu 22.04, share the same login user + password, and are
# reachable from here. Fill in the CHANGE_ME placeholders in config.json first.
#
# After it succeeds:   python3 setup_kube.py

set -euo pipefail

cd "$(dirname "$0")"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/id_ed25519}"

# --- read user + nodes from config.json ------------------------------------
USER_NAME="$(python3 -c "import json; print(json.load(open('config.json'))['nodes_user'])")"
mapfile -t NODES < <(python3 -c "import json; [print(n) for n in json.load(open('config.json'))['nodes']]")

if [[ "$USER_NAME" == CHANGE_ME* || "${NODES[0]}" == CHANGE_ME* ]]; then
    echo "[bootstrap_local] ERROR: fill in nodes_user and nodes[] in config.json first." >&2
    exit 1
fi

# --- shared password -------------------------------------------------------
PASSWORD="${PASSWORD:-}"
if [[ -z "$PASSWORD" ]]; then
    read -rsp "Shared SSH/sudo password for $USER_NAME on all nodes: " PASSWORD
    echo
fi

# --- 1. sshpass + key ------------------------------------------------------
if ! command -v sshpass >/dev/null 2>&1; then
    echo "[bootstrap_local] Installing sshpass on the orchestrator..."
    sudo apt-get update -yq && sudo apt-get install -yq sshpass
fi
if [[ ! -f "$KEY_PATH" ]]; then
    echo "[bootstrap_local] Generating passphrase-less SSH key at $KEY_PATH"
    ssh-keygen -t ed25519 -N "" -f "$KEY_PATH"
fi

SSH_OPTS="-o StrictHostKeyChecking=accept-new"

# --- 2 & 3. per node: push key + NOPASSWD sudo -----------------------------
for ip in "${NODES[@]}"; do
    echo "[bootstrap_local] === $ip ==="
    echo "[bootstrap_local]   pushing public key"
    sshpass -p "$PASSWORD" ssh-copy-id $SSH_OPTS -i "${KEY_PATH}.pub" "$USER_NAME@$ip"
    echo "[bootstrap_local]   enabling NOPASSWD sudo"
    sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USER_NAME@$ip" \
        "echo '$PASSWORD' | sudo -S sh -c \"echo '$USER_NAME ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-nopasswd && chmod 440 /etc/sudoers.d/90-nopasswd\""
done

# --- 4. verify (must not prompt for any password) --------------------------
echo "[bootstrap_local] Verifying passwordless SSH + sudo..."
fail=0
for ip in "${NODES[@]}"; do
    who=$(ssh -o BatchMode=yes $SSH_OPTS "$USER_NAME@$ip" "sudo whoami" 2>/dev/null || true)
    if [[ "$who" == "root" ]]; then echo "  OK   $ip"; else echo "  FAIL $ip (got '$who')"; fail=1; fi
done
[[ $fail -eq 0 ]] || { echo "[bootstrap_local] Some nodes failed; fix before setup_kube.py." >&2; exit 1; }

echo "[bootstrap_local] Done. Next:  python3 setup_kube.py"
