# k8s-redteam — LLM post-compromise agent for labeled attack telemetry

An [hackingBuddyGPT](https://github.com/ipa-lab/hackingBuddyGPT) use case that drives an
autonomous LLM red-team agent from a **foothold pod** inside the CloudLab Kubernetes cluster, so its
post-compromise activity is captured by ubench's telemetry collector and labeled for the gnnid GNN
intrusion detector. See [`../REDTEAM.md`](../REDTEAM.md) for the end-to-end workflow and
[`../k8s/redteam/`](../k8s/redteam/) for the attacker launchpad manifests.

This runs on the dev box (Python ≥3.13, separate from gnnid's 3.12 env) and reaches the cluster via
`ssh <control-node> kubectl exec` — the same SSH-to-node-0 path everything else uses. It does **not**
run inside the cluster.

## Install

```bash
uv venv --python 3.13 .venv && source .venv/bin/activate
uv pip install -e .            # pulls hackingbuddygpt from PyPI
cp .env.example .env           # then edit .env: put your OpenRouter key in llm.api_key
redteam-agent                  # no args: lists use cases (expect K8sPostCompromise)
```

## Run (standalone)

Usually `scripts/cloudlab/redteam.sh` deploys the launchpad and invokes this with the live pod name.
To run it by hand against an already-deployed launchpad pod:

```bash
redteam-agent K8sPostCompromise \
    --pod "$(ssh WillG@apt097.apt.emulab.net kubectl get pod -n redteam -l app=redteam-agent -o jsonpath='{.items[0].metadata.name}')" \
    --node0 apt097.apt.emulab.net --node0_user WillG --namespace redteam
```

The run transcript (every tool call + LLM message, with timestamps and cost) is written to
`logs/log-<timestamp>.jsonl`. `redteam.sh` reads it to build the attack ground truth
(`attack/attack.json`) that gnnid's labeler consumes.

## What it does

The agent is told it has a shell on a compromised pod whose service-account token is mounted, and is
asked to enumerate its access and the cluster and attempt lateral movement / privilege escalation
(`run_shell_command` → `kubectl exec` in the pod; `record_note`; `conclude`). The pod's RBAC scope
(set by `k8s/redteam/rbac-recon.yaml` by default) determines what succeeds vs what is denied — both
are useful labeled signal. Bound by `limits.max_rounds` / `limits.max_cost` in `.env`.
