#!/bin/bash
#
# Offline validation gate for the experiment pipeline — no cluster needed.
#
#   * bash -n / py_compile (and shellcheck, if installed) on the pipeline scripts
#   * golden check: rendering every benchmark at workers=4 / replicas=1 must
#     reproduce the checked-in placement exactly (proves the default path is
#     a no-op, boutique via its pinned layout)
#   * structural checks across workers x replica cases: per-replica Deployments
#     carry the slot label in selector+template, selectors are disjoint, node
#     pinning follows the round-robin formula, no ${...} placeholders survive
#
# Run from anywhere: ./scripts/check_render.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FAIL=0
note() { echo "[check_render] $*"; }
bad()  { echo "[check_render] FAIL: $*" >&2; FAIL=1; }

note "syntax checks"
for f in scripts/run.sh scripts/run_and_collect.sh scripts/check_render.sh \
         scripts/cloudlab/deploy.sh scripts/cloudlab/bootstrap.sh; do
    bash -n "$f" || bad "bash -n $f"
done
for f in scripts/render_manifests.py scripts/collect_metrics.py \
         scripts/cloudlab/register_cluster.py; do
    [ -f "$f" ] && { python3 -m py_compile "$f" || bad "py_compile $f"; }
done
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S error scripts/run.sh scripts/run_and_collect.sh \
        scripts/cloudlab/deploy.sh scripts/cloudlab/bootstrap.sh \
        || bad "shellcheck"
else
    note "shellcheck not installed; skipping"
fi

note "render + placement checks (this can take a few seconds)"
python3 - <<'EOF' || FAIL=1
import json, subprocess, sys
from pathlib import Path
import yaml

BENCHES = ["boutique", "hotel", "movie", "social",
           "chain-d2-http-sync", "chain-d8-http-sync"]
SLOT = "ubench.io/replica-slot"
IDX = "ubench.io/node-index"
fail = 0

def bad(msg):
    global fail
    print(f"[check_render] FAIL: {msg}", file=sys.stderr)
    fail = 1

def render(bench, name, extra=()):
    cmd = [sys.executable, "scripts/render_manifests.py", "--bench", bench,
           "--name", name, *extra]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        bad(f"render failed: {' '.join(cmd)}\n{p.stderr}")
        return None
    return Path("build") / name

def deployments(yamls_dir):
    """{deployment name: doc}, plus doc order per sorted filename."""
    out = {}
    for path in sorted(Path(yamls_dir).glob("*.yaml")):
        for doc in yaml.safe_load_all(path.read_text()):
            if isinstance(doc, dict) and doc.get("kind") == "Deployment":
                out[doc["metadata"]["name"]] = doc
    return out

def node_index(doc):
    return doc["spec"]["template"]["spec"].get("nodeSelector", {}).get(IDX)

# --- golden: workers=4, replicas=1 must equal the checked-in manifests -------
for bench in BENCHES:
    build = render(bench, f"_check_{bench}")
    if build is None:
        continue
    src = deployments(Path("k8s") / bench / "yamls")
    ren = deployments(build / "yamls")
    if set(src) != set(ren):
        bad(f"{bench}: deployment set changed: {set(src) ^ set(ren)}")
        continue
    for name in src:
        if node_index(src[name]) != node_index(ren[name]):
            bad(f"{bench}/{name}: golden nodeSelector {node_index(src[name])} "
                f"-> {node_index(ren[name])}")
        if ren[name]["spec"].get("replicas") != 1:
            bad(f"{bench}/{name}: golden replicas != 1")
    text = "".join(p.read_text() for p in (build / "yamls").glob("*.yaml"))
    if "${" in text:
        bad(f"{bench}: unsubstituted placeholder survives in build output")

# --- structural: workers x replica cases -------------------------------------
for bench in BENCHES:
    meta = yaml.safe_load((Path("k8s") / bench / "bench.yaml").read_text())
    entry = meta["entry_service"]
    src_names = list(deployments(Path("k8s") / bench / "yamls"))
    backend = next(n for n in src_names if n != entry)
    for workers in (1, 2, 4, 6):
        build = render(bench, f"_check_{bench}_w{workers}",
                       ("--workers", str(workers),
                        "--replicas", f"{entry}=3", "--replicas", f"{backend}=2"))
        if build is None:
            continue
        ren = deployments(build / "yamls")
        prov = json.loads((build / "resolved.json").read_text())
        placement = prov["placement"]
        for name, m in ((entry, 3), (backend, 2)):
            home = placement[name]
            slots = [f"{name}-{r}" for r in range(1, m + 1)]
            if any(s not in ren for s in slots) or name in ren:
                bad(f"{bench} w={workers} {name}: expected {slots}, "
                    f"got {[k for k in ren if k.startswith(name)]}")
                continue
            sels = []
            for r, s in enumerate(slots, start=1):
                d = ren[s]
                sel = d["spec"]["selector"]["matchLabels"]
                lbl = d["spec"]["template"]["metadata"]["labels"]
                if sel.get(SLOT) != str(r) or lbl.get(SLOT) != str(r):
                    bad(f"{bench} w={workers} {s}: slot label missing/wrong")
                sels.append(tuple(sorted(sel.items())))
                want = ((home - 1) + (r - 1)) % workers + 1
                if node_index(d) != str(want):
                    bad(f"{bench} w={workers} {s}: node {node_index(d)} != {want}")
                if d["spec"].get("replicas") != 1:
                    bad(f"{bench} w={workers} {s}: replicas != 1")
            if len(set(sels)) != len(sels):
                bad(f"{bench} w={workers} {name}: selectors not disjoint")
        for name, doc in ren.items():
            base = name.rsplit("-", 1)[0] if name.rsplit("-", 1)[-1].isdigit() \
                else name
            if base not in (entry, backend):
                idx = node_index(doc)
                if idx != str(placement[name]):
                    bad(f"{bench} w={workers} {name}: node {idx} != "
                        f"{placement[name]}")
                if int(idx) > workers:
                    bad(f"{bench} w={workers} {name}: index {idx} > workers")

sys.exit(fail)
EOF

if [ "${FAIL}" -eq 0 ]; then
    note "OK — all checks passed"
else
    note "FAILED — see messages above"
fi
exit "${FAIL}"
