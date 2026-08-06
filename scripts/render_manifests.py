#!/usr/bin/env python3
"""Render a benchmark's k8s manifests for an experiment spec.

Reads k8s/<bench>/yamls/*.yaml (the checked-in n=4, replicas=1 reference),
patches placement and replica counts, and writes a fully resolved copy of the
benchmark directory into build/<name>/ plus:

    resolved.json   every knob after defaulting + the placement map (provenance;
                    run_and_collect.sh copies it into each run dir)
    spec.env        SPEC_* shell variables for deploy.sh to source

Placement rule (matches k8s/*/PLACEMENT.md): the entry service first, then the
remaining Deployments in yamls/ filename order, round-robin over worker
node-index 1..workers. A benchmark whose checked-in layout predates the rule
pins it verbatim in bench.yaml `pinned_layouts` (boutique), used whenever the
requested worker count has an entry there.

Replicas: m == 1 keeps today's single pinned Deployment. m > 1 becomes m
single-replica Deployments `<name>-1..m`, replica r pinned to node-index
((home-1 + r-1) % workers) + 1 — fully deterministic pod->node placement. The
pod template keeps its original labels (the Service still selects all replicas)
plus `ubench.io/replica-slot`, which is also added to the Deployment selector so
the m Deployments never select each other's pods.

chain-* ConfigMaps carry ${PROCESSING_TIME_SERVICEi} placeholders; they are
substituted here (values from gen_processing_time.py, seeded by the spec) so the
build output is fully concrete and `kubectl apply -f` works without envsubst.
"""
from __future__ import annotations

import argparse
import copy
import json
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("render_manifests.py needs PyYAML: pip install pyyaml "
             "(or apt install python3-yaml)")

REPO_ROOT = Path(__file__).resolve().parent.parent
K8S_DIR = REPO_ROOT / "k8s"
BUILD_DIR = REPO_ROOT / "build"
SLOT_LABEL = "ubench.io/replica-slot"
NODE_INDEX_LABEL = "ubench.io/node-index"
BENCH_LABEL = "ubench.io/bench"

SPEC_DEFAULTS = {
    "request": None,          # falls back to bench.yaml default_request
    "workers": 4,
    "replicas": {"default": 1, "overrides": {}},
    "load": {"threads": 4, "conns": 16, "rate": 1000},
    "total_duration_s": 60,
    "segment_s": None,        # falls back to total_duration_s (one segment)
    "seed": 42,
}


def fail(msg: str) -> None:
    sys.exit(f"[render_manifests] error: {msg}")


def load_spec(args: argparse.Namespace) -> dict:
    if args.spec:
        spec_path = Path(args.spec)
        if not spec_path.exists():
            fail(f"spec file not found: {spec_path}")
        with open(spec_path) as f:
            spec = yaml.safe_load(f) or {}
        if not isinstance(spec, dict):
            fail(f"{spec_path} is not a YAML mapping")
        spec.setdefault("name", spec_path.stem)
    else:
        if not args.bench:
            fail("either --spec or --bench is required")
        spec = {"benchmark": args.bench, "name": args.name or args.bench}
    # CLI flags override spec values (deploy.sh env overrides happen later, in
    # deploy.sh itself; these flags exist for the no-spec path and check_render).
    for key, val in (("workers", args.workers), ("request", args.request),
                     ("total_duration_s", args.total_duration_s),
                     ("segment_s", args.segment_s), ("seed", args.seed)):
        if val is not None:
            spec[key] = val
    if args.replicas_default is not None:
        spec.setdefault("replicas", {})["default"] = args.replicas_default
    for item in args.replicas or []:
        name, _, m = item.partition("=")
        if not m.isdigit():
            fail(f"--replicas expects name=count, got '{item}'")
        spec.setdefault("replicas", {}).setdefault("overrides", {})[name] = int(m)
    return spec


