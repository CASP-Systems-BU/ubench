#!/bin/bash
#
# One-shot CloudLab cluster setup: paste node hostnames in below, then run.
#
# After instantiating an experiment in the CloudLab UI, grab the public
# hostnames from the List View (node-0 first — it becomes the control plane),
# paste them into HOSTS below, then run:
#
#   ./setup.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- paste your CloudLab node hostnames here, node-0 (control plane) first ---
HOSTS=(
	"pc546.emulab.net"
	"pc442.emulab.net"
	"pc557.emulab.net"
	"pc529.emulab.net"
	"pc537.emulab.net"
)
# -------------------------------------------------------------------------

python3 "${SCRIPT_DIR}/register_cluster.py" "${HOSTS[@]}" --ip-base 10.0.0.1
"${SCRIPT_DIR}/bootstrap.sh"
