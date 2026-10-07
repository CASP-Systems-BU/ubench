#!/usr/bin/env bash
#
# setup-stratus.sh - install & verify Stratus Red Team on a fresh CloudLab node.
#
# Run ON node-0 (where kubectl is live), AFTER bootstrap.sh, any time before you
# want to detonate. Idempotent: safe to re-run.
#
# Deployed automatically by `./bootstrap.sh stratus`, run from your workstation
# (copies this file to node-0 alongside the rest of scripts/cloudlab/, then
# executes it there over ssh). Not part of the default `./bootstrap.sh` (`all`)
# flow — opt in explicitly when you actually want Stratus on the cluster.
#
# Stratus is a CLI run *from* this node against the cluster kubectl points at.
# It is NOT deployed into the cluster. This script installs the binary and
# preflight-checks that the cluster is reachable and the current identity can
# actually run the Kubernetes techniques.
#
# Overrides (env):
#   STRATUS_VERSION   pinned release tag, or "latest"   (default: v2.16.0)
#   INSTALL_DIR       where to place the binary          (default: /usr/local/bin)
#
set -euo pipefail
 
STRATUS_VERSION="${STRATUS_VERSION:-v2.37.0}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
 
# ---- logging (matches the deploy.sh [*]/[OK] style) ------------------------
log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }
 
# ---- 0. required tools -----------------------------------------------------
for cmd in curl tar kubectl uname sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done
 
SUDO=""
[ -w "$INSTALL_DIR" ] || SUDO="sudo"
 
# ---- 1. cluster preflight --------------------------------------------------
# Everything Stratus does hits THIS cluster. Fail loudly if it's not the one.
log "Checking cluster connectivity..."
kubectl cluster-info >/dev/null 2>&1 \
  || die "kubectl can't reach a cluster — run bootstrap.sh first / check KUBECONFIG"
 
CTX="$(kubectl config current-context 2>/dev/null || echo '?')"
API="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo '?')"
ok "context: ${CTX}"
ok "api:     ${API}   <-- Stratus will attack THIS cluster"
 
# Techniques create cluster-scoped resources; confirm the identity can.
log "Checking RBAC (do we have the perms techniques need?)..."
rbac_ok=true
for res in "pods" "serviceaccounts" "secrets" "clusterroles"; do
  if kubectl auth can-i create "$res" >/dev/null 2>&1; then
    ok "can create ${res}"
  else
    warn "cannot create ${res} — some techniques will fail with 'forbidden'"
    rbac_ok=false
  fi
done
$rbac_ok || warn "current identity is not cluster-admin; expect partial coverage"
 
# ---- 2. resolve version & arch ---------------------------------------------
if [ "$STRATUS_VERSION" = "latest" ]; then
  log "Resolving latest release tag..."
  STRATUS_VERSION="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      https://github.com/DataDog/stratus-red-team/releases/latest \
      | sed 's#.*/tag/##')"
  [ -n "$STRATUS_VERSION" ] || die "couldn't resolve latest tag"
  ok "latest is ${STRATUS_VERSION}"
fi
 
case "$(uname -m)" in
  x86_64|amd64)   ARCH="x86_64" ;;
  aarch64|arm64)  ARCH="arm64" ;;
  *)              die "unsupported arch: $(uname -m)" ;;
esac
 
# ---- 3. install stratus (idempotent) ---------------------------------------
want="${STRATUS_VERSION#v}"   # strip leading v for comparison
have=""
if command -v stratus >/dev/null 2>&1; then
  have="$(stratus version 2>/dev/null || true)"
fi
 
if printf '%s' "$have" | grep -q -- "$want"; then
  ok "stratus ${STRATUS_VERSION} already installed — skipping download"
else
  log "Installing stratus ${STRATUS_VERSION} (${ARCH})..."
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
 
  asset="stratus-red-team_Linux_${ARCH}.tar.gz"
  url="https://github.com/DataDog/stratus-red-team/releases/download/${STRATUS_VERSION}/${asset}"
 
  curl -fSL --retry 3 -o "$tmp/$asset" "$url" \
    || die "download failed: $url (bad version tag, or no egress to github.com?)"
 
  # Print the digest so you can eyeball it against the release's checksums.txt.
  ok "sha256: $(sha256sum "$tmp/$asset" | awk '{print $1}')"
 
  tar -xzf "$tmp/$asset" -C "$tmp"
  [ -f "$tmp/stratus" ] || die "archive did not contain a 'stratus' binary"
 
  $SUDO install -m 0755 "$tmp/stratus" "${INSTALL_DIR}/stratus"
  ok "installed to ${INSTALL_DIR}/stratus"
fi
 
# ---- 4. verify the binary runs ---------------------------------------------
log "Verifying stratus..."
stratus version || die "stratus installed but won't run"
n="$(stratus list --platform kubernetes 2>/dev/null | grep -oE 'k8s\.[A-Za-z0-9_.-]+' | sort -u | wc -l)"
ok "stratus sees ${n} Kubernetes techniques"
 
# ---- 5. egress soft-check (first 'warmup' downloads Terraform) -------------
# Stratus downloads its own Terraform into ~/.stratus-red-team on first warmup.
log "Checking egress for the one-time Terraform download..."
if curl -fsSI --max-time 5 https://releases.hashicorp.com >/dev/null 2>&1; then
  ok "releases.hashicorp.com reachable"
else
  warn "releases.hashicorp.com unreachable — first 'stratus warmup' may hang"
fi
 
# ---- done ------------------------------------------------------------------
cat <<EOF
 
[*] Stratus Red Team ready on $(hostname).
 
    Browse:        stratus list --platform kubernetes
    Inspect:       stratus show k8s.persistence.create-token
    Detonate:      stratus detonate k8s.persistence.create-token --cleanup
 
    (first 'warmup'/'detonate' pauses once to fetch Terraform — expected)
EOF