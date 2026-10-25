from pathlib import Path
from uuid import UUID

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")
    tenant_id: UUID
    web_client_id: UUID
    web_client_secret: SecretStr = SecretStr("")
    public_url: str = "http://localhost:8000"
    operator_ids: list[UUID] = Field(default_factory=list)
    authorized_group_id: UUID | None = None
    demo_tenant_confirmed: bool = False
    delivery_enabled: bool = False
    mailbox_scope_confirmed: bool = False
    allow_external_recipients: bool = False
    users_file: Path = Path("config/demo-users.yaml")
    resources_file: Path = Path("config/resources.yaml")
    schema_file: Path = Path("schemas/demo-scenario.schema.json")
    data_dir: Path = Path("data")
    max_upload_bytes: int = Field(default=65536, ge=1024, le=1048576)
    max_concurrency: int = Field(default=2, ge=1, le=5)
    max_runs: int = Field(default=100, ge=1, le=1000)
    max_sessions: int = Field(default=200, ge=5, le=1000)
    mail_client_id: UUID | None = None
    mail_client_secret: SecretStr = SecretStr("")
    managed_identity_client_id: str = ""
    key_vault_url: str = ""
    web_secret_name: str = "web-client-secret"
    journal_blob_url: str = ""
    session_seconds: int = Field(default=3600, ge=300, le=3600)

    @field_validator("authorized_group_id", "mail_client_id", mode="before")
    @classmethod
    def empty_optional_id(cls, value: object) -> object:
        return None if value == "" else value

    @model_validator(mode="after")
    def safe(self) -> "Settings":
        self.public_url = self.public_url.rstrip("/")
        from urllib.parse import urlparse

        url = urlparse(self.public_url)
        if url.username or url.password or url.query or url.fragment or url.path:
            raise ValueError("PUBLIC_URL must be an origin without path or credentials")
        if url.scheme != "https" and self.public_url != "http://localhost:8000":
            raise ValueError("HTTPS required except http://localhost:8000")
        if not url.hostname:
            raise ValueError("PUBLIC_URL requires a hostname")
        if not self.demo_tenant_confirmed:
            raise ValueError("Confirm isolated CDX tenant with DEMO_TENANT_CONFIRMED=true")
        if not self.operator_ids and not self.authorized_group_id:
            raise ValueError("Configure OPERATOR_IDS or AUTHORIZED_GROUP_ID")
        if self.delivery_enabled and not self.mailbox_scope_confirmed:
            raise ValueError("Verify Exchange mailbox scope before enabling delivery")
        return self
