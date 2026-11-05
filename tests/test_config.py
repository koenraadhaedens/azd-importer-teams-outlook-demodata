import json
import sys
from pathlib import Path

import pytest
from conftest import FakeGateway
from fastapi.testclient import TestClient
from pydantic import ValidationError

from demo_loader.app import create_app
from demo_loader.cli import main
from demo_loader.config import Settings
from demo_loader.validation import InputError, load_config, load_json


@pytest.fixture
def configuration_path(tmp_path: Path) -> Path:
    directory = tmp_path / "config"
    directory.mkdir()
    config_path = directory / "config.json"
    config_path.write_text(
        json.dumps(
            {
                "services": {
                    "app": {"image": "example.azurecr.io/app:latest"},
                    "caddy": {"image": "example.azurecr.io/caddy:latest"},
                },
                "x-demo": {
                    "channels": {},
                    "users": [
                        {
                            "key": key,
                            "displayName": key.title(),
                            "userPrincipalName": f"{key}@example.org",
                        }
                        for key in ("adele", "alex", "christie", "diego", "megan")
                    ],
                },
            }
        ),
        encoding="utf-8",
    )
    return config_path


def test_default_configuration_is_json(settings: Settings) -> None:
    assert settings.config_file == Path("config/config.json")
    users, resources = load_config(settings.config_file)
    assert len(users.users) == 5
    assert "project-harvest" in resources.channels


@pytest.mark.parametrize(
    "content",
    [
        b"users: []",
        b'{"users": [],}',
        b'{"users": [], "users": []}',
        b'{"channels": {"launch": {}, "launch": {}}}',
        b'{"value": NaN}',
        b'{"value": Infinity}',
        b'{"value": -Infinity}',
        b'{"value": 1e400}',
        b'{"value": "\xff"}',
        b"[]",
        b"null",
        b'{"value": ' + b"9" * 5000 + b"}",
    ],
)
def test_invalid_json_configuration(content: bytes) -> None:
    with pytest.raises(InputError):
        load_json(content)


def test_json_configuration_size_limit() -> None:
    with pytest.raises(InputError, match="maximum"):
        load_json(b'{"value": "' + b"x" * 65536 + b'"}')
    document = b'{"channels": {}}'
    assert load_json(document, maximum=len(document)) == {"channels": {}}
    with pytest.raises(InputError, match="maximum"):
        load_json(document, maximum=len(document) - 1)


def test_nested_arrays_are_not_user_configuration(
    configuration_path: Path,
) -> None:
    configuration_path.write_bytes(b'{"users": ' + b"[" * 2000 + b"]" * 2000 + b"}")
    with pytest.raises((InputError, ValidationError)):
        load_config(configuration_path)


@pytest.mark.parametrize("mutation", ["missing", "extra", "duplicate-key", "duplicate-upn"])
def test_json_user_constraints(configuration_path: Path, mutation: str) -> None:
    configuration = load_json(configuration_path.read_bytes())
    data = configuration["x-demo"]
    if mutation == "missing":
        data["users"].pop()
    elif mutation == "extra":
        data["users"].append(data["users"][0])
    elif mutation == "duplicate-key":
        data["users"][1]["key"] = data["users"][0]["key"]
    else:
        data["users"][1]["userPrincipalName"] = data["users"][0]["userPrincipalName"].upper()
    configuration_path.write_text(json.dumps(configuration), encoding="utf-8")
    with pytest.raises(ValidationError):
        load_config(configuration_path)


def test_json_channel_mapping(configuration_path: Path) -> None:
    channel = {
        "teamId": "00000000-0000-0000-0000-000000000001",
        "channelId": "19:demo@thread.tacv2",
    }
    data = load_json(configuration_path.read_bytes())
    data["x-demo"]["channels"] = {"launch": channel}
    configuration_path.write_text(json.dumps(data), encoding="utf-8")
    _, resources = load_config(configuration_path)
    assert resources.channels["launch"].model_dump(mode="json") == channel


def test_yaml_configuration_is_not_silently_accepted(
    configuration_path: Path,
) -> None:
    configuration_path.write_text("users: []\nchannels: {}", encoding="utf-8")
    with pytest.raises(InputError, match="JSON"):
        load_config(configuration_path)


@pytest.mark.parametrize(
    "mutation", ["unknown", "invalid-channel", "invalid-service", "missing-service"]
)
def test_combined_configuration_remains_strict(configuration_path: Path, mutation: str) -> None:
    data = load_json(configuration_path.read_bytes())
    if mutation == "unknown":
        data["unexpected"] = True
    elif mutation == "invalid-channel":
        data["x-demo"]["channels"] = {"launch": {"teamId": "invalid", "channelId": "invalid"}}
    elif mutation == "invalid-service":
        data["services"]["app"]["build"] = "."
    else:
        del data["services"]["app"]
    configuration_path.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(ValidationError):
        load_config(configuration_path)


def test_app_loads_json_configuration(
    settings: Settings, fake: FakeGateway, configuration_path: Path
) -> None:
    settings.config_file = configuration_path
    with TestClient(create_app(settings, fake), base_url="http://localhost:8000") as client:
        assert client.get("/healthz").json() == {"status": "ready"}
        assert client.app.state.users.users[0].userPrincipalName == "adele@example.org"


@pytest.mark.parametrize("custom_paths", [False, True])
def test_cli_uses_json_configuration_and_yaml_scenarios(
    configuration_path: Path,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    custom_paths: bool,
) -> None:
    scenario = Path("examples/demo-scenario.yaml").resolve()
    schema = Path("schemas/demo-scenario.schema.json").resolve()
    arguments = ["validate-scenario", str(scenario), "--schema", str(schema)]
    if custom_paths:
        config_path = configuration_path.rename(tmp_path / "custom-config.json")
        arguments += ["--config", str(config_path)]
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", arguments)
    main()
    assert "Valid: launch-email-preview; 2 activities; no Graph calls" in capsys.readouterr().out
