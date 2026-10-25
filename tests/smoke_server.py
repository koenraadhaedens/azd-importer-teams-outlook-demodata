"""Image-only startup/proxy check with an injected gateway; never packaged in runtime."""

from uuid import uuid4

import uvicorn

from demo_loader.app import create_app
from demo_loader.config import Settings
from demo_loader.models import Activity, Users


class SmokeGateway:
    async def resolve_users(self, users: Users) -> dict[str, str]:
        return {user.key: str(uuid4()) for user in users.users}

    async def execute(
        self,
        action: Activity,
        delegated_token: str | None,
        parent_id: str | None,
        correlation_id: str,
    ) -> str | None:
        raise AssertionError("Smoke check must never perform Graph writes")


if __name__ == "__main__":
    config = Settings(
        _env_file=None,
        tenant_id=uuid4(),
        web_client_id=uuid4(),
        operator_ids=[uuid4()],
        demo_tenant_confirmed=True,
        public_url="https://localhost:8443",
        data_dir="/tmp/demo-loader-smoke",
    )
    uvicorn.run(
        create_app(config, SmokeGateway()),
        host="0.0.0.0",
        port=8000,
        proxy_headers=False,
        access_log=False,
    )
