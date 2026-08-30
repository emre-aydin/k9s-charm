#!/usr/bin/env bash
# Builds the k9s rock inside a Multipass Ubuntu VM.
#
# Rockcraft only ships as a Linux snap, so on macOS (or any host without
# rockcraft installed) this script spins up (or reuses) a Multipass VM,
# syncs the project into it, runs `rockcraft pack` there, and copies the
# resulting .rock file(s) back to the repo root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_NAME="${ROCKCRAFT_VM:-k9s-rockcraft-build}"
VM_IMAGE="${ROCKCRAFT_VM_IMAGE:-26.04}"
REMOTE_DIR="/home/ubuntu/k9s-charm"
REMOTE_ROCK_DIR="$REMOTE_DIR/rock"

log() { echo "==> $*" >&2; }

if ! command -v multipass >/dev/null 2>&1; then
  echo "error: multipass is required (brew install --cask multipass)" >&2
  exit 1
fi

if ! multipass info "$VM_NAME" >/dev/null 2>&1; then
  log "launching build VM '$VM_NAME' ($VM_IMAGE)"
  multipass launch "$VM_IMAGE" --name "$VM_NAME" --cpus 4 --memory 6G --disk 25G

  log "installing rockcraft"
  multipass exec "$VM_NAME" -- sudo snap install rockcraft --classic

  log "initializing LXD (used by rockcraft to build)"
  multipass exec "$VM_NAME" -- sudo lxd init --auto
fi

if ! multipass list --format csv | grep -q "^${VM_NAME},Running,"; then
  log "starting VM '$VM_NAME'"
  multipass start "$VM_NAME"
fi

log "syncing project into VM"
multipass exec "$VM_NAME" -- mkdir -p "$REMOTE_DIR"
(cd "$REPO_ROOT" && multipass transfer -r . "$VM_NAME:$REMOTE_DIR")

log "removing stale .rock artifacts in VM"
multipass exec "$VM_NAME" -- sh -c "rm -f '$REMOTE_ROCK_DIR'/*.rock"

log "running rockcraft pack"
multipass exec "$VM_NAME" -- sh -c "cd '$REMOTE_ROCK_DIR' && sudo rockcraft pack"

log "fetching built rock(s)"
ROCKS="$(multipass exec "$VM_NAME" -- sh -c "cd '$REMOTE_ROCK_DIR' && ls -1 *.rock")"
for rock in $ROCKS; do
  multipass transfer "$VM_NAME:$REMOTE_ROCK_DIR/$rock" "$REPO_ROOT/$rock"
  log "built $REPO_ROOT/$rock"
done
