# Agentic boutique: the `recommendations` agent

Boutique is otherwise a set of **static** microservices with fixed RPC fan-out.
The `recommendations` service is now an **agent**: a bounded tool-calling loop
whose downstream calls are chosen at run time (by a deterministic stub or by a
real LLM) instead of hard-coded. This turns boutique into an *agentic* workload
with content-dependent, variable fan-out and (optionally) real external LLM
egress — a more realistic benign regime for the gnnid intrusion detector.

> Note: before this change `recommendations` was deployed but **never called**
> (no service invoked it and no request mix drove it), and its one hard-coded
> call fetched an empty catalog (`catalog_size: 0`). It is now wired in through a
> dedicated path and fetches a real catalog.

## How it works

`GetRecommendationsFor` runs an agent loop (`app/internal/boutique/agent.go`).
Its "tools" are existing boutique services, called over the same k8s-DNS
HTTP/JSON contract as `pkg/invoke`:

| tool | service | method | notes |
|---|---|---|---|
| `fetch_catalog` | productcatalog | `ro_fetch_catalog` | returns the product list |
| `get_product` | productcatalog | `ro_get_product` | arg is `id` (not `product_id`) |
| `get_cart` | cart | `ro_get_cart` | needs a `user_id` |
| `list_currencies` | currency | `ro_get_currencies` | — |

The loop and tool dispatch are identical across backends; only the choice of the
next action differs. Any backend error or timeout **falls back to the stub**, so
a request never fails or stalls the mesh.

### Backends (`AGENT_MODE`)

- **`stub`** (default) — a deterministic, input-seeded sequence of real tool
  calls (0–2 product look-ups, maybe the cart, maybe currencies), then a sampled
  recommendation. Same input → same calls and same result; different inputs →
  different fan-out. Free, reproducible, safe at full request rate (CI and dense
  telemetry).
- **`llm`** — an OpenAI-compatible chat model drives the tool calls (`pkg/llm`).
  Produces real external egress (a `recommendations → ext:world` flow). Honors
  `AGENT_SAMPLE` and bounded steps; falls back to the stub on any error.

### Environment

Set on the `recommendations` Deployment (`k8s/boutique/yamls/recommendations.yaml`):

| env | default | meaning |
|---|---|---|
| `AGENT_MODE` | `stub` | `stub` or `llm` |
| `AGENT_MAX_STEPS` | `3` | max tool-call rounds in llm mode |
| `AGENT_SAMPLE` | `1.0` | fraction of llm calls that hit the model (rest use stub) |
| `AGENT_SEED` | `42` | stub RNG seed base |
| `AGENT_CATALOG_SIZE` | `10` | `catalog_size` sent to productcatalog |
| `AGENT_LLM_BASE_URL` | — | OpenAI-compatible base URL, e.g. `https://openrouter.ai/api/v1` |
| `AGENT_LLM_MODEL` | — | model id, e.g. `openai/gpt-4o-mini` |
| `AGENT_LLM_API_KEY` | — | bearer token (from a Secret; optional) |
| `AGENT_LLM_TEMPERATURE` | `0` | sampling temperature |
| `AGENT_LLM_TIMEOUT_MS` | `8000` | per-request timeout before fallback |

A per-request `mode` field on the request body overrides `AGENT_MODE` (used in
tests; the load mix leaves it empty so the deployment env decides).

## Driving it

The wrk2 driver only hits the frontend, so the agent is reached through a thin
frontend passthrough `POST /ro_recommend` → `recommendations`. The request mix
`client/lua/agentic.lua` is the standard boutique traffic **plus** a `recommend`
route (~20%). The default `client/lua/mix.lua` is untouched, so `request: mix`
runs stay byte-identical to history. Select the agentic mix with `request: agentic`.

Experiment specs:

- `experiments/boutique-agentic.yaml` — stub backend, healthy rate. Dense,
  reproducible, free.
- `experiments/boutique-agentic-llm.yaml` — low rate for the real LLM backend.

```bash
# stub (default manifest): dense agentic fan-out, no cost
./scripts/cloudlab/deploy.sh --experiment experiments/boutique-agentic.yaml --run
```

### Rate / cost

wrk2 is open-loop; real LLM calls cannot run at mix rate. The stub is free and
runs at full rate. For the `llm` backend keep the experiment rate low
(`boutique-agentic-llm.yaml` uses `rate: 10`) and/or set `AGENT_SAMPLE` below
1.0 so only a fraction of calls hit the model; the timeout + stub fallback bound
tail latency and cost.

## Switching to the LLM backend

1. Create the API-key Secret (kept out of `yamls/` so deploys don't clobber it):
   ```bash
   kubectl create secret generic recommendations-llm --from-literal=api-key='sk-or-...'
   ```
   (template: `k8s/boutique/recommendations-llm-secret.example.yaml`)
2. In `k8s/boutique/yamls/recommendations.yaml` set `AGENT_MODE=llm`,
   `AGENT_LLM_BASE_URL`, `AGENT_LLM_MODEL`, and an `AGENT_SAMPLE` you can afford.
3. Deploy with `experiments/boutique-agentic-llm.yaml`.

The cluster has no NetworkPolicy and Istio defaults to allow-any egress, so
external calls work without extra policy. On a locked-down cluster, add an egress
allow (and an Istio `ServiceEntry` under `REGISTRY_ONLY`) for the model host.

## Rebuilding the image

The boutique app image is built **manually** (not CI, unlike the client image).
`PrebuiltDockerfile` rebuilds every `app/cmd/boutique/*` binary, so the changed
recommendations + frontend are included automatically:

```bash
docker build --build-arg BENCHMARK=boutique -f scripts/PrebuiltDockerfile . -t <registry>/ubench:boutique
docker push <registry>/ubench:boutique
```

The tag is mutable. This feature's first deploy changes `recommendations.yaml`,
so `deploy.sh`'s drift path recreates the pods and they pull the new image. A
*later* same-tag rebuild with unchanged YAML won't auto-roll — use a dated
immutable tag, or `kubectl rollout restart deployment -l ubench.io/bench=boutique`.

## What the detector sees

`recommendations` keeps its role name but gains **variable, multimodal fan-out**
to productcatalog/cart/currency, and in `llm` mode a `recommendations → ext:world`
L4 flow (a `dns:<host>` node appears only if Hubble L7 DNS visibility is enabled;
it is off by default). No gnnid schema or code change is needed — the role is
learned from data. Expect the wider benign distribution to raise this role's
baseline role-prediction error; watch it in `gnnid eval`.
