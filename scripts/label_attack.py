#!/usr/bin/env python3
"""
Label a captured attack run as benign / malicious — the dataset payoff.

Reads a run directory produced by attack_and_collect.sh (which contains
attack/attack.json = the ground truth: attacker namespaces, pod IPs, and per
technique time windows) and tags each record in the captured provenance sources:

  * audit/events.jsonl   -> audit/events_labeled.jsonl     (control-plane)
  * cilium/flows.jsonl   -> cilium/flows_labeled.jsonl      (L3/L4 network)
  * istio/access_logs/*  -> (scanned; IP-based)             (L7 HTTP)

and writes labels_summary.json at the run root. This mirrors AssureMOSS's
labeling recipe (label by attacker identity + attack timestamps), adapted to our
richer sources: we label by attacker *namespace* and *pod IP* (exact, not just
subnet) and, for control-plane read/RBAC techniques that create no pod, by the
per-technique audit signature within the technique's time window.

Pure post-processing; safe to re-run. Runs on the control node or the host.
"""
import argparse
import json
import os

# Per-technique audit signature for techniques whose detonation does NOT create a
# resource in the stratus-red-team namespace (those are caught precisely by the
# namespace rule). Each signature matches (verb, resource, optional subresource,
# optional cluster_scoped) AND must be performed by the attacker identity — this
# user gate is what keeps benign control-plane churn that happens to fall in the
# attack window (e.g. kiali's `create pods/portforward`, kubelet's
# `create serviceaccounts/token`) out of the malicious set.
AUDIT_SIGNATURES = {
    "k8s.credential-access.dump-secrets": [
        {"verb": "list", "resource": "secrets", "cluster_scoped": True},
    ],
    "k8s.persistence.create-admin-clusterrole": [
        {"verb": "create", "resource": "clusterroles"},
        {"verb": "create", "resource": "clusterrolebindings"},
    ],
    "k8s.persistence.create-client-certificate": [
        {"verb": "create", "resource": "certificatesigningrequests"},
        {"verb": "update", "resource": "certificatesigningrequests",
         "subresource": "approval"},
    ],
    "k8s.persistence.create-token": [
        {"verb": "create", "resource": "serviceaccounts", "subresource": "token"},
    ],
    "k8s.privilege-escalation.nodes-proxy": [
        {"verb": "get", "resource": "nodes", "subresource": "proxy"},
        {"verb": "create", "resource": "nodes", "subresource": "proxy"},
    ],
}


def _ts_epoch(ts):
    import datetime
    if not ts:
        return None
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    if "." in ts:
        head, _, tail = ts.partition(".")
        frac, sign, off = tail.partition("+") if "+" in tail else (tail, "", "")
        ts = f"{head}.{frac[:6]}{sign}{off}"
    try:
        return datetime.datetime.fromisoformat(ts).timestamp()
    except ValueError:
        return None


def label_audit(run_dir, attack, ns_prefix):
    src = os.path.join(run_dir, "audit", "events.jsonl")
    if not os.path.exists(src):
        return None
    techs = attack.get("techniques", [])
    windows = [(t["id"], t["ts_start_epoch"], t["ts_end_epoch"]) for t in techs]
    attacker_user = attack.get("attacker_user", "kubernetes-admin")

    out = []
    n_mal = 0
    by_tech = {}
    for line in open(src):
        line = line.strip()
        if not line:
            continue
        ev = json.loads(line)
        o = ev.get("objectRef", {}) or {}
        verb = ev.get("verb", "")
        res = o.get("resource", "")
        sub = o.get("subresource", "") or ""
        ns = o.get("namespace", "") or ""
        user = (ev.get("user", {}) or {}).get("username", "")
        e = _ts_epoch(ev.get("stageTimestamp"))
        label, reason, tech_hit = "benign", "", ""

        # Rule 1: anything touching the attacker's own namespace.
        if ns.startswith(ns_prefix):
            label, reason = "malicious", "attacker-namespace"

        # Rule 2: per-technique audit signature, by the attacker identity, within
        # that technique's window (the user gate excludes coincidental benign
        # control-plane activity that overlaps the attack window).
        if label == "benign" and (not attacker_user or user == attacker_user):
            for tid, ts, te in windows:
                if e is None or not (ts <= e <= te):
                    continue
                for sig in AUDIT_SIGNATURES.get(tid, []):
                    if sig["verb"] != verb or sig["resource"] != res:
                        continue
                    if sig.get("subresource", "") != sub:
                        continue
                    if sig.get("cluster_scoped") and ns:
                        continue
                    label, reason, tech_hit = "malicious", "technique-signature", tid
                    break
                if label == "malicious":
                    break

        if label == "malicious":
            n_mal += 1
            key = tech_hit or "attacker-namespace"
            by_tech[key] = by_tech.get(key, 0) + 1
        ev["label"] = label
        if reason:
            ev["label_reason"] = reason
        if tech_hit:
            ev["label_technique"] = tech_hit
        out.append(json.dumps(ev))

    dst = os.path.join(run_dir, "audit", "events_labeled.jsonl")
    with open(dst, "w") as f:
        f.write("\n".join(out))
    return {"total": len(out), "malicious": n_mal,
            "benign": len(out) - n_mal, "by_technique": by_tech}


