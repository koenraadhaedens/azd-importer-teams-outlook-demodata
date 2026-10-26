import asyncio
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock
from uuid import uuid4

import pytest
from conftest import FakeGateway, sign_in
from fastapi.testclient import TestClient

from demo_loader.auth import Auth, Session, TeamsAuthorizationError
from demo_loader.config import Settings
from demo_loader.engine import Engine
from demo_loader.graph import GraphError
from demo_loader.journal import Journal
from demo_loader.models import Scenario


def conversation() -> Scenario:
    activities = [
        {
            "id": "email-start",
            "type": "email",
            "user": "adele",
            "to": ["alex"],
            "subject": "Fictional kickoff",
            "body": "Fictional kickoff",
        }
    ]
    previous = "email-start"
    users = ["adele", "alex", "christie", "diego", "megan"]
    for index, user in enumerate(users * 2):
        action_id = f"teams-{index}"
        activities.append(
            {
                "id": action_id,
                "type": "teamsMessage",
                "user": user,
                "channel": "launch",
                "body": "Fictional conversation",
                "dependsOn": [previous],
            }
        )
        previous = action_id
    activities.append(
        {
            "id": "email-finish",
            "type": "email",
            "user": "alex",
            "to": ["adele"],
            "subject": "Fictional wrapup",
            "body": "Fictional wrapup",
            "dependsOn": [previous],
        }
    )
    return Scenario.model_validate(
        {
            "schemaVersion": "1.0",
            "scenarioId": "background-conversation",
            "title": "Fictional conversation",
            "author": "Test",
            "createdAt": "2026-10-01T09:00:00Z",
            "tenantAssumptions": ["Isolated demo tenant"],
            "requiredUsers": users,
            "requiredChannels": ["launch"],
            "dryRun": False,
            "activities": activities,
        }
    )


async def wait_for_state(engine: Engine, run: str, user: str, state: str) -> None:
    async def wait() -> None:
        while engine.report(run)["background"]["teams"][user] != state:  # noqa: ASYNC110
            await asyncio.sleep(0.001)

    await asyncio.wait_for(wait(), 2)


async def test_five_authors_continue_once_authorized_and_email_resumes(
    tmp_path: Path, fake: FakeGateway
) -> None:
    engine = Engine(Journal(tmp_path / "runs.json"), fake)
    scenario = conversation()
    run = engine.create(scenario, "operator")
    engine.start(run, True)
    calls: dict[str, int] = {}

    def provider(user: str):
        async def token() -> str:
            calls[user] = calls.get(user, 0) + 1
            await asyncio.sleep(0)
            return f"{user}-fresh-{calls[user]}"

        return token

    try:
        for user in scenario.requiredUsers:
            engine.kick(run, user, provider(user))
            engine.kick(run, user, provider(user))
        await wait_for_state(engine, run, "alex", "waiting_for_dependencies")
        assert not fake.calls
        engine.kick(run, None, None)
        await asyncio.wait_for(asyncio.gather(*engine.tasks), 3)
        assert [call[0] for call in fake.calls] == [a.id for a in scenario.activities]
        assert calls == dict.fromkeys(scenario.requiredUsers, 2)
        assert all(step["status"] == "success" for step in engine.report(run)["steps"].values())
        assert all(
            state == "completed" for state in engine.report(run)["background"]["teams"].values()
        )
        for index, user in enumerate(scenario.requiredUsers):
            assert fake.calls[index + 1][1] == f"{user}-fresh-1"
            assert fake.calls[index + 6][1] == f"{user}-fresh-2"
    finally:
        await engine.close()


async def test_authorization_failure_preserves_pending_work_and_can_resume(
    tmp_path: Path, fake: FakeGateway
) -> None:
    engine = Engine(Journal(tmp_path / "runs.json"), fake)
    run = engine.create(conversation(), "operator")
    engine.start(run, True)
    engine.update_step(run, "email-start", status="success")

    async def expired() -> str:
        raise TeamsAuthorizationError("secret error content must not be persisted")

    try:
        engine.kick(run, "adele", expired)
        await asyncio.wait_for(asyncio.gather(*engine.tasks), 2)
        await wait_for_state(engine, run, "adele", "reauthentication_required")
        report = engine.report(run)
        assert report["steps"]["teams-0"]["status"] == "pending"
        assert "sign in" in report["steps"]["teams-0"]["error"]
        assert "secret error" not in str(report)
        assert not fake.calls

        async def renewed() -> str:
            return "renewed-token"

        engine.kick(run, "adele", renewed)
        await wait_for_state(engine, run, "adele", "waiting_for_dependencies")
        assert fake.calls == [("teams-0", "renewed-token")]
        assert engine.report(run)["steps"]["teams-0"]["error"] == ""
        assert "renewed-token" not in str(engine.report(run))
    finally:
        await engine.close()


