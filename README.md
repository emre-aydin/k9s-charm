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

## Reproducibility

What is pinned, and what isn't:

| Input | Pinned? | How |
|---|---|---|
| k9s binary | yes | exact version + per-arch SHA256 verified at build time in `rock/rockcraft.yaml` |
| `ops` (charm runtime) | yes | `ops==2.23.4` in `requirements.txt` — charmcraft resolves this at pack time, so a range would make two packs of the same source differ |
| Test toolchain | yes | `requirements-dev.txt` |
| GitHub Actions | yes | all `uses:` refs are full commit SHAs, including `canonical/craft-actions` |
| Workload image tag | yes | content hash of the built `.rock` (see below) |
| Build toolchain snaps | channel-pinned | `ROCKCRAFT_CHANNEL`, `CHARMCRAFT_CHANNEL`, `JUJU_CHANNEL`, `MICROK8S_CHANNEL` env vars in `hack/` |
| `ubuntu@26.04` base image | **no** | Rockcraft has no digest pinning for `base:` |
| apt packages in the rock | **no** | see below |

The last two are the real gaps. Deliberately not pinning apt versions: 26.04 is a development
release, and the archive drops superseded versions, so `zsh=5.9-x` pins would turn a
*reproducible* build into a *broken* one within weeks. If you need byte-identical rebuilds,
the practical answer is to build once and pin the **resulting image by digest** rather than
trying to make the build deterministic — which is what `hack/deploy.sh` does by tagging with
the `.rock` hash.

### How reproducible is it in practice?

Measured by packing the same source twice, back to back, in the same VM:

- The two `.rock` files are **not** bit-identical.
- But the **base image layers are identical**, the image `created` timestamp is identical
  (Rockcraft pins it to the base image, not to wall-clock time), and every file payload is
  byte-for-byte identical — `usr/bin/k9s`, `etc/zsh/zshenv`, `root/.zshrc`, `root/.shinit` all
  match.
- The only differences are **file mtimes** in the layers we build.

So the build is content-reproducible but not bit-reproducible. That's fine for the digest-
pinning approach above, and it means a rebuild can be diffed meaningfully: if anything other
than an mtime changes, an input genuinely changed.

This comparison also caught a real bug: `root/.zshrc` and `root/.shinit` were landing as
`root:nogroup` in some builds and `root:root` in others, because the `dump` plugin inherits the
build user's group. The `permissions:` block in the `shell-config` part now pins them.

## Other targets

```bash
make clean    # remove build artifacts
make vm-down  # delete the Multipass build VMs
```
