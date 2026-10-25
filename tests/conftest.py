from __future__ import annotations

from pathlib import Path
from typing import Any
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from demo_loader.app import create_app
from demo_loader.config import Settings
from demo_loader.models import Activity, Users
from demo_loader.validation import load_yaml


class FakeGateway:
    def __init__(self) -> None:
        self.ids = {key: str(uuid4()) for key in ("adele", "alex", "christie", "diego", "megan")}
        self.calls: list[tuple[str, str | None]] = []

    async def resolve_users(self, users: Users) -> dict[str, str]:
        return self.ids

    async def execute(
        self,
        action: Activity,
        delegated_token: str | None,
        parent_id: str | None,
        correlation_id: str,
    ) -> str | None:
        self.calls.append((action.id, delegated_token))
        return "remote-" + action.id


@pytest.fixture
def raw_scenario() -> dict[str, Any]:
    raw = load_yaml(Path("examples/demo-scenario.yaml").read_bytes())
    for action in raw["activities"]:
        action["delaySeconds"] = 0
    return raw


@pytest.fixture
def fake() -> FakeGateway:
    return FakeGateway()


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        _env_file=None,
        tenant_id=uuid4(),
        web_client_id=uuid4(),
        operator_ids=[uuid4()],
        demo_tenant_confirmed=True,
        delivery_enabled=True,
        mailbox_scope_confirmed=True,
        data_dir=tmp_path,
    )


@pytest.fixture
def client(settings: Settings, fake: FakeGateway):
    with TestClient(create_app(settings, fake), base_url="http://localhost:8000") as client:
        yield client


def sign_in(client: TestClient, oid: str, tenant: str) -> str:
    auth = client.app.state.auth
    key, session = auth.new()
    session.claims = {"oid": oid, "tid": tenant, "name": "Fictional tester"}
    client.cookies.set("demo_session", key)
    return session.csrf
