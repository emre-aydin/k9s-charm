# k9s-charm

A Juju Kubernetes charm that gives you a shell with [k9s](https://k9scli.io/) in it, for
debugging the cluster your Juju applications are deployed on.

The charm does **nothing** on its own — it runs no workload, exposes no relations and has no
configuration. Its only purpose is to be a place you can `juju ssh` into.

```
.
├── charmcraft.yaml      # the charm
├── src/charm.py
├── tests/unit/
├── rock/rockcraft.yaml  # the workload image (k9s + zsh)
├── hack/                # build / dev-environment scripts
└── Makefile
```

## The charm

| | |
|---|---|
| Name | `k9s` |
| Type | Kubernetes sidecar charm |
| Containers | `k9s`, backed by the `k9s-image` OCI resource (the rock below) |
| Relations / config / storage | none, by design |
| Workload services | none — see [No workload](#no-workload) |

On `pebble-ready` (and on `upgrade-charm` / `update-status` as a cheap self-heal) the charm
reads the pod's Kubernetes service account from
`/var/run/secrets/kubernetes.io/serviceaccount/` and writes a kubeconfig to
`/root/.kube/config` (mode `0600`) in the workload container, so `k9s` works the moment you
land in the shell.

### Deploying

```bash
juju deploy ./k9s_ubuntu@24.04-<arch>.charm k9s \
  --resource k9s-image=<registry>/k9s:<tag> \
  --trust
```

Then:

```bash
juju ssh --container k9s k9s/0
```

That drops you straight into `zsh`, with `k9s` on `PATH` and `KUBECONFIG` already pointing at
the generated config. Just run `k9s`.

### `--trust`

`--trust` is what gives the charm's service account cluster-wide permissions. Without it the
generated kubeconfig is limited to the model's own namespace, so k9s will only see the
resources of that one model. The charm still deploys and is still shell-able either way; if
the service account isn't available at all the charm goes `blocked` with an explanatory
message rather than failing.

### No workload

The charm deliberately defines no Pebble layer and no service. Juju's own Pebble runs as PID 1
in the workload container, so the container stays alive with nothing defined. A unit test
asserts this invariant. (The rock keeps its own `sleep infinity` service purely so that it is
also usable standalone under `docker run`.)

### Interactive shell details

Juju starts `/bin/sh` when you `juju ssh --container`, ignoring the login shell configured in
`/etc/passwd`. The rock therefore sets `ENV=/root/.shinit` in the image environment — `dash`
sources `$ENV` for *interactive* shells only — and that file `exec`s `zsh`. Non-interactive
invocations such as `juju ssh ... 'some command'` are unaffected and keep running under plain
`sh`.

## The k9s rock

`rock/rockcraft.yaml` builds the [rock](https://documentation.ubuntu.com/rockcraft/) used as
the charm's workload container.

| | |
|---|---|
| Base | `ubuntu@26.04` |
| Architectures | `amd64`, `arm64` |
| Contents | `k9s` (pinned upstream release, SHA256-verified), `zsh`, `bash`, `less`, `vim-tiny`, `ncurses-term` |
| Pebble service | `k9s` — `sleep infinity`, for standalone use outside Juju |

### Bumping the k9s version

Update `version` in `rock/rockcraft.yaml` and the per-architecture SHA256 sums in the `k9s`
part. The checksums come from the `checksums.sha256` asset of the corresponding
[k9s release](https://github.com/derailed/k9s/releases).

## Building

Rockcraft and charmcraft only run on Linux (they are distributed as snaps). On macOS the build
targets transparently fall back to a [Multipass](https://multipass.run/) VM — install it first
with `brew install --cask multipass`.

```bash
make build    # build the rock  -> k9s_<version>_<arch>.rock (OCI archive)
make charm    # build the charm -> k9s_ubuntu@24.04-<arch>.charm
make unit     # run the charm unit tests
```

Or manually:

```bash
sudo snap install rockcraft --classic
sudo snap install charmcraft --classic
(cd rock && rockcraft pack)
charmcraft pack
```

### Trying the rock without Juju

`make shell` does this for you (needs `skopeo` and a running Docker):

```bash
skopeo --insecure-policy copy \
  oci-archive:k9s_0.51.0_arm64.rock docker-daemon:k9s:local

docker run --rm -it --entrypoint /usr/bin/zsh k9s:local
```

## End-to-end testing

`hack/dev-vm.sh` provisions a Multipass VM with microk8s, Juju, charmcraft and rockcraft;
`hack/deploy.sh` then builds the rock and charm inside it, pushes the image to the microk8s
registry and deploys the charm with `--trust`.

```bash
make dev-vm
make deploy

multipass shell k9s-dev
juju ssh --container k9s k9s/0 -m k9s-test
```

The image is tagged with the hash of the built `.rock`. A fixed tag such as `latest` would make
Juju treat the OCI resource as unchanged on `juju refresh`, silently keeping the old pod.

## Other targets

```bash
make clean    # remove build artifacts
make vm-down  # delete the Multipass build VM
```
