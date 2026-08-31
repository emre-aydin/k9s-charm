# k9s-charm

A Juju Kubernetes sidecar charm that drops an operator into an interactive shell with
[k9s](https://k9scli.io/) preinstalled. It runs **no workload**, has **no relations, config,
or storage** by design — its only job is to be `juju ssh`-able with a working kubeconfig.

Two things are built from this repo:
- **The charm** (`src/charm.py`, `charmcraft.yaml`) — the Juju operator, written against `ops`.
- **The rock** (`rock/rockcraft.yaml`) — the OCI workload image (k9s + zsh) shipped as the
  charm's `k9s-image` resource.

## Build, test, lint

```bash
make unit     # run the charm unit tests (creates .venv from requirements-dev.txt)
make build    # build the rock  -> k9s_<version>_<arch>.rock
make charm    # build the charm -> k9s-shell_ubuntu@24.04-<arch>.charm
make clean    # remove build artifacts (*.rock, *.charm, build/, .venv, caches)
```

- **Unit tests are the only CI gate that runs on every push/PR** (`.github/workflows/build-charm.yaml`).
- Run a single test: `./.venv/bin/python -m pytest tests/unit/test_charm.py::test_kubeconfig_is_pushed -q`
- Tests use `ops-scenario` (`ops[testing]`) state-transition testing, not a live cluster —
  `ctx.run(ctx.on.pebble_ready(container), state_in)` and assert on `state_out`.
- There is no configured linter/formatter; don't invent one.
- `rockcraft`/`charmcraft` are Linux-only snaps. On macOS `make build` transparently falls back
  to a Multipass VM (`hack/`); `make charm` does not and requires `make dev-vm` first.

## Architecture / key behaviors

- **The charm is deliberately inert.** It defines no Pebble layer or service — Juju's own Pebble
  (PID 1) keeps the container alive. `test_charm_defines_no_pebble_services` guards this invariant;
  never add a service to make the container stay up.
- **Reconcile pattern:** all three observed events (`pebble_ready`, `upgrade_charm`,
  `update_status`) route to a single idempotent `_reconcile`. `update_status`/`upgrade_charm` act
  as cheap self-heal. New behavior generally belongs in `_reconcile`, not new handlers.
- **What `_reconcile` does:** reads the pod's service account from
  `/var/run/secrets/kubernetes.io/serviceaccount/` (`SERVICE_ACCOUNT_DIR`) and pushes a rendered
  kubeconfig to `/root/.kube/config` (mode `0600`) in the workload container. The charm and
  workload share a pod, so those credentials are valid for the workload.
- **Status semantics are load-bearing** (asserted by tests): container unreachable →
  `MaintenanceStatus`; no service account → `BlockedStatus` (shell still works, just no cluster
  access — never raise/crash instead); success → `ActiveStatus` with the `juju ssh` hint.

## Rock conventions

- **Landing in zsh:** Juju runs `/bin/sh` on `juju ssh --container`, ignoring `/etc/passwd`. The
  rock sets `ENV=/root/.shinit` so `dash` sources it for *interactive* shells only, and that file
  `exec`s zsh. Non-interactive `juju ssh ... 'cmd'` stays on plain `sh`. Shell config lives in
  `rock/files/` (`zshenv`, `zshrc`, `shinit`).
- **Bumping k9s:** update `version` in `rock/rockcraft.yaml` **and** both per-arch `K9S_SHA256`
  sums (from the release's `checksums.sha256`). The build verifies the download against them.
- **File permissions in the rock are pinned explicitly** (`permissions:` in `shell-config`)
  because the `dump` plugin otherwise inherits the build user's group and varies between builds.

## Reproducibility (a core design goal — see README "Reproducibility")

- `ops` is pinned exactly (`ops==2.23.4`) in both `requirements.txt` and `requirements-dev.txt`;
  charmcraft resolves it at pack time, so a range would make two packs differ. Keep it pinned.
- All GitHub Actions `uses:` refs are full commit SHAs. Preserve this when editing workflows.
- The k9s binary is version- and SHA-pinned. Base image and apt packages are intentionally
  *not* pinned (26.04 is a dev release); the digest-pinning happens on the resulting image instead.

## Releasing

Releases are manual: `.github/workflows/release.yaml` runs only on `workflow_dispatch`; landing
on `main` never publishes. It packs both arches, uploads the charm revision **before** the
resource (Charmhub requires the resource be declared in an uploaded revision), then releases.
Each arch's charm revision is paired with the same arch's rock. See README "Publishing to
Charmhub" for the full flow and CI credential (`CHARMHUB_TOKEN`) setup.
