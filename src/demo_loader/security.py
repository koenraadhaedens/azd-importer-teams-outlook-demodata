from __future__ import annotations

import logging
import re
import time
from collections import defaultdict, deque

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send


def redact(text: str) -> str:
    text = re.sub(r"(?i)bearer\s+\S+", "Bearer [REDACTED]", text)
    text = re.sub(
        r"(?i)((?:access_token|refresh_token|client_secret|password)[\"']?\s*[:=]\s*)"
        r"(?:\"[^\"]*\"|'[^']*'|[^\s,}&]+)",
        r"\1[REDACTED]",
        text,
    )
    return re.sub(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b", "[JWT]", text)


class RedactionFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.msg = redact(record.getMessage())
        record.args = ()
        return True


class SecurityMiddleware:
    def __init__(self, app: ASGIApp, maximum: int, public_host: str, https: bool) -> None:
        self.app, self.maximum, self.public_host, self.https = app, maximum, public_host, https
        self.hits: dict[str, deque[float]] = defaultdict(deque)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        headers = dict(scope["headers"])
        host = headers.get(b"host", b"").decode().split(":")[0]
        if host != self.public_host:
            await JSONResponse({"detail": "Invalid Host header"}, 400)(scope, receive, send)
            return

        async def secure_send(message: Message) -> None:
            if message["type"] == "http.response.start":
                extra = [
                    (b"x-content-type-options", b"nosniff"),
                    (b"referrer-policy", b"no-referrer"),
                    (b"x-frame-options", b"DENY"),
                    (b"cache-control", b"no-store"),
                    (b"permissions-policy", b"camera=(), microphone=(), geolocation=()"),
                    (
                        b"content-security-policy",
                        b"default-src 'self'; script-src 'self'; style-src 'self'; "
                        b"object-src 'none'; frame-ancestors 'none'; base-uri 'none'; "
                        b"form-action 'self'",
                    ),
                ]
                if self.https:
                    extra.append((b"strict-transport-security", b"max-age=31536000"))
                message["headers"] = list(message.get("headers", [])) + extra
            await send(message)

        if scope["path"] != "/healthz" and not scope["path"].startswith("/static/"):
            now = time.monotonic()
            # The proxy deliberately does not trust browser-supplied forwarded IPs.
            identity = (scope.get("client") or ("unknown",))[0]
            if identity not in self.hits and len(self.hits) >= 1000:
                self.hits = defaultdict(
                    deque, {key: hits for key, hits in self.hits.items() if hits[-1] > now - 60}
                )
                if len(self.hits) >= 1000:
                    await JSONResponse({"detail": "Rate limit capacity"}, 429)(
                        scope, receive, secure_send
                    )
                    return
            bucket = self.hits[identity]
            while bucket and bucket[0] <= now - 60:
                bucket.popleft()
            if len(bucket) >= 120:
                await JSONResponse({"detail": "Rate limited; wait one minute"}, 429)(
                    scope, receive, secure_send
                )
                return
            bucket.append(now)
        if scope["method"] == "POST":
            body = bytearray()
            while True:
                message = await receive()
                if message["type"] == "http.disconnect":
                    return
                body.extend(message.get("body", b""))
                if len(body) > self.maximum + 16384:
                    await JSONResponse({"detail": "Upload too large"}, 413)(
                        scope, receive, secure_send
                    )
                    return
                if not message.get("more_body", False):
                    break
            sent = False

            async def replay() -> Message:
                nonlocal sent
                if sent:
                    return await receive()
                sent = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}

            await self.app(scope, replay, secure_send)
        else:
            await self.app(scope, receive, secure_send)
