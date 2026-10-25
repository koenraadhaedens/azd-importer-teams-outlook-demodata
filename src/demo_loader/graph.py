from __future__ import annotations

import asyncio
import random
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from typing import Any, Protocol
from urllib.parse import quote

import httpx

from demo_loader.models import Activity, Email, Resources, TeamsReply, Users

GRAPH = "https://graph.microsoft.com/v1.0"


class GraphError(RuntimeError):
    def __init__(self, message: str, ambiguous: bool = False) -> None:
        super().__init__(message)
        self.ambiguous = ambiguous


class Gateway(Protocol):
    async def resolve_users(self, users: Users) -> dict[str, str]: ...

    async def execute(
        self,
        action: Activity,
        delegated_token: str | None,
        parent_id: str | None,
        correlation_id: str,
    ) -> str | None: ...


def retry_after(value: str | None, attempt: int) -> float:
    if value:
        try:
            seconds = float(value)
        except ValueError:
            try:
                seconds = (parsedate_to_datetime(value) - datetime.now(UTC)).total_seconds()
            except (ValueError, TypeError, OverflowError):
                seconds = 2**attempt
        if seconds > 60:
            raise GraphError("Graph Retry-After exceeds retry budget; try again later")
        return max(0.0, seconds)
    # Jitter is not a security-sensitive random value.
    return min(30.0, 2**attempt + random.random())  # nosec B311


class GraphGateway:
    def __init__(
        self,
        client: httpx.AsyncClient,
        app_token: Callable[[], Awaitable[str]],
        users: Users,
        resources: Resources,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ) -> None:
        self.client, self.app_token = client, app_token
        self.users, self.resources, self.sleep = users, resources, sleep
        self.resolved: dict[str, str] = {}

    async def request(
        self,
        method: str,
        path: str,
        token: str,
        payload: dict[str, Any] | None = None,
        correlation_id: str = "",
        params: dict[str, str] | None = None,
    ) -> httpx.Response:
        for attempt in range(4):
            try:
                response = await self.client.request(
                    method,
                    GRAPH + path,
                    headers={
                        "Authorization": f"Bearer {token}",
                        "client-request-id": correlation_id,
                    },
                    json=payload,
                    params=params,
                    timeout=httpx.Timeout(30, connect=10),
                )
            except httpx.RequestError as exc:
                raise GraphError(
                    "Graph network failure; inspect remote outcome before replay",
                    ambiguous=method != "GET",
                ) from exc
            retryable = response.status_code == 429 or (
                method == "GET" and response.status_code in {502, 503, 504}
            )
            if retryable and attempt < 3:
                await self.sleep(retry_after(response.headers.get("Retry-After"), attempt))
                continue
            if response.is_error:
                raise GraphError(
                    f"Graph returned HTTP {response.status_code}; see tenant audit logs",
                    ambiguous=method != "GET" and response.status_code >= 500,
                )
            return response
        raise GraphError("Graph retry budget exhausted")

    async def resolve_users(self, users: Users) -> dict[str, str]:
        token = await self.app_token()
        resolved: dict[str, str] = {}
        for user in users.users:
            upn = user.userPrincipalName.replace("'", "''")
            response = await self.request(
                "GET",
                "/users",
                token,
                params={
                    "$filter": f"userPrincipalName eq '{upn}'",
                    "$select": "id,userPrincipalName",
                    "$top": "2",
                },
            )
            matches = response.json().get("value", [])
            if len(matches) != 1 or (
                matches[0].get("userPrincipalName", "").lower() != user.userPrincipalName.lower()
            ):
                raise GraphError(f"Configured user slot {user.key} could not be resolved uniquely")
            resolved[user.key] = matches[0]["id"]
        if len(set(resolved.values())) != 5:
            raise GraphError("The five configured users must resolve to distinct object IDs")
        self.resolved = resolved
        return resolved

    async def execute(
        self,
        action: Activity,
        delegated_token: str | None,
        parent_id: str | None,
        correlation_id: str,
    ) -> str | None:
        by_key = {u.key: u for u in self.users.users}
        if isinstance(action, Email):

            def recipients(keys: list[str]) -> list[dict[str, dict[str, str]]]:
                return [
                    {
                        "emailAddress": {
                            "address": str(by_key[k].userPrincipalName) if k in by_key else k
                        }
                    }
                    for k in keys
                ]

            message = {
                "subject": action.subject,
                "body": {"contentType": action.bodyType, "content": action.body},
                "importance": action.importance,
                "toRecipients": recipients(action.to),
                "ccRecipients": recipients(action.cc),
            }
            await self.request(
                "POST",
                f"/users/{quote(self.resolved[action.user], safe='')}/sendMail",
                await self.app_token(),
                {"message": message, "saveToSentItems": True},
                correlation_id,
            )
            return None
        if not delegated_token:
            raise GraphError("Teams requires an interactive token for the assigned demo user")
        channel = self.resources.channels[action.channel]
        path = f"/teams/{channel.teamId}/channels/{quote(channel.channelId, safe='')}/messages"
        if isinstance(action, TeamsReply):
            if not parent_id:
                raise GraphError("Parent Teams message has no confirmed remote ID")
            path += f"/{quote(parent_id, safe='')}/replies"
        response = await self.request(
            "POST",
            path,
            delegated_token,
            {"body": {"contentType": "text", "content": action.body}},
            correlation_id,
        )
        try:
            remote_id = response.json()["id"]
            if not isinstance(remote_id, str) or not remote_id:
                raise ValueError("Invalid message ID")
            return remote_id
        except (ValueError, KeyError) as exc:
            raise GraphError("Graph accepted message but returned no ID", ambiguous=True) from exc
