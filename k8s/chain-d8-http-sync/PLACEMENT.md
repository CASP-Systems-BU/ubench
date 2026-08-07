# Deterministic pod placement (chain-d8-http-sync)

Every Deployment in `yamls/` is pinned to a fixed worker node via
`nodeSelector: { ubench.io/node-index: "<N>" }`, so the pod->node layout — and
therefore the cross-node network flow topology — is identical on every run.

**The mechanism** (stable `ubench.io/node-index` labels keyed off the `node-<N>`
ordinal, applied idempotently by `scripts/cloudlab/deploy.sh`, plus why we don't
use `kubernetes.io/hostname`) is documented once in
[../boutique/PLACEMENT.md](../boutique/PLACEMENT.md). This file only records the
mapping for `chain-d8-http-sync`.

node-0 is the tainted control plane, so only worker indices 1..workers
(default 4) are used. The
client (`ubuntu-client`, pinned in `client/client.yaml`) always runs on node-1;
`service0` (the wrk entry point) is co-located there so the ingress hop is
intra-node and every entry->backend call crosses the overlay.

## Mapping

| node-index | node | services |
|---|---|---|
| 1 | node-1 (ingress tier, shares with `ubuntu-client`) | `service0`, `service4`, `service8` |
| 2 | node-2 | `service1`, `service5`, `service9` |
| 3 | node-3 | `service2`, `service6` |
| 4 | node-4 | `service3`, `service7` |

Assignment rule: services in file order, round-robin across worker node-index
1->workers, with the entry service placed on node-1. The table shows the
default workers=4 layout; scripts/render_manifests.py generalizes it to any
worker count, and `replicas.overrides` in an experiment spec expands a service
into per-replica pinned Deployments (see ../boutique/PLACEMENT.md).

## Changing / verifying

Set `workers:` / `replicas:` in an experiment spec (`experiments/*.yaml`)
and re-deploy — placement is rendered, not hand-edited (see
../boutique/PLACEMENT.md). Check actual placement with:

```
kubectl get pods -o wide
kubectl get nodes -L ubench.io/node-index
```
