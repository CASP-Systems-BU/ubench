# Running on CloudLab

## 1. Instantiate a cluster

1. Go to [Project Profiles](https://www.cloudlab.us/user-dashboard.php#projectprofiles).
2. Pick the **r320x5** profile and click [Instantiate](https://www.cloudlab.us/show-profile.php?uuid=5e50d04b-1b1e-11f0-af1a-e4434b2381fc).
3. Change only the experiment **name** — keep everything else at the defaults.
4. Once it's ready, grab the node hostnames from the **List View**.

## 2. Point the scripts at your nodes

Edit [nodes.sh](nodes.sh) — the single shared list of public hostnames sourced by both
`bootstrap.sh` and `deploy.sh`. `node-0` MUST be first (it becomes the control plane) and
the order must match the internal-IP order in [config.json](config.json). This is the only
file you edit when swapping experiments.

## 3. Bootstrap the cluster

```bash
./bootstrap.sh
```

Orchestrates the whole setup across all nodes: brings up the k8s cluster (`kube`) and applies
firewall + SSH hardening (`secure`).

## 4. Deploy a workload

```bash
./deploy.sh              # defaults to the boutique workload
./deploy.sh movie        # any workload under k8s/<bench>/
```

Copies the workload's `k8s/<bench>/` manifests to the control node, applies them, waits for
rollout, and runs a heartbeat sweep to confirm the deploy is live.

Flags:

- `--down` — tear down a workload's services (directory-based `kubectl delete`).
- `--run` — after deploying, copy `scripts/run.sh` + `client/` up and drive the `wrk` load
  test against the services. `wrk` params are env-overridable via `REQUEST` / `THREADS` /
  `CONNS` / `DURATION` (defaults: mix, 4, 16, 30).

```bash
./deploy.sh boutique --run
./deploy.sh boutique --down
```
