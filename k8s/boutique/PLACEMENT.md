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
   labeling is idempotent (`kubectl label --overwrite`), re-runs on every
   deploy, and deploy.sh **fails fast** if the experiment needs a worker index
   no node carries.

2. **Rendered nodeSelectors.** `scripts/render_manifests.py` (invoked by
   `deploy.sh`) writes `nodeSelector: { ubench.io/node-index: "<N>" }` into
   every rendered Deployment, parameterized by the experiment's `workers:`
   count. `nodeSelector` is a *hard* requirement: if no node has the label a
   pod stays `Pending` (a loud, obvious failure) rather than silently landing
   somewhere arbitrary. The checked-in `yamls/` keep the 4-worker reference
   layout and are the renderer's input — don't hand-edit placement there.

3. **The rule.** Entry service first (on node-1, next to the client), then the
   remaining Deployments in `yamls/` filename order, round-robin over worker
   node-index `1..workers`. **Boutique is the exception**: its checked-in
   layout predates the rule (a block layout), so `bench.yaml` pins it verbatim
   under `pinned_layouts["4"]` — the default 4-worker placement never changes,
   keeping telemetry comparable with all historical runs. Any other worker
   count uses the rule.

4. **Replicas (`replicas.overrides` in the experiment spec).** A service with
   `m > 1` becomes m single-replica Deployments `<name>-1 … <name>-m`, replica
   r pinned to node-index `((home-1 + r-1) % workers) + 1` — round-robin
   starting from the service's home node. Placement stays fully deterministic
   (same pod→node mapping every run). The pods keep the service's `app` label
   (the Service routes to all of them) plus `ubench.io/replica-slot`. Note:
   wrk2 holds keep-alive connections and each connection pins to one endpoint
   for its lifetime — keep `conns` at several × the replica count for even
   per-replica load.

> **node-0 is the control plane** and carries the
> `node-role.kubernetes.io/control-plane:NoSchedule` taint, so workloads never
> run there. Only indices **1..workers** are used.

## The default mapping (workers=4, replicas=1)

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

Set `workers:` / `replicas:` in an experiment spec (`experiments/*.yaml`) and
re-deploy — see `experiments/README.md`. The rendered result is what gets
applied; verify it offline with `scripts/check_render.sh` or inspect
`build/<name>/resolved.json`. To verify where pods actually landed:

```
kubectl get pods -o wide                     # ACTUAL placement this run
kubectl get nodes -L ubench.io/node-index    # the node labels
```

## Applying this to other benchmarks

All six benchmarks are pinned and rendered the same way; each has a
`bench.yaml` naming its entry service. Boutique is the only one with a pinned
(non-rule) default layout.