def resolve_spec(spec: dict, bench_meta: dict) -> dict:
    """Fill defaults and validate. Returns a flat, fully explicit spec."""
    out = {"name": spec["name"], "benchmark": spec["benchmark"]}
    if not re.fullmatch(r"[A-Za-z0-9._-]+", str(out["name"])):
        fail(f"experiment name '{out['name']}' must match [A-Za-z0-9._-]+ "
             "(it becomes a directory name and a shell-quoted value)")
    out["request"] = spec.get("request") or bench_meta.get("default_request", "mix")
    out["workers"] = int(spec.get("workers") or SPEC_DEFAULTS["workers"])

    reps = spec.get("replicas") or {}
    out["replicas_default"] = int(reps.get("default", 1))
    out["replicas_overrides"] = {k: int(v) for k, v in
                                 (reps.get("overrides") or {}).items()}

    load = {**SPEC_DEFAULTS["load"], **(spec.get("load") or {})}
    out["threads"], out["conns"], out["rate"] = \
        int(load["threads"]), int(load["conns"]), int(load["rate"])

    out["total_duration_s"] = int(spec.get("total_duration_s")
                                  or SPEC_DEFAULTS["total_duration_s"])
    out["segment_s"] = int(spec.get("segment_s") or out["total_duration_s"])
    out["seed"] = int(spec.get("seed", SPEC_DEFAULTS["seed"]))

    if out["workers"] < 1:
        fail("workers must be >= 1")
    if out["replicas_default"] < 1 or any(m < 1 for m in
                                          out["replicas_overrides"].values()):
        fail("replica counts must be >= 1")
    if out["rate"] < 1:
        fail("load.rate must be a positive integer (wrk2 is open-loop; "
             "there is no unthrottled mode)")
    if out["conns"] < out["threads"]:
        fail(f"load.conns ({out['conns']}) must be >= load.threads "
             f"({out['threads']}) — wrk2 splits connections over threads")
    if out["segment_s"] > out["total_duration_s"]:
        fail("segment_s must be <= total_duration_s")
    if out["segment_s"] < 30:
        fail("segment_s < 30s gives collectors no room; use >= 30")
    return out


def load_bench_meta(bench: str) -> dict:
    bench_dir = K8S_DIR / bench
    if not (bench_dir / "yamls").is_dir():
        avail = ", ".join(sorted(p.name for p in K8S_DIR.iterdir() if p.is_dir()))
        fail(f"no manifests at k8s/{bench}/yamls (available: {avail})")
    meta_path = bench_dir / "bench.yaml"
    if not meta_path.exists():
        fail(f"missing k8s/{bench}/bench.yaml (entry_service etc.)")
    with open(meta_path) as f:
        return yaml.safe_load(f) or {}


def processing_time_env(topology: str, seed: int) -> dict[str, str]:
    """Run gen_processing_time.py and parse its `export K=V` stdout lines."""
    proc = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "gen_processing_time.py"),
         topology, str(seed)],
        capture_output=True, text=True)
    if proc.returncode != 0:
        fail(f"gen_processing_time.py {topology} {seed} failed:\n{proc.stderr}")
    env = {}
    for line in proc.stdout.splitlines():
        m = re.match(r"export\s+(\w+)=(\S+)", line)
        if m:
            env[m.group(1)] = m.group(2)
    if not env:
        fail(f"gen_processing_time.py produced no export lines for {topology}")
    return env


def substitute_placeholders(text: str, env: dict[str, str], fname: str) -> str:
    def repl(m: re.Match) -> str:
        key = m.group(1)
        if key not in env:
            fail(f"{fname}: no value for ${{{key}}} "
                 f"(gen_processing_time.py produced: {sorted(env)})")
        return env[key]
    return re.sub(r"\$\{(\w+)\}", repl, text)


