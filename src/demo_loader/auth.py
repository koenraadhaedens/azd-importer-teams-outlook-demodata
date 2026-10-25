from __future__ import annotations

import asyncio
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

import msal
from fastapi import HTTPException, Request

from demo_loader.config import Settings

SCOPES = ["https://graph.microsoft.com/ChannelMessage.Send"]


@dataclass
class Session:
    created: float = field(default_factory=time.time)
    csrf: str = field(default_factory=lambda: secrets.token_urlsafe(32))
    claims: dict[str, Any] = field(default_factory=dict)
    flow: dict[str, Any] = field(default_factory=dict)
    cache: msal.TokenCache = field(default_factory=msal.TokenCache)


class Auth:
    def __init__(
        self,
        settings: Settings,
        demo_ids: dict[str, str],
        client_assertion: Callable[[], str] | None = None,
    ) -> None:
        self.settings, self.demo_ids = settings, demo_ids
        self.client_assertion = client_assertion
        self.sessions: dict[str, Session] = {}

    def client(self, session: Session) -> msal.ConfidentialClientApplication:
        if self.client_assertion is None:
            raise RuntimeError("Web authentication requires the ACI managed identity")
        return msal.ConfidentialClientApplication(
            str(self.settings.web_client_id),
            authority=f"https://login.microsoftonline.com/{self.settings.tenant_id}",
            client_credential={"client_assertion": self.client_assertion},
            token_cache=session.cache,
            exclude_scopes=["offline_access"],
            enable_pii_log=False,
        )

    def new(self) -> tuple[str, Session]:
        now = time.time()
        self.sessions = {
            key: value
            for key, value in self.sessions.items()
            if now - value.created < self.settings.session_seconds
        }
        if len(self.sessions) >= self.settings.max_sessions:
            raise HTTPException(429, "Session capacity reached; try later")
        key, session = secrets.token_urlsafe(32), Session()
        self.sessions[key] = session
        return key, session

    def session(self, request: Request, authenticated: bool = True) -> Session:
        session = self.sessions.get(request.cookies.get("demo_session", ""))
        if not session or time.time() - session.created >= self.settings.session_seconds:
            raise HTTPException(401, "Sign in required")
        if authenticated and not session.claims:
            raise HTTPException(401, "Sign in required")
        return session

    def authorize(self, claims: dict[str, Any]) -> None:
        if claims.get("tid") != str(self.settings.tenant_id) or not isinstance(
            claims.get("oid"), str
        ):
            raise HTTPException(403, "Wrong tenant or missing object identity")
        if not self.is_operator(claims) and claims["oid"] not in self.demo_ids.values():
            raise HTTPException(403, "User is not explicitly authorized")

    def is_operator(self, claims: dict[str, Any]) -> bool:
        if claims.get("oid") in {str(oid) for oid in self.settings.operator_ids}:
            return True
        group = self.settings.authorized_group_id
        groups = claims.get("groups", [])
        return bool(
            group
            and isinstance(groups, list)
            and str(group) in groups
            and "hasgroups" not in claims
            and "groups" not in claims.get("_claim_names", {})
        )

    def operator(self, request: Request) -> Session:
        session = self.session(request)
        if not self.is_operator(session.claims):
            raise HTTPException(403, "Operator authorization required")
        return session

    def demo_key(self, session: Session) -> str:
        for key, oid in self.demo_ids.items():
            if oid == session.claims["oid"]:
                return key
        raise HTTPException(403, "Sign in as one of the five assigned demo users")

    async def token(self, session: Session) -> str:
        client = self.client(session)
        accounts = client.get_accounts()
        account = next(
            (a for a in accounts if a.get("local_account_id") == session.claims["oid"]), None
        )
        if not account:
            raise HTTPException(401, "Sign in again as the assigned demo user")
        result = await asyncio.to_thread(client.acquire_token_silent, SCOPES, account=account)
        if not result or "access_token" not in result:
            raise HTTPException(401, "Teams authorization expired; sign in again")
        return str(result["access_token"])


async def csrf(request: Request, session: Session) -> None:
    form = await request.form(max_files=1, max_fields=3, max_part_size=1024)
    supplied = form.get("csrf")
    if not isinstance(supplied, str) or not secrets.compare_digest(supplied, session.csrf):
        raise HTTPException(403, "Invalid CSRF token")
    origin = request.headers.get("origin")
    if origin and origin != request.app.state.settings.public_url:
        raise HTTPException(403, "Invalid request origin")
