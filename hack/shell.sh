#!/usr/bin/env bash
# Loads a built .rock into the local Docker daemon and drops you into an
# interactive zsh shell inside it (bypassing Pebble/Juju entirely).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-k9s:local}"

ROCK="$(ls -1 "$REPO_ROOT"/*.rock 2>/dev/null | head -1 || true)"
if [ -z "$ROCK" ]; then
  echo "error: no .rock file found in $REPO_ROOT — run 'make build' first" >&2
  exit 1
fi

if ! command -v skopeo >/dev/null 2>&1; then
  echo "error: skopeo is required (brew install skopeo)" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "error: docker does not appear to be running" >&2
  exit 1
fi

echo "==> loading $ROCK into docker as $IMAGE_TAG" >&2
skopeo --insecure-policy copy "oci-archive:$ROCK" "docker-daemon:$IMAGE_TAG"

echo "==> starting interactive shell in $IMAGE_TAG" >&2
exec docker run --rm -it --entrypoint /usr/bin/zsh "$IMAGE_TAG"