async def test_cancel_wakes_dependency_and_delay_waiters(tmp_path: Path, fake: FakeGateway) -> None:
    engine = Engine(Journal(tmp_path / "runs.json"), fake)
    scenario = conversation()
    scenario.activities[1].delaySeconds = 3600
    run = engine.create(scenario, "operator")
    engine.start(run, True)
    engine.update_step(run, "email-start", status="success")

    async def token() -> str:
        raise AssertionError("Cancelled delayed work must not request a token")

    try:
        engine.kick(run, "adele", token)
        engine.kick(run, "alex", token)
        await wait_for_state(engine, run, "alex", "waiting_for_dependencies")
        engine.cancel(run)
        await asyncio.wait_for(asyncio.gather(*engine.tasks), 1)
        assert not fake.calls
        assert all(
            step["status"] in {"success", "cancelled"}
            for step in engine.report(run)["steps"].values()
        )
    finally:
        await engine.close()


async def test_refresh_happens_after_delay_and_shutdown_requires_new_authorization(
    tmp_path: Path, fake: FakeGateway
) -> None:
    class DelayedTokenEngine(Engine):
        async def _perform(self, run_id, action_id, delay, token, event=None):
            if action_id == "teams-0":
                delay = 0.02
            return await super()._perform(run_id, action_id, delay, token, event)

    engine = DelayedTokenEngine(Journal(tmp_path / "runs.json"), fake)
    run = engine.create(conversation(), "operator")
    engine.start(run, True)
    engine.update_step(run, "email-start", status="success")
    refreshed = False

    async def token() -> str:
        assert refreshed
        return "fresh-after-delay"

    engine.kick(run, "adele", token)
    await asyncio.sleep(0)
    assert not fake.calls
    refreshed = True
    await wait_for_state(engine, run, "adele", "waiting_for_dependencies")
    assert fake.calls == [("teams-0", "fresh-after-delay")]
    await engine.close()
    assert not engine.batches
    restarted = Engine(Journal(tmp_path / "runs.json"), fake)
    assert restarted.report(run)["background"]["teams"]["adele"] == "authorization_required"
    assert restarted.report(run)["steps"]["teams-0"]["status"] == "success"


async def test_token_provider_failure_is_visible_without_sending(
    tmp_path: Path, fake: FakeGateway
) -> None:
    engine = Engine(Journal(tmp_path / "runs.json"), fake)
    run = engine.create(conversation(), "operator")
    engine.start(run, True)
    engine.update_step(run, "email-start", status="success")

    async def unavailable() -> str:
        raise RuntimeError("secret-bearing exception must not appear in reports")

    engine.kick(run, "adele", unavailable)
    await asyncio.gather(*engine.tasks, return_exceptions=True)
    await wait_for_state(engine, run, "adele", "failed")
    assert not fake.calls
    assert engine.report(run)["steps"]["teams-0"]["status"] == "pending"
    assert "secret-bearing" not in str(engine.report(run))
    await engine.close()


async def test_failed_dependency_wakes_and_finishes_all_author_workers(tmp_path: Path) -> None:
    class RejectedGateway(FakeGateway):
        async def execute(self, action, delegated_token, parent_id, correlation_id):
            raise GraphError("Graph rejected the message")

    engine = Engine(Journal(tmp_path / "runs.json"), RejectedGateway())
    scenario = conversation()
    run = engine.create(scenario, "operator")
    engine.start(run, True)
    engine.update_step(run, "email-start", status="success")

    async def token() -> str:
        return "mock-token"

    try:
        for user in reversed(scenario.requiredUsers):
            engine.kick(run, user, token)
        engine.kick(run, None, None)
        await asyncio.wait_for(asyncio.gather(*engine.tasks), 2)
        report = engine.report(run)
        assert report["steps"]["teams-0"]["status"] == "failed"
        assert all(
            report["steps"][action.id]["status"] == "skipped" for action in scenario.activities[2:]
        )
    finally:
        await engine.close()


