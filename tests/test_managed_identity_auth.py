from unittest.mock import Mock
from uuid import uuid4

import pytest
from azure.core.credentials import AccessToken
from conftest import FakeGateway
from fastapi.testclient import TestClient

from demo_loader.app import create_app
from demo_loader.auth import Auth, Session
from demo_loader.config import Settings


def test_msal_receives_lazy_assertion_not_a_secret(
    settings: Settings, fake: FakeGateway, monkeypatch: pytest.MonkeyPatch
) -> None:
    constructor = Mock()
    monkeypatch.setattr("demo_loader.auth.msal.ConfidentialClientApplication", constructor)
    assertion = Mock(return_value="synthetic-assertion")
    auth = Auth(settings, fake.ids, assertion)
    session = Session()
    auth.client(session)
    assertion.assert_not_called()
    credentials = constructor.call_args.kwargs["client_credential"]
    assert set(credentials) == {"client_assertion"}
    assert credentials["client_assertion"]() == "synthetic-assertion"
    assert constructor.call_args.kwargs["token_cache"] is session.cache


def test_runtime_uses_assigned_identity_for_web_assertion(
    settings: Settings, fake: FakeGateway, monkeypatch: pytest.MonkeyPatch
) -> None:
    settings.managed_identity_client_id = uuid4()
    credential = Mock()
    credential.get_token.return_value = AccessToken("synthetic-assertion", 9999999999)
    factory = Mock(return_value=credential)
    monkeypatch.setattr("demo_loader.app.ManagedIdentityCredential", factory)
    constructor = Mock()
    monkeypatch.setattr("demo_loader.auth.msal.ConfidentialClientApplication", constructor)
    with TestClient(create_app(settings, fake)) as client:
        auth = client.app.state.auth
        auth.client(Session())
        callback = constructor.call_args.kwargs["client_credential"]["client_assertion"]
        assert callback() == "synthetic-assertion"
        credential.get_token.assert_called_with("api://AzureADTokenExchange/.default")
        factory.assert_called_once_with(client_id=str(settings.managed_identity_client_id))
    credential.close.assert_called_once()


def test_no_secret_or_default_credential_fallback(settings: Settings, fake: FakeGateway) -> None:
    with pytest.raises(RuntimeError, match="ACI managed identity"):
        Auth(settings, fake.ids).client(Session())
    with pytest.raises(RuntimeError, match="MANAGED_IDENTITY_CLIENT_ID"):
        with TestClient(create_app(settings)):
            pass
