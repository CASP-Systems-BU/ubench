# Experiment specs

One YAML file = one reusable experiment definition. Run it with:

```bash
./scripts/cloudlab/deploy.sh --experiment experiments/boutique-mix.yaml --run
```

`deploy.sh` renders the benchmark manifests for the spec (`scripts/render_manifests.py`
→ `build/<name>/`), deploys them, fails fast if the cluster has fewer workers
than `workers`, and drives **one continuous wrk2 run** whose telemetry is
harvested into one run directory per `segment_s` under `results/`.

## Schema

```yaml
name: boutique-mix-1h        # optional; default: the file stem
benchmark: boutique          # required; one of k8s/<benchmark>/
request: mix                 # boutique: client/lua/<request>.lua
                             # chain-*: URL path on the entry service
                             # hotel/movie/social: ignored (mix lives in the rust proxy)
workers: 4                   # placement spans node-index 1..workers; deploy
                             # aborts if the cluster has fewer labeled workers

replicas:
  default: 1
  overrides:                 # keyed by Deployment name (kubectl get deploy)
    frontend: 2              # -> Deployments frontend-1, frontend-2, each
                             #    replicas:1, pinned round-robin from the
                             #    service's home node (deterministic placement)

load:
  threads: 4                 # wrk2 -t
  conns: 16                  # wrk2 -c (must be >= threads)
  rate: 1000                 # wrk2 -R, total offered req/s — REQUIRED knob;
                             # wrk2 is open-loop (see "Choosing rate")

total_duration_s: 3600       # one continuous wrk2 process
segment_s: 600               # telemetry harvested every segment_s into its own
                             # run dir (default: = total, i.e. a single segment)
seed: 42                     # chain-*: gen_processing_time.py seed
```

Env vars override spec values for a one-off run
(`RATE=500 ./deploy.sh --experiment ... --run`); precedence is
built-in default < spec < explicit env var.

## Segments, not repeats

A long experiment produces `total/segment` run directories, e.g.
`results/boutique-mix_20260812-010000/`, `..._20260812-011000/`, ... Each is a
contiguous time slice of the same continuous run — collected while the logs
still exist (kubelet and the apiserver rotate logs with hard caps, so a
multi-hour run collected only at the end would silently lose its early hours).
Downstream consumers that split runs by timestamp get a temporal split of the
long run for free. Keep `segment_s` at or below ~900s so a segment never
outlives log rotation.

## Choosing rate (knee sweep)

wrk2 is open-loop: it offers `rate` req/s no matter how the cluster responds.
If `rate` exceeds what the deployment can absorb, the backlog grows without
bound and latency measures the backlog, not the services. To find the limit,
run short experiments at increasing rates and compare `rate_rps` vs
`achieved_rps` in each run dir's `meta.json`:

```bash
for r in 250 500 750 1000 1250 1500 1750; do
  RATE=$r TOTAL_S=60 ./scripts/cloudlab/deploy.sh boutique --run
done
```

The knee is the first rate where achieved < ~99% of offered. Operate at
70–80% of the knee. Runs under 60s are only good for this sweep — wrk2 spends
its first 10s calibrating, so keep real experiments at several minutes minimum.
