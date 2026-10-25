"""Offline repository contract and high-confidence credential-pattern checks."""

import json
import re
import subprocess
from pathlib import Path

import jsonschema
import yaml

from demo_loader.models import Scenario
from demo_loader.validation import load_yaml, parse_scenario


def main() -> None:
    schema_path = Path("schemas/demo-scenario.schema.json")
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    jsonschema.Draft202012Validator.check_schema(schema)
    expected = Scenario.model_json_schema()
    expected["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    assert schema == expected, "Primary schema drift"
    assert (
        json.loads(
            Path("skills/demo-scenario-creator/schema/demo-scenario.schema.json").read_text("utf-8")
        )
        == schema
    ), "Skill schema drift"
    for path in (
        Path("examples/demo-scenario.yaml"),
        Path("examples/teams-assisted.yaml"),
        Path("skills/demo-scenario-creator/examples/scenario.yaml"),
    ):
        parse_scenario(path.read_bytes(), schema_path)
    skill = Path("skills/demo-scenario-creator/SKILL.md").read_text("utf-8")
    frontmatter = yaml.safe_load(skill.split("---", 2)[1])
    assert frontmatter["name"] == "demo-scenario-creator"
    assert frontmatter["description"]
    example = re.search(r"```yaml\n(.*?)```", skill, re.S)
    assert example is not None, "Skill needs a complete YAML example"
    parse_scenario(example[1].encode(), schema_path)
    for path in Path(".github/workflows").glob("*.yml"):
        # GitHub uses YAML 1.2; PyYAML's 1.1 loader interprets the key "on" as bool.
        assert yaml.safe_load(path.read_text("utf-8"))["jobs"], f"Missing workflow jobs: {path}"
    hooks = load_yaml(Path("azure.yaml").read_bytes())["hooks"]
    assert hooks["predeploy"]
    assert hooks["postprovision"]["run"] == "./scripts/register-web-app.ps1"
    assert hooks["postprovision"]["interactive"] is False
    assert load_yaml(Path("compose.yaml").read_bytes())["services"]["app"].get("ports") is None
    images = json.loads(Path("config/container-images.json").read_text("utf-8"))
    assert set(images) == {"services"}
    assert set(images["services"]) == {"app", "caddy"}
    for name, service in images["services"].items():
        assert set(service) == {"image"}, f"Only an image reference is allowed for {name}"
        assert re.fullmatch(
            r"[a-z0-9]+(?:[.-][a-z0-9]+)*(?::[0-9]+)?/"
            r"[a-z0-9]+(?:[._/-][a-z0-9]+)*"
            r"(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-f0-9]{64})?",
            service["image"],
        ), f"Use a fully qualified registry image reference for {name}"

    files = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    patterns = [
        re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
        re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
        re.compile(r"\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\b"),
    ]
    for name in files:
        path = Path(name)
        if not path.is_file():
            continue
        assert path.name != ".env", "Environment secrets must not be tracked"
        assert path.suffix not in {".pfx", ".pem", ".key"}, f"Credential file: {path}"
        text = path.read_text(encoding="utf-8")
        assert not any(pattern.search(text) for pattern in patterns), f"Credential pattern: {path}"
    print("Schemas, samples, skill, workflows, proxy topology and credential patterns: PASS")
    print("Pattern checks are not a guarantee that arbitrary credentials cannot be present.")


if __name__ == "__main__":
    main()
