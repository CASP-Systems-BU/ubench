# Build the client (load-generator) image

The client pod image carries `/wrk2/wrk` (pinned giltene/wrk2) and the rust
request-mix proxy. The Lua request mixes are **not** in the image — they live
in `client/lua/` and are mounted via the `wrk-scripts` ConfigMap by
`scripts/run.sh`, so editing a mix never needs a rebuild.

Build from the **repo root**, with `client/` as the build context (the
Dockerfile COPYs `./proxy` relative to the context):

```bash
TAG="$(date -u +%Y%m%d)-g$(git rev-parse --short HEAD)"
docker build --platform linux/amd64 -f scripts/ClientDockerfile client/ \
    -t <REGISTRY>/ubench-client:${TAG}
docker push <REGISTRY>/ubench-client:${TAG}
```

`<REGISTRY>` is your registry namespace (e.g. `docker.io/<dockerhub-user>`).
Tags are immutable — the date+sha scheme ties every image to the Dockerfile
revision that built it. Never point manifests at `:latest`.

After pushing, update the `CLIENT_IMAGE` default in `scripts/run.sh` (the one
place the blessed image tag lives); per-run override:
`CLIENT_IMAGE=<REGISTRY>/ubench-client:<tag> ./scripts/cloudlab/deploy.sh ... --run`.

To bump a pinned source: `--build-arg WRK2_SHA=<sha>` (or edit the Dockerfile
defaults).

## Build the application with poker runtime

Run the following command from the repo root with `BENCHMARK=<name>` where
name is one of `boutique`, `social`, `hotel`, and `movie`:

```
docker build --build-arg BENCHMARK=boutique -f scripts/PrebuiltDockerfile . -t yizhengx/ubench:boutique
```
