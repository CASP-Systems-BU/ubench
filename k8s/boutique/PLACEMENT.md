# Deterministic pod placement (boutique)

## Why

By default the Kubernetes scheduler spreads pods across the worker nodes however
it sees fit, so two runs can land the same services on different nodes. That
changes the **network flow topology**: a service-to-service call is an
intra-node hop (no encapsulation) when the pods share a node, but a cross-node
hop over the Cilium VXLAN overlay (`trace_observation_point: TO_OVERLAY`,
`interface: cilium_vxlan`) when they don't. The result is that
`cilium/edges.json`, `istio/edges.json`, and the per-flow records differ run to
run, which makes comparing logs across runs unreliable.

Pinning each service to a fixed node makes the pod→node layout — and therefore
the cross-node edge set — **identical on every run**.

## How it works

1. **Stable node labels.** `deploy.sh` labels every node
   `ubench.io/node-index=<N>` before applying manifests, where `<N>` is the
   integer from the node's `node-<N>` hostname prefix. We key off the ordinal
   (not `kubernetes.io/hostname`) because the CloudLab hostname embeds the
   experiment name — `node-3.ubench-7.nsdi27-casp-pg0.apt.emulab.net` — which
   changes when you swap experiments; the `node-<N>` ordinal is stable. The
   labeling is idempotent (`kubectl label --overwrite`) and re-runs on every
   deploy, so it self-heals and needs no re-bootstrap.

2. **nodeSelector in each manifest.** Every Deployment in `yamls/` carries
   `nodeSelector: { ubench.io/node-index: "<N>" }`, and `client/client.yaml`
   does too. `nodeSelector` is a *hard* requirement: if no node has the label a
   pod stays `Pending` (a loud, obvious failure) rather than silently landing
   somewhere arbitrary.

> **node-0 is the control plane** and carries the
> `node-role.kubernetes.io/control-plane:NoSchedule` taint, so workloads never
> run there. Only indices **1–4** (the four workers) are used.

## The mapping

| node-index | node | services |
|---|---|---|
| 1 | node-1 (ingress tier) | `frontend`, `ubuntu-client` |
| 2 | node-2 | `cart`, `checkout`, `currency` |
| 3 | node-3 | `email`, `payment` |
| 4 | node-4 | `productcatalog`, `recommendations`, `shipping` |

Rationale: the client and `frontend` (the ingress) share node-1, so the
client→frontend hop is intra-node; every frontend→backend call then crosses to
node-2/3/4, giving a pronounced and **stable** set of cross-node overlay edges
to analyze. Load is spread 2/3/2/3 across the workers.

## Changing it

Edit the `nodeSelector` value in the relevant `yamls/<service>.yaml` (and
`client/client.yaml` for the client), then re-run `./deploy.sh boutique`. No
node-side changes are needed — the labels already exist on all nodes. To verify
where pods actually landed:

```
kubectl get pods -o wide                     # ACTUAL placement this run
kubectl get nodes -L ubench.io/node-index    # the node labels
```

## Applying this to other benchmarks

Only boutique is pinned today. To pin another workload, add the same
`nodeSelector` block under each Deployment's `template.spec` in that benchmark's
`yamls/`. The node labels and the `deploy.sh` labeling step are workload-agnostic,
so nothing else changes.