def stamp_ownership(doc: dict, bench: str) -> None:
    """Label every rendered object ubench.io/bench=<bench>. Benchmarks share
    object names (every one has a `frontend`), so deploy.sh uses this label to
    tear down a previously deployed different benchmark instead of silently
    mutating its objects in place, and to scope its rollout wait + heartbeat
    sweep to the current benchmark. Selectors are NOT touched."""
    doc.setdefault("metadata", {}).setdefault("labels", {})[BENCH_LABEL] = bench
    if doc.get("kind") == "Deployment":
        doc["spec"]["template"].setdefault("metadata", {}) \
            .setdefault("labels", {})[BENCH_LABEL] = bench


def deployment_names(docs: list) -> list[str]:
    return [d["metadata"]["name"] for d in docs
            if isinstance(d, dict) and d.get("kind") == "Deployment"]


def compute_placement(ordered: list[str], entry: str, workers: int,
                      pinned: dict | None) -> dict[str, int]:
    """service name -> home node-index."""
    if pinned:
        missing = set(ordered) - set(pinned)
        if missing:
            fail(f"pinned_layouts[{workers}] missing services: {sorted(missing)}")
        return {name: int(pinned[name]) for name in ordered}
    if entry not in ordered:
        fail(f"entry_service '{entry}' is not a Deployment in this benchmark "
             f"(found: {ordered})")
    order = [entry] + [s for s in ordered if s != entry]
    return {name: (i % workers) + 1 for i, name in enumerate(order)}


def patch_deployment(doc: dict, home: int, replicas: int, workers: int) -> list[dict]:
    """Return the doc(s) replacing this Deployment for the requested replicas."""
    name = doc["metadata"]["name"]
    tmpl_spec = doc["spec"]["template"]["spec"]
    if replicas == 1:
        doc["spec"]["replicas"] = 1
        tmpl_spec["nodeSelector"] = {NODE_INDEX_LABEL: str(home)}
        return [doc]
    out = []
    for r in range(1, replicas + 1):
        d = copy.deepcopy(doc)
        d["metadata"]["name"] = f"{name}-{r}"
        d["spec"]["replicas"] = 1
        slot = {SLOT_LABEL: str(r)}
        d["spec"].setdefault("selector", {}).setdefault("matchLabels", {}).update(slot)
        d["spec"]["template"].setdefault("metadata", {}) \
            .setdefault("labels", {}).update(slot)
        idx = ((home - 1) + (r - 1)) % workers + 1
        d["spec"]["template"]["spec"]["nodeSelector"] = {NODE_INDEX_LABEL: str(idx)}
        out.append(d)
    return out


