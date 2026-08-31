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
├── icon.svg             # Charmhub listing icon
├── rock/rockcraft.yaml  # the workload image (k9s + zsh)
├── hack/                # build / dev-environment scripts
└── Makefile
```

## The charm

| | |
|---|---|
| Name | `k9s-shell` |
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

From Charmhub, once published (see [Publishing to Charmhub](#publishing-to-charmhub)):

```bash
juju deploy k9s-shell --channel latest/edge --trust
```

Or from a locally built charm, supplying the image yourself:

```bash
juju deploy ./k9s-shell_ubuntu@24.04-<arch>.charm k9s-shell \
  --resource k9s-image=<registry>/k9s:<tag> \
  --trust
```

Then:

```bash
juju ssh --container k9s k9s-shell/0
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
make charm    # build the charm -> k9s-shell_ubuntu@24.04-<arch>.charm
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

## Publishing to Charmhub

Releases are manual: `.github/workflows/release.yaml` runs only on `workflow_dispatch`, so
landing on `main` never publishes anything. Pick a channel (default `latest/edge`) and run the
workflow; it packs the rock and the charm for `amd64` and `arm64`, uploads both, and releases
them.

Once published, deploying no longer needs a locally built image or an explicit `--resource`:

```bash
juju deploy k9s-shell --channel latest/edge --trust
```

### One-off setup

Both steps need a [Charmhub](https://charmhub.io/) account (an Ubuntu One SSO account) and can
only be done by a human — CI cannot bootstrap them.

**1. Register the name.** Names are first-come, first-served across all of Charmhub:

```bash
sudo snap install charmcraft --classic
charmcraft login
charmcraft register k9s-shell
```

**2. Mint the CI credentials.** `charmcraft login --export` writes a macaroon that the workflow
reads from `CHARMCRAFT_AUTH`. Scope it to this charm and to the permissions the workflow
actually uses, rather than exporting your full account credentials:

```bash
charmcraft login --export charmhub-auth.txt \
  --charm k9s-shell \
  --permission package-manage-revisions \
  --permission package-view-revisions \
  --permission package-manage-releases \
  --ttl 7776000   # 90 days, in seconds
```

`package-manage-revisions` covers the charm and resource uploads, `package-view-revisions` lets
`charmcraft upload` read back the revision review it polls (without it the upload fails with
`Missing required permission: package-view-revisions`), and `package-manage-releases` covers the
release itself.

Then store the file's contents **verbatim** as the `CHARMHUB_TOKEN` repository secret:

```bash
gh secret set CHARMHUB_TOKEN < charmhub-auth.txt
rm charmhub-auth.txt
```

`charmhub-auth.txt` is in `.gitignore`, but delete it anyway. The credential expires after the
`--ttl`, so this has to be repeated periodically; a release failing with an authentication
error is the usual reminder.

### How a release works

For each architecture, in this order:

1. `rockcraft pack` and `charmcraft pack`.
2. `charmcraft analyse` on the packed charm. Warnings are advisory and do not block; errors do.
3. `charmcraft upload` the charm. **This has to happen before the resource is uploaded** —
   Charmhub will only accept a resource that is declared in an already-uploaded revision of the
   charm, so the very first release necessarily uploads charm revision 1 first.
4. `charmcraft upload-resource k9s-shell k9s-image --image <path to the .rock>`. `--image` accepts a
   path to an OCI archive, so the rock goes straight to Charmhub's registry — no Docker daemon
   and no separate `skopeo` copy.
5. `charmcraft release`, binding the charm revision to the resource revision.

Charmhub resource revisions carry no architecture, but charm revisions do. Rather than building
a multi-arch manifest, each architecture's charm revision is released with the resource revision
built from the *same architecture's* rock. Juju resolves the charm revision matching the unit's
architecture and therefore gets a matching image.

### Promoting between channels

Releasing does not rebuild anything — it just points a channel at an existing revision. So
promotion is a re-release of the revisions already in `edge`:

```bash
charmcraft status k9s-shell   # lists revisions per channel/base/architecture
charmcraft release k9s-shell --revision=<amd64 rev> --channel=latest/candidate --resource=k9s-image:<rev>
charmcraft release k9s-shell --revision=<arm64 rev> --channel=latest/candidate --resource=k9s-image:<rev>
```

Note that each architecture is promoted separately, with the resource revision it was originally
released against — reusing one architecture's resource revision for the other would hand units
an image for the wrong architecture.

The charm stays on the default `latest` track. A dedicated track has to be requested from
Canonical and is not worth it here.

### Listing page

`title`, `summary`, `description` and `links` in `charmcraft.yaml` are pushed to Charmhub with
each revision and drive the listing page, as does `icon.svg`. Longer documentation lives on
[Charmhub's Discourse](https://discourse.charmhub.io/) rather than in this repo, and is linked
to the listing from the Charmhub web UI.

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

## License

Apache-2.0 — see [LICENSE](LICENSE). This matches the `license` declared in
`rock/rockcraft.yaml`. `k9s` itself is a separate upstream project with its own license; this
repo packages it but does not vendor or modify it.
