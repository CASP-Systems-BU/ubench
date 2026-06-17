# Deterministic pod placement (social)

Every Deployment in `yamls/` is pinned to a fixed worker node via
`nodeSelector: { ubench.io/node-index: "<N>" }`, so the pod->node layout — and
therefore the cross-node network flow topology — is identical on every run.

**The mechanism** (stable `ubench.io/node-index` labels keyed off the `node-<N>`
ordinal, applied idempotently by `scripts/cloudlab/deploy.sh`, plus why we don't
use `kubernetes.io/hostname`) is documented once in
[../boutique/PLACEMENT.md](../boutique/PLACEMENT.md). This file only records the
mapping for `social`.

node-0 is the tainted control plane, so only worker indices 1-4 are used. The
client (`ubuntu-client`, pinned in `client/client.yaml`) always runs on node-1;
`compose_post` (the wrk entry point) is co-located there so the ingress hop is
intra-node and every entry->backend call crosses the overlay.

## Mapping

| node-index | node | services |
|---|---|---|
| 1 | node-1 (ingress tier, shares with `ubuntu-client`) | `compose_post`, `user_timeline` |
| 2 | node-2 | `home_timeline` |
| 3 | node-3 | `post_storage` |
| 4 | node-4 | `social_graph` |

Assignment rule: services in file order, round-robin across worker node-index
1->4, with the entry service placed on node-1.

## Changing / verifying

Edit the `nodeSelector` value in `yamls/<service>.yaml`, then re-run
`./deploy.sh social`. Check actual placement with:

```
kubectl get pods -o wide
kubectl get nodes -L ubench.io/node-index
```