def render(resolved: dict, bench_meta: dict, out_dir: Path) -> dict:
    """Write the rendered benchmark dir; return the placement map for provenance."""
    bench_dir = K8S_DIR / resolved["benchmark"]
    if out_dir.exists():
        shutil.rmtree(out_dir)
    shutil.copytree(bench_dir, out_dir)

    subst_env = None
    if bench_meta.get("synthetic_topology"):
        subst_env = processing_time_env(bench_meta["synthetic_topology"],
                                        resolved["seed"])

    yaml_files = sorted((out_dir / "yamls").glob("*.yaml"))
    parsed: list[tuple[Path, list]] = []
    ordered_services: list[str] = []
    for path in yaml_files:
        text = path.read_text()
        if subst_env is not None:
            text = substitute_placeholders(text, subst_env, path.name)
        docs = [d for d in yaml.safe_load_all(text) if d is not None]
        parsed.append((path, docs))
        ordered_services.extend(deployment_names(docs))

    known = set(ordered_services)
    for svc in resolved["replicas_overrides"]:
        if svc not in known:
            fail(f"replicas.overrides names unknown Deployment '{svc}' "
                 f"(this benchmark has: {sorted(known)})")

    entry = bench_meta.get("entry_service")
    pinned = (bench_meta.get("pinned_layouts") or {}).get(str(resolved["workers"]))
    placement = compute_placement(ordered_services, entry, resolved["workers"],
                                  pinned)

    warnings = []
    entry_reps = resolved["replicas_overrides"].get(
        entry, resolved["replicas_default"])
    if entry_reps > 1:
        warnings.append(
            f"entry service '{entry}' has {entry_reps} replicas: slots beyond 1 "
            "run off node-1, so part of the client->ingress traffic goes "
            "cross-node (deterministically).")

    replica_map = {}
    for path, docs in parsed:
        out_docs = []
        for doc in docs:
            if isinstance(doc, dict) and doc.get("kind") == "Deployment":
                name = doc["metadata"]["name"]
                m = resolved["replicas_overrides"].get(
                    name, resolved["replicas_default"])
                replica_map[name] = m
                out_docs.extend(patch_deployment(doc, placement[name], m,
                                                 resolved["workers"]))
            else:
                out_docs.append(doc)
        for doc in out_docs:
            if isinstance(doc, dict) and doc.get("kind"):
                stamp_ownership(doc, resolved["benchmark"])
        path.write_text(yaml.safe_dump_all(out_docs, sort_keys=False,
                                           default_flow_style=False))

    provenance = {
        **resolved,
        "kind": bench_meta.get("kind", "wrk-lua"),
        "entry_service": entry,
        "placement": placement,          # service -> home node-index
        "replicas": replica_map,         # service -> replica count
        "pinned_layout_used": bool(pinned),
        "warnings": warnings,
    }
    with open(out_dir / "resolved.json", "w") as f:
        json.dump(provenance, f, indent=2)

    env_lines = {
        "SPEC_NAME": resolved["name"],
        "SPEC_BENCH": resolved["benchmark"],
        "SPEC_KIND": bench_meta.get("kind", "wrk-lua"),
        "SPEC_REQUEST": resolved["request"],
        "SPEC_WORKERS": resolved["workers"],
        "SPEC_THREADS": resolved["threads"],
        "SPEC_CONNS": resolved["conns"],
        "SPEC_RATE": resolved["rate"],
        "SPEC_TOTAL_S": resolved["total_duration_s"],
        "SPEC_SEGMENT_S": resolved["segment_s"],
        "SPEC_SEED": resolved["seed"],
    }
    with open(out_dir / "spec.env", "w") as f:
        for k, v in env_lines.items():
            f.write(f'{k}="{v}"\n')
    return provenance


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--spec", help="experiments/<name>.yaml")
    ap.add_argument("--bench", help="benchmark name (no-spec path)")
    ap.add_argument("--name", help="output name under build/ (default: bench)")
    ap.add_argument("--workers", type=int)
    ap.add_argument("--request")
    ap.add_argument("--replicas-default", type=int, dest="replicas_default")
    ap.add_argument("--replicas", action="append", metavar="NAME=COUNT",
                    help="per-service replica override (repeatable)")
    ap.add_argument("--total-duration-s", type=int, dest="total_duration_s")
    ap.add_argument("--segment-s", type=int, dest="segment_s")
    ap.add_argument("--seed", type=int)
    ap.add_argument("--out", help="output dir (default build/<name>)")
    args = ap.parse_args()

    spec = load_spec(args)
    if "benchmark" not in spec:
        fail("spec is missing the required 'benchmark' key")
    bench_meta = load_bench_meta(spec["benchmark"])
    resolved = resolve_spec(spec, bench_meta)
    out_dir = Path(args.out) if args.out else BUILD_DIR / resolved["name"]

    provenance = render(resolved, bench_meta, out_dir)
    for w in provenance["warnings"]:
        print(f"[render_manifests] note: {w}", file=sys.stderr)
    scaled = {k: v for k, v in provenance["replicas"].items() if v > 1}
    print(f"[render_manifests] {resolved['benchmark']} -> {out_dir} "
          f"(workers={resolved['workers']}"
          f"{', scaled: ' + str(scaled) if scaled else ''})")
    # Last line is the build dir, so deploy.sh can locate it.
    print(out_dir)


if __name__ == "__main__":
    main()
