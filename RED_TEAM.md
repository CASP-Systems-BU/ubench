# Red-team attack simulation + labeled capture (Stratus Red Team)

> **Date:** 2026-06-24
> **Why this doc exists:** add an *injected adversary* to the ubench capture pipeline so a
> run produces **labeled** benign+malicious provenance data — directly closing **Gap 2**
> ("we have no attack traffic, no labels") from [`ASSUREMOSS_DATASET_ANALYSIS.md`](ASSUREMOSS_DATASET_ANALYSIS.md)
> and feeding the long-term GNN-IDS dataset goal.

---

## 1. TL;DR

- We integrated **[Stratus Red Team](https://github.com/DataDog/stratus-red-team)** (DataDog's
  attack emulator) to detonate **Kubernetes control-plane attacks** against the CloudLab cluster
  **while a benign workload runs**, capturing the full metric bundle plus a **ground-truth label**.
- One command — `scripts/cloudlab/attack.sh` — deploys the app, drives benign `wrk` load, detonates
  the attack mid-window, captures everything, and labels every record benign/malicious.
- **New data source:** the **kube-apiserver audit log** (previously off). It is *the* place
  control-plane attacks are legible, and now part of every attack capture.
- **Validated end-to-end** with `k8s.privilege-escalation.privileged-pod`: benign load of
  137k requests @ 1522 req/s, attack detonated 25s in, **12 audit events correctly labeled
  malicious** (the privileged-pod create with `privileged=true, code=201`, the namespace/SA/
  configmap/CiliumEndpoint creates), 0 false positives, cluster left clean.

### Honest fit assessment (read this first)

Stratus Red Team emulates **control-plane / cloud-API** attacks. Its 8 Kubernetes techniques are
all mediated by the **Kubernetes API server** (run from the operator machine via kubeconfig). This
means:

- ✅ **Great for:** a reproducible, self-cleaning, MITRE-mapped adversary whose actions are
  *unambiguous in the audit log* — privileged pods, secret dumps, admin clusterroles, stolen
  service-account tokens, container breakouts. Ideal for a **whole-cluster provenance** IDS dataset.
- ⚠️ **Not** a substitute for the AssureMOSS-style **web-RCE → lateral-movement → crypto-miner**
  chains (those are *application-network* attacks). Stratus won't reproduce those; it attacks the
  control plane, not the boutique microservices.
- ⚠️ **Layer reality:** control-plane techniques have a thin L3/L4 footprint. `privileged-pod`
  creates a pod that just *sleeps* — its signal is **in the audit log, not the network**. Our
  capture reflects this honestly (audit: labeled; cilium/istio: ~0 for this technique). Techniques
  whose pods actually talk on the network (or read the API from inside the pod) do show up in the
  Hubble flow graph, and the harness labels those too (by attacker pod IP / namespace).

So: this is the right tool for **labeled control-plane attack samples**, captured in the **same**
provenance bundle as the benign app traffic. It complements — does not replace — future
app-layer exploit injection.

---

## 2. What was added

| File | Role |
|---|---|
| [`scripts/cloudlab/audit-policy.yaml`](scripts/cloudlab/audit-policy.yaml) | kube-apiserver audit policy: `RequestResponse` for secrets/SA/RBAC/pod-create/exec, `Metadata` for the rest, drops control-plane read noise. |
| [`scripts/cloudlab/enable_audit.sh`](scripts/cloudlab/enable_audit.sh) | Turn audit logging on/off on node-0. Idempotent + **reversible** (backs up the static-pod manifest, `revert` restores it). `enable` / `status` / `revert`. |
| [`scripts/attack_and_collect.sh`](scripts/attack_and_collect.sh) | The attack-aware sibling of `run_and_collect.sh`. Runs on node-0: benign load + Stratus detonation mid-window + metric/audit capture + labeling + cleanup. |
| [`scripts/cloudlab/attack.sh`](scripts/cloudlab/attack.sh) | Host-side orchestrator (sibling of `deploy.sh --run`): ensure deploy → ship harness up → run → pull the labeled bundle back to `results/`. |
| [`scripts/label_attack.py`](scripts/label_attack.py) | Post-processor: tags each audit event / network flow / access-log line **benign \| malicious** using the attacker namespace + pod IPs + per-technique audit signatures. |
| [`scripts/collect_metrics.py`](scripts/collect_metrics.py) | Extended with **audit-log collection** (`--audit-log`): slices the audit log to the run window, writes `audit/events.jsonl` + `audit/summary.json`. |

