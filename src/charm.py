#!/usr/bin/env python3
"""A charm whose only purpose is to provide an interactive shell with k9s.

The charm intentionally runs no workload. Juju's own Pebble keeps the workload
container alive, so no Pebble service needs to be defined; all this charm does
is drop a usable kubeconfig into the container so that ``k9s`` works as soon as
an operator runs ``juju ssh --container k9s <unit>``.
"""

import base64
import logging
import os
import pathlib

import ops
import yaml

logger = logging.getLogger(__name__)

CONTAINER_NAME = "k9s"
KUBECONFIG_PATH = "/root/.kube/config"

# Where Kubernetes mounts the pod's service account credentials. The charm
# container and the workload container live in the same pod, so credentials
# read here are equally valid for the workload.
SERVICE_ACCOUNT_DIR = pathlib.Path("/var/run/secrets/kubernetes.io/serviceaccount")


class ServiceAccountUnavailableError(Exception):
    """Raised when the pod's service account credentials cannot be read."""


class K9sCharm(ops.CharmBase):
    """Provide a shell with k9s and a working kubeconfig."""

    def __init__(self, framework: ops.Framework):
        super().__init__(framework)
        self.framework.observe(self.on[CONTAINER_NAME].pebble_ready, self._reconcile)
        self.framework.observe(self.on.upgrade_charm, self._reconcile)
        self.framework.observe(self.on.update_status, self._reconcile)

    def _reconcile(self, _: ops.EventBase) -> None:
        container = self.unit.get_container(CONTAINER_NAME)
        if not container.can_connect():
            self.unit.status = ops.MaintenanceStatus("waiting for the k9s container")
            return

        try:
            kubeconfig = self._build_kubeconfig()
        except ServiceAccountUnavailableError as exc:
            logger.warning("could not build a kubeconfig: %s", exc)
            # The shell itself still works, there just are no cluster
            # credentials in it, so surface that instead of failing outright.
            self.unit.status = ops.BlockedStatus(
                f"no Kubernetes service account found, k9s has no cluster access ({exc})"
            )
            return

        container.push(
            KUBECONFIG_PATH,
            kubeconfig,
            permissions=0o600,
            make_dirs=True,
        )
        self.unit.status = ops.ActiveStatus(
            f"ready; run: juju ssh --container {CONTAINER_NAME} {self.unit.name}"
        )

    def _build_kubeconfig(self) -> str:
        """Render a kubeconfig from the pod's service account credentials."""
        token = self._read_service_account_file("token")
        ca_cert = self._read_service_account_file("ca.crt")
        namespace = self._read_service_account_file("namespace")

        config = {
            "apiVersion": "v1",
            "kind": "Config",
            "clusters": [
                {
                    "name": "juju-cluster",
                    "cluster": {
                        "server": self._api_server_url(),
                        "certificate-authority-data": base64.b64encode(
                            ca_cert.encode()
                        ).decode(),
                    },
                }
            ],
            "users": [
                {
                    "name": "juju-service-account",
                    "user": {"token": token},
                }
            ],
            "contexts": [
                {
                    "name": "juju-context",
                    "context": {
                        "cluster": "juju-cluster",
                        "user": "juju-service-account",
                        "namespace": namespace,
                    },
                }
            ],
            "current-context": "juju-context",
        }
        return yaml.safe_dump(config)

    def _read_service_account_file(self, name: str) -> str:
        path = SERVICE_ACCOUNT_DIR / name
        try:
            return path.read_text().strip()
        except OSError as exc:
            raise ServiceAccountUnavailableError(f"cannot read {path}") from exc

    @staticmethod
    def _api_server_url() -> str:
        """Return the in-cluster Kubernetes API server URL."""
        host = os.environ.get("KUBERNETES_SERVICE_HOST")
        port = os.environ.get("KUBERNETES_SERVICE_PORT_HTTPS") or os.environ.get(
            "KUBERNETES_SERVICE_PORT"
        )
        if host and port:
            # IPv6 addresses need bracketing in a URL.
            if ":" in host:
                host = f"[{host}]"
            return f"https://{host}:{port}"
        return "https://kubernetes.default.svc"


if __name__ == "__main__":  # pragma: nocover
    ops.main(K9sCharm)
