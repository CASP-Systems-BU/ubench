#!/bin/bash
#
# DEPRECATED for the CloudLab pipeline: scripts/cloudlab/deploy.sh renders the
# ${PROCESSING_TIME_*} placeholders at render time (scripts/render_manifests.py,
# seeded via the experiment spec) — no envsubst step needed. This script remains
# for direct/manual applies only.

cd $(dirname $0)

random_seed=42
temp_env=$(mktemp)
python3 ../../scripts/gen_processing_time.py chain-d8 $random_seed > "$temp_env"
source "$temp_env"
cat "$temp_env"
rm -f "$temp_env"

for file in $(ls yamls/*.yaml); do
    envsubst < $file | kubectl apply -f -
done
