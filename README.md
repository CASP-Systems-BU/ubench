# Microservice Benchmarks

## Origin and acknowledgements

This repository is a fork of [atlas-brown/ubench](https://github.com/atlas-brown/ubench).
The upstream project provides the core benchmarks: the Go microservice
applications (boutique, hotel, movie, social, and the synthetic chain/mutex
services), as well as Kubernetes manifests, the load-generation client, and the
basic run scripts.

Our contributions on top of upstream:

- CloudLab automation: cluster registration, bootstrap, and deployment ([scripts/cloudlab/](scripts/cloudlab/)).
- A spec-driven experiment pipeline: declarative experiment specs ([experiments/](experiments/)) with a manifest renderer and segmented runs.
- wrk2-based load generation with a pinned, prebuilt client image and vendored Lua request mixes.
- Telemetry collection: per-segment resource sampling via /proc probes, metrics-server, optional Istio service-level metrics, and Kubernetes audit-log capture.
- Deterministic, per-replica pinned pod placement across all benchmarks.

## Running on CloudLab

See [scripts/cloudlab/README.md](scripts/cloudlab/README.md) for how to instantiate a cluster, bootstrap it, and deploy/run a workload.

## Agentic workload

Boutique's `recommendations` service can run as an **LLM agent** instead of a
static stub: a bounded tool-calling loop whose downstream calls (productcatalog,
cart, currency) are chosen at run time, giving content-dependent, variable
fan-out and optional real external LLM egress. A deterministic `stub` backend is
the default (free, reproducible, full-rate); an OpenAI-compatible `llm` backend
produces real egress at low rate.

```bash
# stub backend — dense agentic fan-out, no cost:
./scripts/cloudlab/deploy.sh --experiment experiments/boutique-agentic.yaml --run
```

Full reference (backends, env, driver, LLM setup, image rebuild, telemetry):
[docs/AGENTIC.md](docs/AGENTIC.md).