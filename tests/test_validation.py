import copy
from pathlib import Path

import pytest
from pydantic import ValidationError

from demo_loader.models import Resources, Scenario, Users
from demo_loader.validation import (
    InputError,
    load_config,
    load_json,
    load_yaml,
    parse_scenario,
    prepare,
)

SCHEMA = Path("schemas/demo-scenario.schema.json")


def test_valid_sample() -> None:
    scenario = parse_scenario(Path("examples/demo-scenario.yaml").read_bytes(), SCHEMA)
    users, resources = load_config(Path("config/demo-users.json"), Path("config/resources.json"))
    result = prepare(scenario, users, resources)
    assert "Alex Wilber" in result.activities[0].body


@pytest.mark.parametrize(
    "content",
    [
        b"foo: !!python/object/apply:os.system [not-a-command]",
        b"a: &x [1]\nb: *x",
        b"a: 1\na: 2",
        b"1: invalid",
        b"a: .nan",
        b"- not-an-object",
        b"a: " + b"[" * 1000 + b"]" * 1000,
    ],
)
def test_unsafe_yaml(content: bytes) -> None:
    with pytest.raises(InputError):
        load_yaml(content)


def test_oversized() -> None:
    with pytest.raises(InputError, match="maximum"):
        load_yaml(b"a: " + b"x" * 65536)


def test_invalid_schema() -> None:
    with pytest.raises(InputError):
        parse_scenario(Path("examples/demo-scenario-invalid.yaml").read_bytes(), SCHEMA)


def test_five_users_and_missing_configuration(tmp_path: Path) -> None:
    users = load_json(Path("config/demo-users.json").read_bytes())
    users["users"].pop()
    with pytest.raises(ValidationError):
        Users.model_validate(users)
    with pytest.raises(InputError, match="missing"):
        load_config(tmp_path / "missing.json", Path("config/resources.json"))


@pytest.mark.parametrize("mutation", ["duplicate", "cycle", "unknown", "type", "reply"])
def test_structural_rejections(raw_scenario: dict, mutation: str) -> None:
    raw = copy.deepcopy(raw_scenario)
    if mutation == "duplicate":
        raw["activities"][1]["id"] = raw["activities"][0]["id"]
    elif mutation == "cycle":
        raw["activities"][0]["dependsOn"] = [raw["activities"][1]["id"]]
    elif mutation == "unknown":
        raw["activities"][0]["user"] = "intruder"
    elif mutation == "type":
        raw["activities"][0]["type"] = "chat"
    else:
        raw["activities"][0].update(type="teamsReply", parent="future", channel="launch")
    with pytest.raises(ValidationError):
        Scenario.model_validate(raw)


def test_recipient_placeholder_and_html_boundaries(raw_scenario: dict) -> None:
    users, resources = load_config(Path("config/demo-users.json"), Path("config/resources.json"))
    raw_scenario["activities"][0]["to"] = ["outside@example.org"]
    with pytest.raises(InputError, match="Recipients"):
        prepare(Scenario.model_validate(raw_scenario), users, resources)
    assert prepare(Scenario.model_validate(raw_scenario), users, resources, True)
    raw_scenario["activities"][0]["to"] = ["alex"]
    raw_scenario["activities"][0]["body"] = "{{user.intruder.displayName}}"
    with pytest.raises(InputError, match="unknown"):
        prepare(Scenario.model_validate(raw_scenario), users, resources)
    raw_scenario["activities"][0]["body"] = "{{ 7 * 7 }}"
    with pytest.raises(InputError, match="expression"):
        prepare(Scenario.model_validate(raw_scenario), users, resources)
    raw_scenario["activities"][0].update(
        bodyType="html", body="<script>alert(1)</script><b>Demo</b><img src=x onerror=x>"
    )
    action = prepare(Scenario.model_validate(raw_scenario), users, resources).activities[0]
    assert action.body == "<b>Demo</b>"


def test_unknown_configured_user(raw_scenario: dict) -> None:
    users, _ = load_config(Path("config/demo-users.json"), Path("config/resources.json"))
    raw_scenario["requiredUsers"][-1] = "nobody"
    raw_scenario["activities"][1]["user"] = "nobody"
    with pytest.raises(InputError, match="unknown"):
        prepare(Scenario.model_validate(raw_scenario), users, Resources())
