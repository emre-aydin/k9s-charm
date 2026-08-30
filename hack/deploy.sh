#!/usr/bin/env bash
# Builds the rock and the charm inside the dev VM, imports the image into
# microk8s, and deploys the charm with Juju.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_NAME="${DEV_VM:-k9s-dev}"
REMOTE_DIR="/home/ubuntu/k9s-charm"
MODEL="${JUJU_MODEL:-k9s-test}"
APP="${JUJU_APP:-k9s}"

log() { echo "==> $*" >&2; }
vm() { multipass exec "$VM_NAME" -- "$@"; }
vmsh() { multipass exec "$VM_NAME" -- sh -c "$1"; }

if ! multipass info "$VM_NAME" >/dev/null 2>&1; then
  echo "error: dev VM '$VM_NAME' not found; run 'make dev-vm' first" >&2
  exit 1
fi

log "syncing project into VM"
vm mkdir -p "$REMOTE_DIR"
(cd "$REPO_ROOT" && multipass transfer -r . "$VM_NAME:$REMOTE_DIR")

log "building the rock"
vmsh "cd '$REMOTE_DIR/rock' && rm -f ./*.rock && sudo rockcraft pack"

log "waiting for the microk8s registry to be ready"
vmsh "sudo microk8s kubectl -n container-registry rollout status deployment/registry --timeout=5m"
vmsh "for i in \$(seq 1 60); do
        curl -sf -o /dev/null http://127.0.0.1:32000/v2/ && exit 0
        sleep 5
      done
      echo 'registry did not become reachable on 127.0.0.1:32000' >&2; exit 1"

log "importing the rock into the microk8s registry"
ROCK="$(vmsh "cd '$REMOTE_DIR/rock' && ls -1 *.rock | head -1")"
# Tag the image by its content hash. Reusing a fixed tag such as `latest`
# makes Juju treat the OCI resource as unchanged on `juju refresh`, so the
# pod is never recreated and rock changes silently don't take effect.
TAG="$(vmsh "cd '$REMOTE_DIR/rock' && sha256sum '${ROCK}' | cut -c1-12")"
IMAGE="127.0.0.1:32000/k9s:${TAG}"
log "image tag: $IMAGE"
vmsh "cd '$REMOTE_DIR/rock' && sudo rockcraft.skopeo --insecure-policy copy \
  oci-archive:${ROCK} docker://${IMAGE} --dest-tls-verify=false"

log "building the charm"
vmsh "cd '$REMOTE_DIR' && rm -f ./*.charm && charmcraft pack"

log "bootstrapping juju onto microk8s (if needed)"
vmsh "juju controllers 2>/dev/null | grep -q micro || juju bootstrap microk8s micro"

log "creating model $MODEL (if needed)"
vmsh "juju show-model '$MODEL' >/dev/null 2>&1 || juju add-model '$MODEL'"

log "deploying"
ARCH="$(vmsh "dpkg --print-architecture")"
CHARM="$(vmsh "cd '$REMOTE_DIR' && ls -1 *-${ARCH}.charm 2>/dev/null | head -1")"
if [ -z "$CHARM" ]; then
  echo "error: no .charm built for architecture '$ARCH'" >&2
  exit 1
fi
log "using $CHARM (arch $ARCH)"
vmsh "cd '$REMOTE_DIR' && juju deploy ./${CHARM} '$APP' \
  --resource k9s-image=${IMAGE} \
  --constraints arch=${ARCH} \
  --trust -m '$MODEL' 2>/dev/null || \
  juju refresh '$APP' -m '$MODEL' --path ./${CHARM} \
  --resource k9s-image=${IMAGE}"

log "waiting for the application to become active"
vmsh "juju wait-for application '$APP' -m '$MODEL' --timeout 10m --query='status==\"active\"'" || true

vmsh "juju status -m '$MODEL'"

cat >&2 <<EOF

==> deployed. To get a shell:

    multipass shell $VM_NAME
    juju ssh --container k9s $APP/0 -m $MODEL

EOF
