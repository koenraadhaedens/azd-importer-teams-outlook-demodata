import io
import json
from pathlib import Path
from uuid import uuid4

import pytest
from conftest import FakeGateway, sign_in
from fastapi import HTTPException
from fastapi.testclient import TestClient

from demo_loader.auth import Auth
from demo_loader.config import Settings
from demo_loader.security import redact


def test_auth_and_security_headers(client: TestClient) -> None:
    page = client.get("/")
    assert page.status_code == 200
    assert page.headers["referrer-policy"] == "same-origin"
    assert client.get("/runs/not-real/report").status_code == 401
    response = client.post("/upload")
    assert response.status_code == 401
    assert response.headers["x-frame-options"] == "DENY"
    assert "frame-ancestors 'none'" in response.headers["content-security-policy"]
    assert client.get("/", headers={"Host": "attacker.invalid"}).status_code == 400


def test_authorization_tenant_and_group_overage(settings: Settings, fake: FakeGateway) -> None:
    auth = Auth(settings, fake.ids)
    with pytest.raises(HTTPException):
        auth.authorize({"tid": str(uuid4()), "oid": str(settings.operator_ids[0])})
    with pytest.raises(HTTPException):
        auth.authorize({"tid": str(settings.tenant_id), "oid": str(uuid4())})
    auth.authorize({"tid": str(settings.tenant_id), "oid": fake.ids["adele"]})
    group = uuid4()
    settings.authorized_group_id = group
    claims = {"tid": str(settings.tenant_id), "oid": str(uuid4()), "groups": [str(group)]}
    auth.authorize(claims)
    claims["_claim_names"] = {"groups": "src1"}
    with pytest.raises(HTTPException):
        auth.authorize(claims)


def test_user_cannot_upload_or_start(
    client: TestClient, settings: Settings, fake: FakeGateway
) -> None:
    csrf = sign_in(client, fake.ids["adele"], str(settings.tenant_id))
    assert client.post("/upload", data={"csrf": csrf}).status_code == 403
    assert client.post("/runs/unknown/execute", data={"csrf": csrf}).status_code == 403


def test_upload_preview_dryrun_and_report(
    client: TestClient, settings: Settings, fake: FakeGateway
) -> None:
    csrf = sign_in(client, str(settings.operator_ids[0]), str(settings.tenant_id))
    content = Path("examples/demo-scenario.yaml").read_bytes()
    assert (
        client.post("/upload", files={"scenario": ("demo.yaml", content, "text/yaml")}).status_code
        == 403
    )
    response = client.post(
        "/upload",
        data={"csrf": csrf},
        files={"scenario": ("demo.yaml", content, "text/yaml")},
        follow_redirects=False,
    )
    assert response.status_code == 303
    path = response.headers["location"]
    page = client.get(path)
    assert page.status_code == 200 and "Planned Graph" in page.text
    assert "Progress by demo user" in page.text
    assert "Alex Wilber" in page.text
    dry = client.post(path + "/dry-run", data={"csrf": csrf})
    assert dry.json()["graphWrites"] == 0 and not fake.calls
    report = client.get(path + "/report")
    assert "body" not in report.text
    assert "access_token" not in report.text
    assert client.post(path + "/execute", data={"csrf": csrf, "confirm": "send"}).status_code == 400
    assert (
        client.post(
            "/upload", data={"csrf": csrf}, files={"scenario": ("demo.yaml", content, "text/yaml")}
        ).status_code
        == 400
    )


@pytest.mark.parametrize(
    ("filename", "mime", "size", "expected"),
    [
        ("bad.json", "text/yaml", 20, 400),
        ("bad.yaml", "application/json", 20, 400),
        ("bad.yaml", "application/octet-stream", 20, 400),
        ("big.yaml", "text/yaml", 65537, 413),
        ("big.yaml", "application/octet-stream", 65537, 413),
        ("huge.yaml", "text/yaml", 100000, 413),
    ],
)
def test_upload_boundary(
    client: TestClient, settings: Settings, filename: str, mime: str, size: int, expected: int
) -> None:
    csrf = sign_in(client, str(settings.operator_ids[0]), str(settings.tenant_id))
    response = client.post(
        "/upload",
        data={"csrf": csrf},
        files={"scenario": (filename, io.BytesIO(b"x" * size), mime)},
    )
    assert response.status_code == expected


@pytest.mark.parametrize("origin", ["https://evil.example", "null"])
def test_csrf_origin(client: TestClient, settings: Settings, origin: str) -> None:
    csrf = sign_in(client, str(settings.operator_ids[0]), str(settings.tenant_id))
    assert (
        client.post(
            "/logout", data={"csrf": csrf}, headers={"Origin": origin}
        ).status_code
        == 403
    )


@pytest.mark.parametrize(
    "mime",
    [
        "application/yaml",
        "application/x-yaml",
        "text/yaml",
        "text/x-yaml",
        "text/plain",
        "application/octet-stream",
    ],
)
def test_upload_same_origin(client: TestClient, settings: Settings, mime: str) -> None:
    csrf = sign_in(client, str(settings.operator_ids[0]), str(settings.tenant_id))
    users = [user.key for user in client.app.state.users.users]
    content = json.dumps(
        {
            "schemaVersion": "1.0",
            "scenarioId": "same-origin-upload",
            "title": "Same-origin upload",
            "author": "Test operator",
            "createdAt": "2026-10-01T09:00:00Z",
            "tenantAssumptions": ["Isolated demo tenant"],
            "requiredUsers": users,
            "activities": [
                {
                    "id": "email",
                    "type": "email",
                    "user": users[0],
                    "to": [users[1]],
                    "subject": "Fictional demo",
                    "body": "Fictional demo",
                }
            ],
        }
    ).encode()
    response = client.post(
        "/upload",
        data={"csrf": csrf},
        files={
            "scenario": (
                "demo.yaml",
                content,
                mime,
            )
        },
        headers={"Origin": settings.public_url},
        follow_redirects=False,
    )
    assert response.status_code == 303
    assert response.headers["referrer-policy"] == "same-origin"


def test_binary_mime_still_validates_yaml(client: TestClient, settings: Settings) -> None:
    csrf = sign_in(client, str(settings.operator_ids[0]), str(settings.tenant_id))
    response = client.post(
        "/upload",
        data={"csrf": csrf},
        files={"scenario": ("demo.yaml", b"\x00\xff", "application/octet-stream")},
        headers={"Origin": settings.public_url},
    )
    assert response.status_code == 400
    assert response.json()["detail"] == "Invalid or excessively nested YAML"


def test_secret_redaction() -> None:
    value = redact('Bearer confidential access_token="secret" client_secret=hidden password=pass')
    for secret in ("confidential", '"secret"', "hidden", "pass "):
        assert secret not in value
    assert "[REDACTED]" in value
