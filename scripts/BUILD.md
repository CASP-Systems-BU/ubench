# Build the client (load-generator) image

The client pod image carries `/wrk2/wrk` (pinned giltene/wrk2) and the rust
request-mix proxy. The Lua request mixes are **not** in the image — they live
in `client/lua/` and are mounted via the `wrk-scripts` ConfigMap by
`scripts/run.sh`, so editing a mix never needs a rebuild.

## CI (the normal path)

GitHub Actions builds and pushes the image to the GitHub Container Registry on
every push to `main` that touches `client/**` or `scripts/ClientDockerfile`
(workflow: [.github/workflows/client-image.yml](../.github/workflows/client-image.yml);
manual trigger available under the Actions tab). Each run pushes:

- `ghcr.io/casp-systems-bu/wrk2-client:<YYYYMMDD>-g<shortsha>` — immutable,
  use this to pin a reproducible experiment (`CLIENT_IMAGE=... ./deploy.sh ...`)
- `ghcr.io/casp-systems-bu/wrk2-client:latest` — tracks main; the default in
  `scripts/run.sh` (client.yaml uses `imagePullPolicy: Always` so nodes don't
  serve a stale cache of it)

**One-time setup after the first CI push:** the GHCR package is created
private. Make it public so CloudLab kubelets can pull anonymously:
GitHub → the org's Packages → `wrk2-client` → Package settings →
Change visibility → Public. (Otherwise every cluster needs an imagePullSecret.)

## Building locally (fallback)

From the **repo root**, with `client/` as the build context (the Dockerfile
COPYs `./proxy` relative to the context):

```bash
TAG="$(date -u +%Y%m%d)-g$(git rev-parse --short HEAD)"
docker build --platform linux/amd64 -f scripts/ClientDockerfile client/ \
    -t ghcr.io/casp-systems-bu/wrk2-client:${TAG}
docker push ghcr.io/casp-systems-bu/wrk2-client:${TAG}
```

(`docker login ghcr.io` with a GitHub PAT that has `write:packages` first.)

To bump a pinned source: `--build-arg WRK2_SHA=<sha>` (or edit the Dockerfile
defaults).

## Build the application with poker runtime

Run the following command from the repo root with `BENCHMARK=<name>` where
name is one of `boutique`, `social`, `hotel`, and `movie`:

```
docker build --build-arg BENCHMARK=boutique -f scripts/PrebuiltDockerfile . -t yizhengx/ubench:boutique
```
