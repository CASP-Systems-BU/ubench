# Red-team attack simulation + labeled capture (hackingBuddyGPT)

> **Why this exists:** add an *LLM-driven adversary* to the ubench capture pipeline so a run
> produces **labeled** benign+malicious telemetry — the attack data and ground-truth labels the
> gnnid GNN-IDS needs to measure real detection performance (not just benign proxies).

## TL;DR

- An autonomous LLM agent ([hackingBuddyGPT](https://github.com/ipa-lab/hackingBuddyGPT)) is given a
  **foothold pod** inside the cluster with a mounted service-account token and `kubectl`, and told to
  enumerate its access and attempt lateral movement / privilege escalation — a realistic
  **post-compromise** attacker.
- One command — `scripts/cloudlab/redteam.sh` — deploys the launchpad, drives benign `wrk2` load,
  runs the agent mid-window, captures the full telemetry bundle, and writes the attack **ground
  truth** so gnnid can label every event benign/malicious.
- The agent runs on the dev box (its own Python ≥3.13 venv) and reaches the cluster over the same
  `ssh node-0 kubectl exec` path everything else uses; nothing extra is installed on the nodes.

## Components

| Path | Role |
|---|---|
| [`k8s/redteam/`](k8s/redteam/) | Attacker launchpad: `namespace` + scoped `ServiceAccount`/RBAC (`rbac-recon.yaml` default, `rbac-escalated.yaml` opt-in) + `attacker.yaml` (a pod with `kubectl`, image `alpine/k8s`). |
| [`redteam/`](redteam/) | The hackingBuddyGPT integration (Python pkg `k8s_redteam`): `PodShellCapability` (kubectl-exec-into-pod tool) + the `K8sPostCompromise` use case. OpenRouter LLM via `.env`. |
| [`scripts/cloudlab/redteam.sh`](scripts/cloudlab/redteam.sh) | Host orchestrator (sibling of `deploy.sh --run`): deploy → benign capture → agent → label-ground-truth → teardown. |

The collector is **unchanged**: `run_and_collect.sh` / `collect_metrics.py` already capture the
kube-apiserver audit log, Hubble flows, and `-A` object snapshots cluster-wide, which is everything
the attacker pod touches. No collector edits were needed.

## Quickstart

```bash
# one-time: Python 3.13 venv for the agent + your OpenRouter key
cd redteam
uv venv --python 3.13 .venv && uv pip install -e .
cp .env.example .env            # edit .env: set llm.api_key (OpenRouter)
cd ..

# run a mixed benign+attack capture (default: recon RBAC, boutique, 10min window)
./scripts/cloudlab/redteam.sh boutique
# -> results/boutique-mix_<ts>/ … each segment that overlaps the attack now has attack/attack.json
```

Tuning (env on `redteam.sh`): `RBAC_PROFILE=recon|escalated`, `WARMUP_S`, `RATE/TOTAL_S/SEGMENT_S`.
Agent budget (rounds/cost/model) lives in `redteam/.env` (`limits.max_rounds`, `limits.max_cost`,
`llm.model`). Keep `TOTAL_S` larger than `WARMUP_S` + the agent's run time so the attack is fully
inside the window.

## Ground truth & labeling

`redteam.sh` writes `attack/attack.json` into each captured run dir that overlaps the attack:

```json
{
  "is_attack": true,
  "attacker_tool": "hackingBuddyGPT",
  "attacker_namespace": "redteam",
  "attacker_ips": ["10.244.x.y"],
  "attacker_pod": "redteam-agent-...",
  "attacker_sa": "system:serviceaccount:redteam:redteam-agent",
  "rbac_profile": "recon",
  "llm_model": "openrouter/anthropic/claude-3.5-sonnet",
  "session_start_epoch": 1760000000,
  "session_end_epoch": 1760000300,
  "hbgpt_log": "log-20261007-....jsonl"
}
```

The attacker's full transcript (every tool call + LLM message, timestamped) is copied in next to it
as `attack/log-*.jsonl`. gnnid's labeler (`gnnid ingest --labels`) keys on the attacker **identity**
(namespace + pod IP) matched against resolved entities, with the session window as a guard. The
network plane (Hubble) is the reliable signal: it carries pod identity from eBPF, so it is unaffected
by the pod→apiserver source-NAT that masquerades a worker pod's API calls to its node IP.

## Then: measure detection (gnnid)

From the gnnid repo root:

```bash
uv run gnnid ingest --labels   # stamps events benign/malicious from attack/attack.json
uv run gnnid train             # benign-only model (attack runs auto-held out of train/val)
uv run gnnid score
uv run gnnid eval              # eval_report.json includes a `labeled_detection` block:
                               # real ROC-AUC / PR / precision-recall of attacker-touched
                               # (known-role) node-windows vs benign
```

## Scope & safety

- Everything the attacker does is confined to namespace `redteam` under one service account, so the
  labels are exact; `redteam.sh` tears the launchpad down after capture (`--keep` to leave it).
- The `recon` RBAC profile is an over-permissioned *read-only* misconfig (recon returns real data;
  writes/secret-reads elsewhere 403 — valuable labeled "denied" signal). `escalated` lets lateral
  movement / secret theft succeed, for "successful attack" samples.
- This is authorized red-team data generation on a dedicated research cluster. It is **not** a
  substitute for a hardened production threat model.