def _flow_ep(ep):
    ep = ep or {}
    pod = ep.get("pod_name") or ""
    return ep.get("namespace", "") or "", pod


def label_flows(run_dir, attack, ns_prefix):
    src = os.path.join(run_dir, "cilium", "flows.jsonl")
    if not os.path.exists(src):
        return None
    atk_ips = set(attack.get("attacker_ips", []))
    atk_ns = set(attack.get("namespaces", []))

    out = []
    n_mal = 0
    for line in open(src):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        flow = obj.get("flow", obj)
        s_ns, s_pod = _flow_ep(flow.get("source"))
        d_ns, d_pod = _flow_ep(flow.get("destination"))
        ip = flow.get("IP", {}) or {}
        s_ip, d_ip = ip.get("source", ""), ip.get("destination", "")

        mal = (
            s_ns in atk_ns or d_ns in atk_ns
            or s_ns.startswith(ns_prefix) or d_ns.startswith(ns_prefix)
            or s_ip in atk_ips or d_ip in atk_ips
        )
        rec = {
            "time": flow.get("time"),
            "src": s_pod or s_ip, "src_ns": s_ns,
            "dst": d_pod or d_ip, "dst_ns": d_ns,
            "verdict": flow.get("verdict"),
            "label": "malicious" if mal else "benign",
        }
        if mal:
            n_mal += 1
        out.append(json.dumps(rec))

    dst = os.path.join(run_dir, "cilium", "flows_labeled.jsonl")
    with open(dst, "w") as f:
        f.write("\n".join(out))
    return {"total": len(out), "malicious": n_mal, "benign": len(out) - n_mal}


def label_access_logs(run_dir, attack):
    """Light IP-based scan of Envoy access logs. Control-plane techniques rarely
    touch the mesh, so this is usually all-benign — but it makes the labeling
    coverage explicit rather than silently skipping L7."""
    d = os.path.join(run_dir, "istio", "access_logs")
    if not os.path.isdir(d):
        return None
    atk_ips = set(attack.get("attacker_ips", []))
    total = mal = 0
    for fn in os.listdir(d):
        if not fn.endswith(".log"):
            continue
        for line in open(os.path.join(d, fn)):
            if not line.strip():
                continue
            total += 1
            if any(ipv and ipv in line for ipv in atk_ips):
                mal += 1
    return {"total": total, "malicious": mal}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="attack run directory")
    args = ap.parse_args()

    attack_path = os.path.join(args.dir, "attack", "attack.json")
    if not os.path.exists(attack_path):
        print(f"[label_attack] no attack.json in {args.dir}; nothing to label")
        return 0
    attack = json.load(open(attack_path))
    ns_prefix = attack.get("namespace_prefix", "stratus-red-team")

    summary = {
        "techniques": [t["id"] for t in attack.get("techniques", [])],
        "attacker_namespaces": attack.get("namespaces", []),
        "attacker_ips": attack.get("attacker_ips", []),
        "audit": label_audit(args.dir, attack, ns_prefix),
        "cilium": label_flows(args.dir, attack, ns_prefix),
        "istio_access": label_access_logs(args.dir, attack),
    }
    with open(os.path.join(args.dir, "labels_summary.json"), "w") as f:
        json.dump(summary, f, indent=2)

    def fmt(s):
        return "n/a" if not s else f"{s['malicious']}/{s['total']} malicious"
    print(f"[label_attack] audit:  {fmt(summary['audit'])}")
    print(f"[label_attack] cilium: {fmt(summary['cilium'])}")
    print(f"[label_attack] istio:  {fmt(summary['istio_access'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
