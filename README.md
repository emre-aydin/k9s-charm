# k9s-charm

A Juju charm to run [k9s](https://k9scli.io/) for debugging Juju applications deployed on
Kubernetes.

## The k9s rock

`rockcraft.yaml` builds a [rock](https://documentation.ubuntu.com/rockcraft/) that is intended
to be used as the workload container of the (upcoming) sidecar charm.

| | |
|---|---|
| Base | `ubuntu@26.04` |
| Architectures | `amd64`, `arm64` |
| Contents | `k9s` (pinned upstream release), `zsh` (root's login shell), `bash`, `less`, `vim-tiny`, `ncurses-term` |
| Pebble service | `k9s` — `sleep infinity`, so the container stays alive and can be exec'd into |

### Building

Rockcraft only runs on Linux (it is distributed as a snap):

```bash
sudo snap install rockcraft --classic
rockcraft pack
```

This produces `k9s_<version>_<arch>.rock`, an OCI archive.

### Running locally

```bash
sudo rockcraft.skopeo --insecure-policy copy \
  oci-archive:k9s_0.51.0_amd64.rock docker-daemon:k9s:0.51.0

docker run --rm -it --entrypoint /usr/bin/zsh k9s:0.51.0
```

To exercise it the way Juju does, run the default entrypoint (Pebble) and exec into it:

```bash
docker run -d --name k9s k9s:0.51.0
docker exec -it k9s /usr/bin/pebble exec -it /usr/bin/zsh
```

### Getting an interactive shell in Kubernetes

Once deployed as a charm workload container:

```bash
juju ssh --container k9s <unit>
# or, directly through Pebble
kubectl exec -it <pod> -c k9s -- /usr/bin/pebble exec -it /usr/bin/zsh
```

`k9s` is on `PATH` and `KUBECONFIG` defaults to `/root/.kube/config`, which the charm is
expected to provide.

### Bumping the k9s version

Update `version` in `rockcraft.yaml` and the per-architecture SHA256 sums in the `k9s` part.
The checksums come from the `checksums.sha256` asset of the corresponding
[k9s release](https://github.com/derailed/k9s/releases).
