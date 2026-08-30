#!/usr/bin/env bash
# Provisions a Multipass VM with microk8s, Juju, charmcraft and rockcraft so the
# charm can be deployed and tested end to end. Idempotent-ish: skips the launch
# if the VM already exists.
set -euo pipefail

VM_NAME="${DEV_VM:-k9s-dev}"
VM_IMAGE="${DEV_VM_IMAGE:-24.04}"

log() { echo "==> $*" >&2; }

if ! multipass info "$VM_NAME" >/dev/null 2>&1; then
  log "launching $VM_NAME"
  multipass launch "$VM_IMAGE" --name "$VM_NAME" --cpus 4 --memory 8G --disk 40G
fi

if ! multipass list --format csv | grep -q "^${VM_NAME},Running,"; then
  multipass start "$VM_NAME"
fi

log "installing snaps"
# Juju 3.6 only works with strictly confined microk8s, hence the -strict channel.
multipass exec "$VM_NAME" -- sudo snap install microk8s --channel="${MICROK8S_CHANNEL:-1.35-strict/stable}"
multipass exec "$VM_NAME" -- sudo snap install juju
multipass exec "$VM_NAME" -- sudo snap install charmcraft --classic
multipass exec "$VM_NAME" -- sudo snap install rockcraft --classic

log "configuring microk8s"
multipass exec "$VM_NAME" -- sudo usermod -a -G snap_microk8s ubuntu
multipass exec "$VM_NAME" -- sudo microk8s status --wait-ready --timeout 300
multipass exec "$VM_NAME" -- sudo microk8s enable hostpath-storage
multipass exec "$VM_NAME" -- sudo microk8s enable registry
multipass exec "$VM_NAME" -- sudo microk8s status --wait-ready --timeout 300

log "writing kubeconfig"
multipass exec "$VM_NAME" -- mkdir -p /home/ubuntu/.kube
multipass exec "$VM_NAME" -- sh -c 'sudo microk8s config | tee /home/ubuntu/.kube/config > /dev/null'
multipass exec "$VM_NAME" -- chmod 600 /home/ubuntu/.kube/config

log "initialising LXD for rockcraft/charmcraft"
multipass exec "$VM_NAME" -- sudo lxd init --auto

log "done"