Stratus itself is installed on the control node at `~/.local/bin/stratus` (v2.33.0, Linux x86_64).

---

## 3. Quickstart

```bash
# One-time: enable the kube-apiserver audit log (reversible; ~10-30s API restart)
./scripts/cloudlab/enable_audit.sh enable
./scripts/cloudlab/enable_audit.sh status      # verify it's logging

# Run a mixed benign+attack capture (default: privileged-pod, 90s load, detonate 25s in)
./scripts/cloudlab/attack.sh boutique
# -> results/attack-boutique-mix_<ts>/   (pulled back, already labeled)
```

Tuning (env vars on `attack.sh`):

```bash
# Detonate a curated multi-tactic set instead of the single smoke-test technique
TECHNIQUES="k8s.credential-access.dump-secrets \
            k8s.credential-access.steal-serviceaccount-token \
            k8s.privilege-escalation.privileged-pod \
            k8s.persistence.create-admin-clusterrole" \
DURATION=120 ATTACK_DELAY=30 ./scripts/cloudlab/attack.sh boutique

KEEP_ATTACK=1 ./scripts/cloudlab/attack.sh boutique --no-deploy   # leave residue, skip deploy
```

The 8 available Kubernetes techniques (`stratus list --platform kubernetes`):

| Technique ID | MITRE tactic | Footprint |
|---|---|---|
| `k8s.credential-access.dump-secrets` | Credential Access | audit (`list secrets`, cluster-scoped) |
| `k8s.credential-access.steal-serviceaccount-token` | Credential Access | audit + pod (network) |
| `k8s.persistence.create-admin-clusterrole` | Persistence / Priv-Esc | audit (`create clusterrole(binding)`) |
| `k8s.persistence.create-client-certificate` | Persistence | audit (`create CSR` + approve) |
| `k8s.persistence.create-token` | Persistence | audit (`create serviceaccounts/token`) |
| `k8s.privilege-escalation.hostpath-volume` | Privilege Escalation | audit + pod |
| `k8s.privilege-escalation.nodes-proxy` | Privilege Escalation | audit (`nodes/proxy`) |
| `k8s.privilege-escalation.privileged-pod` | Privilege Escalation | audit + pod |

---

## 4. Output bundle

Same layout as a normal `results/<run>/` capture (so all existing tooling works), **plus** two
new directories and the labels:

```
results/attack-boutique-mix_<ts>/
├── meta.json                  # + is_attack, attack_techniques, attack_start/end_epoch, audit_enabled
├── resources.csv              # per-pod CPU/mem (now -A: includes attacker pods)
├── wrk.txt / run.log          # benign load
├── cilium/                    # L3/L4 flows + DNS + edges  (network provenance)
│   ├── flows.jsonl
│   ├── flows_labeled.jsonl    # NEW: each flow tagged benign|malicious
│   └── edges.json, dns.jsonl, hubble_metrics.prom
├── istio/                     # L7 HTTP call graph + Envoy access logs
│   ├── edges.json, summary.json, access_logs/<pod>.log, ...
├── audit/                     # NEW: control-plane provenance
│   ├── events.jsonl           # kube-apiserver audit events, sliced to the window
│   ├── events_labeled.jsonl   # each event tagged benign|malicious (+ reason, technique)
│   └── summary.json           # counts by verb×resource, by user, + sensitive events
├── attack/                    # NEW: ground truth
│   ├── attack.json            # techniques + windows + attacker namespaces/pods/IPs/user
│   ├── techniques.jsonl       # one record per detonation (id, mitre, tight ts window, rc)
│   ├── entities.json          # attacker namespaces + pods (name/ip/node)
│   └── detonate_<id>.log, attacker.log
└── labels_summary.json        # NEW: benign/malicious counts per source
```

The **metric window** is the union of the wrk load phase and the attack window, so the detonation
is always fully contained; every source (Istio, Cilium, audit, access logs) is sliced to it.

---

## 5. How labeling works

