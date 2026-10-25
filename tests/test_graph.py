from pathlib import Path
from uuid import uuid4

import httpx
import pytest

from demo_loader.graph import GraphError, GraphGateway, retry_after
from demo_loader.models import Email, Resources, TeamsMessage, TeamsReply
from demo_loader.validation import load_config


async def test_throttling_and_mail_payload() -> None:
    requests = []
    waits = []

    async def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return (
            httpx.Response(429, headers={"Retry-After": "0"})
            if len(requests) == 1
            else httpx.Response(202)
        )

    async def token() -> str:
        return "test-app-token"

    async def sleep(value: float) -> None:
        waits.append(value)

    users, resources = load_config(Path("config/demo-users.yaml"), Path("config/resources.yaml"))
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        graph = GraphGateway(client, token, users, resources, sleep)
        graph.resolved = {"adele": str(uuid4())}
        action = Email(
            id="mail", type="email", user="adele", to=["alex"], subject="Demo", body="Hi"
        )
        assert await graph.execute(action, None, None, str(uuid4())) is None
        assert len(requests) == 2 and waits == [0]
        assert b"alexw@contoso.onmicrosoft.com" in requests[-1].content
        assert requests[-1].headers["authorization"] == "Bearer test-app-token"


@pytest.mark.parametrize("status", [500, 503])
async def test_no_retry_ambiguous_posts(status: int) -> None:
    count = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal count
        count += 1
        return httpx.Response(status)

    async def token() -> str:
        return "test"

    users, resources = load_config(Path("config/demo-users.yaml"), Path("config/resources.yaml"))
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        graph = GraphGateway(client, token, users, resources)
        with pytest.raises(GraphError) as caught:
            await graph.request("POST", "/test", "test")
        assert caught.value.ambiguous
        assert count == 1


async def test_teams_delegated_messages_and_replies() -> None:
    requests = []

    async def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(201, json={"id": "message-result"})

    async def token() -> str:
        raise AssertionError("Teams must never use app-only tokens")

    users, _ = load_config(Path("config/demo-users.yaml"), Path("config/resources.yaml"))
    resources = Resources.model_validate(
        {"channels": {"launch": {"teamId": str(uuid4()), "channelId": "19:demo@thread.tacv2"}}}
    )
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        graph = GraphGateway(client, token, users, resources)
        root = TeamsMessage(
            id="post", type="teamsMessage", user="adele", channel="launch", body="Hi"
        )
        with pytest.raises(GraphError, match="interactive"):
            await graph.execute(root, None, None, "")
        assert await graph.execute(root, "delegated", None, "") == "message-result"
        reply = TeamsReply(
            id="reply",
            type="teamsReply",
            user="alex",
            channel="launch",
            body="Thanks",
            parent="post",
            dependsOn=["post"],
        )
        await graph.execute(reply, "delegated-alex", "message-result", "")
        assert str(requests[-1].url).endswith("/messages/message-result/replies")
        assert requests[-1].headers["authorization"] == "Bearer delegated-alex"
        assert b'"contentType":"text"' in requests[-1].content


def test_retry_budget() -> None:
    assert retry_after("0", 1) == 0
    assert 0 <= retry_after(None, 3) <= 30
    with pytest.raises(GraphError, match="budget"):
        retry_after("3600", 0)
