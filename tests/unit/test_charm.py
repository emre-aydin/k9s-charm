import base64

import ops
import pytest
import yaml
from ops import testing

from charm import KUBECONFIG_PATH, K9sCharm

TOKEN = "a-service-account-token"
CA_CERT = "-----BEGIN CERTIFICATE-----\nnot-a-real-cert\n-----END CERTIFICATE-----"
NAMESPACE = "test-model"


@pytest.fixture
def ctx():
    return testing.Context(K9sCharm)


@pytest.fixture
def service_account(tmp_path, monkeypatch):
    """Pretend the pod has service account credentials mounted."""
    (tmp_path / "token").write_text(TOKEN)
    (tmp_path / "ca.crt").write_text(CA_CERT)
    (tmp_path / "namespace").write_text(NAMESPACE)
    monkeypatch.setattr("charm.SERVICE_ACCOUNT_DIR", tmp_path)
    return tmp_path


@pytest.fixture
def missing_service_account(tmp_path, monkeypatch):
    monkeypatch.setattr("charm.SERVICE_ACCOUNT_DIR", tmp_path / "does-not-exist")


def test_kubeconfig_is_pushed(ctx, service_account, monkeypatch):
    monkeypatch.setenv("KUBERNETES_SERVICE_HOST", "10.152.183.1")
    monkeypatch.setenv("KUBERNETES_SERVICE_PORT_HTTPS", "443")
    container = testing.Container("k9s", can_connect=True)
    state_in = testing.State(containers={container})

    state_out = ctx.run(ctx.on.pebble_ready(container), state_in)

    fs = state_out.get_container("k9s").get_filesystem(ctx)
    kubeconfig = yaml.safe_load((fs / "root/.kube/config").read_text())

    cluster = kubeconfig["clusters"][0]["cluster"]
    assert cluster["server"] == "https://10.152.183.1:443"
    assert base64.b64decode(cluster["certificate-authority-data"]).decode() == CA_CERT
    assert kubeconfig["users"][0]["user"]["token"] == TOKEN
    assert kubeconfig["contexts"][0]["context"]["namespace"] == NAMESPACE
    assert kubeconfig["current-context"] == "juju-context"


def test_active_when_kubeconfig_written(ctx, service_account):
    container = testing.Container("k9s", can_connect=True)
    state_in = testing.State(containers={container})

    state_out = ctx.run(ctx.on.pebble_ready(container), state_in)

    assert isinstance(state_out.unit_status, ops.ActiveStatus)
    assert "juju ssh --container k9s" in state_out.unit_status.message


def test_falls_back_to_default_api_server(ctx, service_account, monkeypatch):
    monkeypatch.delenv("KUBERNETES_SERVICE_HOST", raising=False)
    monkeypatch.delenv("KUBERNETES_SERVICE_PORT_HTTPS", raising=False)
    monkeypatch.delenv("KUBERNETES_SERVICE_PORT", raising=False)
    container = testing.Container("k9s", can_connect=True)

    state_out = ctx.run(
        ctx.on.pebble_ready(container), testing.State(containers={container})
    )

    fs = state_out.get_container("k9s").get_filesystem(ctx)
    kubeconfig = yaml.safe_load((fs / "root/.kube/config").read_text())
    assert kubeconfig["clusters"][0]["cluster"]["server"] == "https://kubernetes.default.svc"


def test_blocked_without_service_account(ctx, missing_service_account):
    container = testing.Container("k9s", can_connect=True)

    state_out = ctx.run(
        ctx.on.pebble_ready(container), testing.State(containers={container})
    )

    assert isinstance(state_out.unit_status, ops.BlockedStatus)
    assert "no Kubernetes service account" in state_out.unit_status.message


def test_maintenance_when_container_unreachable(ctx, service_account):
    container = testing.Container("k9s", can_connect=False)

    state_out = ctx.run(
        ctx.on.update_status(), testing.State(containers={container})
    )

    assert isinstance(state_out.unit_status, ops.MaintenanceStatus)


def test_charm_defines_no_pebble_services(ctx, service_account):
    """The charm must stay inert: it should never start a workload."""
    container = testing.Container("k9s", can_connect=True)

    state_out = ctx.run(
        ctx.on.pebble_ready(container), testing.State(containers={container})
    )

    assert state_out.get_container("k9s").layers == {}


def test_kubeconfig_is_not_world_readable(ctx, service_account):
    container = testing.Container("k9s", can_connect=True)

    state_out = ctx.run(
        ctx.on.pebble_ready(container), testing.State(containers={container})
    )

    fs = state_out.get_container("k9s").get_filesystem(ctx)
    mode = (fs / "root/.kube/config").stat().st_mode & 0o777
    assert mode == 0o600, f"{KUBECONFIG_PATH} should be 0600, got {oct(mode)}"