Mirrors AssureMOSS's recipe (label by *attacker identity + attack timestamps*) but with our richer,
exact ground truth from `attack/attack.json`:

**Audit events** → malicious if:
1. **`attacker-namespace`** — `objectRef.namespace` starts with `stratus-red-team` (catches every
   pod-creating technique and all its side-effect resources), **or**
2. **`technique-signature`** — within a technique's time window, performed **by the attacker
   identity** (`kubernetes-admin`), matching that technique's `(verb, resource, subresource,
   cluster_scoped)` signature (e.g. dump-secrets → cluster-scoped `list secrets`). The **identity
   gate** is what keeps coincidental benign churn out — e.g. `kiali`'s `create pods/portforward` or
   `kubelet`'s `create serviceaccounts/token` that happen to fall in the window are **not** labeled.

**Network flows** (Hubble) → malicious if either endpoint is in an attacker namespace or matches an
attacker pod IP. **Access logs** (Envoy) → IP-based scan (usually all-benign for control-plane
techniques; kept explicit rather than skipped).

> The labeler ([`label_attack.py`](scripts/label_attack.py)) is **pure post-processing** — re-run it
> on any captured bundle: `python3 scripts/label_attack.py --dir results/attack-..._<ts>`.

---

## 6. Validated smoke run (2026-06-24)

`./scripts/cloudlab/attack.sh boutique` with `DURATION=90 ATTACK_DELAY=25`, technique
`k8s.privilege-escalation.privileged-pod`:

- **Benign load:** 137,090 requests in 1.50m, 1522 req/s.
- **Capture window (90s):** cilium **14,562 / 19,021** flows → 1,403 edges, 1,114 DNS;
  audit **466 / 3,797** events → 54 sensitive; istio **391,802** access-log lines.
- **Attack:** detonated 25s in, `rc=0`, 9s window; created ns `stratus-red-team-privileged-name-*`
  with a `busybox:stable` pod, `securityContext.privileged=true`, API `code=201`.
- **Labels:** audit **12/466 malicious** — all in the attacker namespace, **0 false positives**
  (after fixing an over-broad pod-create signature with the identity gate); cilium/istio 0 malicious
  — **correct**: a sleeping privileged pod has no app-network/mesh traffic.
- **Cleanup:** `stratus revert/cleanup` removed everything; no leftover namespaces/pods/clusterroles;
  apiserver healthy; audit logging intact.

The gold-standard malicious record, straight from `audit/events_labeled.jsonl`:

```
verb=create resource=pods ns=stratus-red-team-privileged-name-dweblkhg
  user=kubernetes-admin image=busybox:stable privileged=True code=201  label=malicious
```

---

## 7. Limitations & next steps

- **Scale up the adversary.** The smoke test was one technique; run the **curated multi-tactic set**
  (§3) to populate Credential-Access / Persistence / Priv-Esc samples in one bundle. Each technique's
  signature is already in the labeler.
- **App-layer attacks remain future work.** To reproduce AssureMOSS's web-RCE/DoS/crypto-miner
  scenarios (true microservice-network attacks), we still need in-cluster exploit pods — Stratus does
  not cover these.
- **Gap 1 (bytes) is still open.** Hubble flows carry no per-flow byte counts (see the AssureMOSS
  doc) — independent of this work; a Packetbeat/conntrack exporter is still the fix.
- **Audit policy is tunable.** [`audit-policy.yaml`](scripts/cloudlab/audit-policy.yaml) currently
  logs sensitive resources at `RequestResponse` (full bodies, incl. secret values — fine on a
  sandbox) and everything else at `Metadata`. Tighten/loosen as the dataset needs.
- **Disable when done:** `./scripts/cloudlab/enable_audit.sh revert` restores the pre-audit apiserver.

---

## 8. Sources

- [Stratus Red Team — GitHub](https://github.com/DataDog/stratus-red-team) ·
  [docs](https://stratus-red-team.cloud/) ·
  [Kubernetes techniques](https://stratus-red-team.cloud/attack-techniques/kubernetes/)
- [Kubernetes auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- Companion: [`ASSUREMOSS_DATASET_ANALYSIS.md`](ASSUREMOSS_DATASET_ANALYSIS.md) (Gap 2),
  [`METRICS.md`](METRICS.md) (the capture field reference).
