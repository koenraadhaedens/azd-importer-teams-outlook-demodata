from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import urlencode, urlparse

import httpx
from azure.identity import ManagedIdentityCredential
from azure.storage.blob import BlobClient
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import ValidationError
from starlette.datastructures import UploadFile

from demo_loader.auth import SCOPES, Auth, csrf
from demo_loader.config import Settings
from demo_loader.engine import Engine, ExecutionError
from demo_loader.graph import Gateway, GraphGateway
from demo_loader.journal import Journal, JournalError
from demo_loader.security import RedactionFilter, SecurityMiddleware
from demo_loader.validation import InputError, load_config, parse_scenario, prepare

templates = Jinja2Templates(directory="templates")
logger = logging.getLogger("demo_loader")


def create_app(
    settings: Settings | None = None, gateway: Gateway | None = None, journal: Journal | None = None
) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        cfg = settings or Settings()
        app.state.settings = cfg
        handler = logging.StreamHandler()
        handler.addFilter(RedactionFilter())
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        # HTTP library diagnostics must never print authorization headers or token responses.
        for name in ("httpx", "httpcore", "msal", "azure"):
            logging.getLogger(name).setLevel(logging.WARNING)
        credential: ManagedIdentityCredential | None = None
        if cfg.managed_identity_client_id:
            credential = ManagedIdentityCredential(client_id=str(cfg.managed_identity_client_id))
        elif gateway is None:
            raise RuntimeError("Configure the ACI user-assigned MANAGED_IDENTITY_CLIENT_ID")

        def client_assertion() -> str:
            if credential is None:
                raise RuntimeError("Web authentication requires the ACI managed identity")
            return credential.get_token("api://AzureADTokenExchange/.default").token

        async def app_token() -> str:
            if credential:
                token = await asyncio.to_thread(
                    credential.get_token, "https://graph.microsoft.com/.default"
                )
                return token.token
            raise RuntimeError(
                "Application token acquisition failed; inspect identity configuration"
            )

        users, resources = load_config(cfg.users_file, cfg.resources_file)
        client = httpx.AsyncClient(follow_redirects=False)
        adapter = gateway or GraphGateway(client, app_token, users, resources)
        blob = None
        if cfg.journal_blob_url:
            if credential is None:
                raise RuntimeError("Azure journal requires explicitly configured managed identity")
            blob = BlobClient.from_blob_url(
                cfg.journal_blob_url,
                credential=credential,
                connection_timeout=5,
                read_timeout=15,
            )
        durable = journal or Journal(cfg.data_dir / "journal.json", blob)
        app.state.users, app.state.resources = users, resources
        resolved = await adapter.resolve_users(users)
        configuration_fingerprint = hashlib.sha256(
            json.dumps(
                {
                    "users": users.model_dump(mode="json"),
                    "resources": resources.model_dump(mode="json"),
                    "resolved": resolved,
                    "allowExternal": cfg.allow_external_recipients,
                    "tenant": str(cfg.tenant_id),
                },
                sort_keys=True,
            ).encode()
        ).hexdigest()
        app.state.engine = Engine(
            durable, adapter, cfg.max_concurrency, cfg.max_runs, configuration_fingerprint
        )
        app.state.auth = Auth(cfg, resolved, client_assertion if credential else None)
        logger.info(json.dumps({"event": "startup", "resolvedUserSlots": list(resolved)}))
        try:
            yield
        finally:
            await app.state.engine.close()
            await client.aclose()
            if blob:
                blob.close()
            if credential:
                credential.close()
            logger.removeHandler(handler)

    app = FastAPI(title="azd-m365-demo-loader", lifespan=lifespan, docs_url=None, redoc_url=None)
    # Settings are constructed at process start, before accepting traffic.
    cfg = settings or Settings()
    app.add_middleware(
        SecurityMiddleware,
        maximum=cfg.max_upload_bytes,
        public_host=urlparse(cfg.public_url).hostname or "",
        https=cfg.public_url.startswith("https:"),
    )
    app.mount("/static", StaticFiles(directory="static"), name="static")

    @app.exception_handler(InputError)
    @app.exception_handler(ExecutionError)
    async def input_error(request: Request, exc: ValueError) -> JSONResponse:
        return JSONResponse({"detail": str(exc)}, status_code=400)

    @app.exception_handler(ValidationError)
    async def model_error(request: Request, exc: ValidationError) -> JSONResponse:
        return JSONResponse(
            {
                "detail": "Validation failed",
                "fields": [
                    {"path": list(error["loc"]), "type": error["type"]} for error in exc.errors()
                ],
            },
            status_code=400,
        )

    @app.exception_handler(JournalError)
    async def journal_error(request: Request, exc: JournalError) -> JSONResponse:
        logger.error(json.dumps({"event": "journal_unavailable"}))
        return JSONResponse({"detail": str(exc)}, status_code=503)

    def cookie(response: RedirectResponse, key: str) -> RedirectResponse:
        response.set_cookie(
            "demo_session",
            key,
            httponly=True,
            samesite="lax",
            secure=cfg.public_url.startswith("https:"),
            max_age=cfg.session_seconds,
        )
        return response

    @app.get("/healthz")
    async def health() -> dict[str, str]:
        app.state.engine.journal.check_available()
        return {"status": "ready"}

    @app.get("/login")
    async def login(request: Request) -> RedirectResponse:
        auth: Auth = app.state.auth
        key, session = auth.new()
        session.flow = await asyncio.to_thread(
            auth.client(session).initiate_auth_code_flow,
            SCOPES,
            redirect_uri=cfg.public_url + "/auth/callback",
            prompt="select_account",
        )
        return cookie(RedirectResponse(session.flow["auth_uri"], status_code=303), key)

    @app.get("/auth/callback")
    async def callback(request: Request) -> RedirectResponse:
        auth: Auth = app.state.auth
        session = auth.session(request, authenticated=False)
        if not session.flow:
            raise HTTPException(400, "No pending sign-in flow")
        flow, session.flow = session.flow, {}
        try:
            result = await asyncio.to_thread(
                auth.client(session).acquire_token_by_auth_code_flow,
                flow,
                dict(request.query_params),
            )
        except ValueError as exc:
            raise HTTPException(400, "Sign-in state/nonce validation failed") from exc
        claims = result.get("id_token_claims")
        if "access_token" not in result or not isinstance(claims, dict):
            raise HTTPException(401, "Sign-in failed; check consent and redirect URI")
        auth.authorize(claims)
        session.claims = claims
        old_key = request.cookies.get("demo_session", "")
        new_key, rotated = auth.new()
        rotated.claims, rotated.cache = claims, session.cache
        auth.sessions.pop(old_key, None)
        return cookie(RedirectResponse("/", status_code=303), new_key)

    @app.post("/logout")
    async def logout(request: Request) -> RedirectResponse:
        auth: Auth = app.state.auth
        await csrf(request, auth.session(request))
        auth.sessions.pop(request.cookies.get("demo_session", ""), None)
        response = RedirectResponse(
            f"https://login.microsoftonline.com/{cfg.tenant_id}/oauth2/v2.0/logout?"
            + urlencode({"post_logout_redirect_uri": cfg.public_url + "/"}),
            status_code=303,
        )
        response.delete_cookie("demo_session")
        return response

    @app.get("/auth/signed-out")
    async def signed_out(request: Request) -> RedirectResponse:
        app.state.auth.sessions.pop(request.cookies.get("demo_session", ""), None)
        response = RedirectResponse("/", status_code=303)
        response.delete_cookie("demo_session")
        return response

    @app.get("/", response_class=HTMLResponse)
    async def home(request: Request) -> Any:
        auth: Auth = app.state.auth
        try:
            session = auth.session(request)
        except HTTPException as exc:
            if exc.status_code != 401:
                raise
            return templates.TemplateResponse(request, "welcome.html", {})
        runs = app.state.engine.journal.snapshot()["runs"].values()
        return templates.TemplateResponse(
            request,
            "index.html",
            {
                "session": session,
                "operator": auth.is_operator(session.claims),
                "runs": runs,
                "users": app.state.users.users,
                "resolved": auth.demo_ids,
                "delivery": cfg.delivery_enabled,
                "maximum": cfg.max_upload_bytes,
            },
        )

    @app.post("/upload")
    async def upload(request: Request) -> RedirectResponse:
        auth: Auth = app.state.auth
        session = auth.operator(request)
        await csrf(request, session)
        form = await request.form(max_files=1, max_fields=2)
        uploaded = form.get("scenario")
        if not isinstance(uploaded, UploadFile):
            raise HTTPException(400, "Upload exactly one YAML file")
        if not (uploaded.filename or "").lower().endswith((".yaml", ".yml")):
            raise HTTPException(400, "Only .yaml and .yml files are allowed")
        if uploaded.content_type not in {
            "application/yaml",
            "application/x-yaml",
            "text/yaml",
            "text/x-yaml",
            "text/plain",
        }:
            raise HTTPException(400, "Unsupported MIME type; upload a YAML text document")
        try:
            raw = await uploaded.read(cfg.max_upload_bytes + 1)
        finally:
            await uploaded.close()
        if len(raw) > cfg.max_upload_bytes:
            raise HTTPException(413, "Upload exceeds configured maximum size")
        scenario = prepare(
            parse_scenario(raw, cfg.schema_file, cfg.max_upload_bytes),
            app.state.users,
            app.state.resources,
            cfg.allow_external_recipients,
        )
        run_id = app.state.engine.create(scenario, session.claims["oid"])
        return RedirectResponse(f"/runs/{run_id}", status_code=303)

    @app.get("/runs/{run_id}", response_class=HTMLResponse)
    async def run_page(request: Request, run_id: str) -> Any:
        auth: Auth = app.state.auth
        session = auth.session(request)
        run = app.state.engine.get(run_id)
        app.state.engine.check_configuration(run)
        scenario = run["scenario"]
        operations = []
        per_user: dict[str, dict[str, int]] = {key: {} for key in auth.demo_ids}
        authors: dict[str, str] = {}
        if scenario:
            for action in scenario["activities"]:
                authors[action["id"]] = action["user"]
                status = run["steps"][action["id"]]["status"]
                counts = per_user[action["user"]]
                counts[status] = counts.get(status, 0) + 1
                operations.append(
                    {
                        **action,
                        "method": "POST",
                        "endpoint": (
                            f"/users/{auth.demo_ids[action['user']]}/sendMail"
                            if action["type"] == "email"
                            else f"/teams/{app.state.resources.channels[action['channel']].teamId}"
                            f"/channels/{app.state.resources.channels[action['channel']].channelId}"
                            "/messages"
                            + (
                                f"/<result:{action['parent']}>/replies"
                                if action["type"] == "teamsReply"
                                else ""
                            )
                        ),
                    }
                )
        return templates.TemplateResponse(
            request,
            "run.html",
            {
                "session": session,
                "run": run,
                "operations": operations,
                "operator": auth.is_operator(session.claims),
                "demo_user": session.claims["oid"] in auth.demo_ids.values(),
                "per_user": per_user,
                "authors": authors,
            },
        )

    @app.post("/runs/{run_id}/dry-run")
    async def dry_run(request: Request, run_id: str) -> JSONResponse:
        session = app.state.auth.session(request)
        await csrf(request, session)
        return JSONResponse(app.state.engine.dry_run(run_id))

    @app.post("/runs/{run_id}/execute")
    async def execute(request: Request, run_id: str) -> RedirectResponse:
        auth: Auth = app.state.auth
        session = auth.operator(request)
        await csrf(request, session)
        if (await request.form()).get("confirm") != "send":
            raise HTTPException(400, "Explicit delivery confirmation is required")
        app.state.engine.start(run_id, cfg.delivery_enabled)
        app.state.engine.kick(run_id, None, None)
        return RedirectResponse(f"/runs/{run_id}", status_code=303)

    @app.post("/runs/{run_id}/teams")
    async def teams(request: Request, run_id: str) -> RedirectResponse:
        auth: Auth = app.state.auth
        session = auth.session(request)
        await csrf(request, session)
        key = auth.demo_key(session)
        if not cfg.delivery_enabled:
            raise HTTPException(403, "Delivery is disabled")
        run = app.state.engine.get(run_id)
        if run["started"] is None or run["dryRun"]:
            raise HTTPException(400, "An operator must first start this reviewed scenario")
        app.state.engine.kick(run_id, key, await auth.token(session))
        return RedirectResponse(f"/runs/{run_id}", status_code=303)

    @app.post("/runs/{run_id}/cancel")
    @app.post("/runs/{run_id}/retire")
    async def manage(request: Request, run_id: str) -> RedirectResponse:
        session = app.state.auth.operator(request)
        await csrf(request, session)
        if request.url.path.endswith("/cancel"):
            app.state.engine.cancel(run_id)
        else:
            app.state.engine.retire(run_id)
        return RedirectResponse(f"/runs/{run_id}", status_code=303)

    @app.get("/runs/{run_id}/report")
    async def report(request: Request, run_id: str) -> JSONResponse:
        app.state.auth.session(request)
        return JSONResponse(
            app.state.engine.report(run_id),
            headers={"Content-Disposition": 'attachment; filename="execution-report.json"'},
        )

    return app