async def test_background_auth_outlives_cookie_expiry_but_logout_revokes(
    settings: Settings, fake: FakeGateway, monkeypatch: pytest.MonkeyPatch
) -> None:
    auth = Auth(settings, fake.ids)
    key, session = auth.new()
    session.claims = {"oid": str(uuid4())}
    session.created = 0
    acquired = Mock(side_effect=[{"access_token": "first"}, {"access_token": "renewed"}])
    client = SimpleNamespace(
        get_accounts=lambda: [{"local_account_id": session.claims["oid"]}],
        acquire_token_silent=acquired,
    )
    monkeypatch.setattr(auth, "client", lambda value: client)
    assert await auth.token(session) == "first"
    assert await auth.token(session) == "renewed"
    assert acquired.call_count == 2
    auth.revoke(key)
    with pytest.raises(TeamsAuthorizationError, match="revoked"):
        await auth.token(session)
    assert acquired.call_count == 2


@pytest.mark.parametrize(
    ("accounts", "result"),
    [
        ([], {"access_token": "unusable"}),
        ([{"local_account_id": "different-author"}], {"access_token": "wrong-author"}),
        (None, {"error": "interaction_required", "error_description": "secret details"}),
    ],
)
async def test_silent_auth_requires_the_assigned_account_and_reports_safe_errors(
    settings: Settings,
    fake: FakeGateway,
    monkeypatch: pytest.MonkeyPatch,
    accounts,
    result,
) -> None:
    auth = Auth(settings, fake.ids)
    session = Session(claims={"oid": "assigned-author"})
    client = SimpleNamespace(
        get_accounts=lambda: (
            accounts if accounts is not None else [{"local_account_id": "assigned-author"}]
        ),
        acquire_token_silent=lambda *args, **kwargs: result,
    )
    monkeypatch.setattr(auth, "client", lambda value: client)
    with pytest.raises(TeamsAuthorizationError) as failure:
        await auth.token(session)
    assert "secret details" not in str(failure.value)


def test_http_authorizations_continue_without_browser_cookies(
    client: TestClient,
    settings: Settings,
    fake: FakeGateway,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    engine = client.app.state.engine
    scenario = conversation()
    run = engine.create(scenario, str(settings.operator_ids[0]))
    engine.start(run, settings.delivery_enabled)
    delivered = fake.execute
    release = asyncio.Event()

    async def execute(action, delegated_token, parent_id, correlation_id):
        if action.id == "email-start":
            await release.wait()
        return await delivered(action, delegated_token, parent_id, correlation_id)

    async def token(session: Session) -> str:
        assert not session.revoked
        return f"token-for-{session.claims['oid']}"

    monkeypatch.setattr(fake, "execute", execute)
    monkeypatch.setattr(client.app.state.auth, "token", token)
    for user in scenario.requiredUsers:
        csrf = sign_in(client, fake.ids[user], str(settings.tenant_id))
        response = client.post(f"/runs/{run}/teams", data={"csrf": csrf}, follow_redirects=False)
        assert response.status_code == 303
        client.cookies.clear()
    csrf = sign_in(client, str(settings.operator_ids[0]), str(settings.tenant_id))
    response = client.post(
        f"/runs/{run}/execute",
        data={"csrf": csrf, "confirm": "send"},
        follow_redirects=False,
    )
    assert response.status_code == 303
    client.cookies.clear()

    async def finish_without_browser() -> None:
        release.set()
        await asyncio.wait_for(asyncio.gather(*engine.tasks), 3)

    assert client.portal is not None
    client.portal.call(finish_without_browser)
    assert [call[0] for call in fake.calls] == [a.id for a in scenario.activities]
    assert all(step["status"] == "success" for step in engine.report(run)["steps"].values())
    assert "token-for-" not in str(engine.report(run))


def test_msal_requests_refresh_capability(settings: Settings, fake: FakeGateway) -> None:
    auth = Auth(settings, fake.ids, lambda: "client-assertion")
    with pytest.MonkeyPatch.context() as patch:
        constructor = Mock()
        patch.setattr("demo_loader.auth.msal.ConfidentialClientApplication", constructor)
        auth.client(Session())
        assert "offline_access" not in constructor.call_args.kwargs.get("exclude_scopes", [])
