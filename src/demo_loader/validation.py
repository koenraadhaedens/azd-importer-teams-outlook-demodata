from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import jsonschema
import nh3
import yaml
from pydantic import EmailStr, TypeAdapter
from yaml.tokens import AliasToken, AnchorToken, TagToken

from demo_loader.models import PLACEHOLDER, Email, Resources, Scenario, Users


class InputError(ValueError):
    pass


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader: UniqueLoader, node: yaml.MappingNode) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if not isinstance(key, str) or key in result:
            raise InputError("YAML requires unique string mapping keys")
        result[key] = loader.construct_object(value_node)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)
# Keep dates as strings so JSON Schema and Pydantic see the same input.
UniqueLoader.yaml_implicit_resolvers = {
    key: [(tag, regex) for tag, regex in values if tag != "tag:yaml.org,2002:timestamp"]
    for key, values in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


def load_yaml(data: bytes, maximum: int = 65536) -> dict[str, Any]:
    if len(data) > maximum:
        raise InputError("File exceeds maximum upload size")
    try:
        text = data.decode("utf-8")
        # Aliases, anchors and explicit tags are not needed by the data contract.
        for token in yaml.scan(text):
            if isinstance(token, AliasToken | AnchorToken | TagToken):
                raise InputError("YAML aliases, anchors and explicit tags are forbidden")
        # UniqueLoader inherits only SafeLoader constructors and rejects duplicate keys.
        value = yaml.load(text, Loader=UniqueLoader)  # nosec B506
    except (UnicodeError, yaml.YAMLError, RecursionError) as exc:
        raise InputError("Invalid or excessively nested YAML") from exc
    if not isinstance(value, dict):
        raise InputError("YAML document must be an object")
    try:
        encoded = json.dumps(value, allow_nan=False)
    except (TypeError, ValueError, RecursionError) as exc:
        raise InputError("YAML must contain JSON-compatible finite values") from exc
    if len(encoded) > maximum * 8:
        raise InputError("Expanded document is too large")
    return value


def unique_json_mapping(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InputError("JSON requires unique mapping keys")
        result[key] = value
    return result


def load_json(data: bytes, maximum: int = 65536) -> dict[str, Any]:
    if len(data) > maximum:
        raise InputError("File exceeds maximum configuration size")
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_json_mapping)
        json.dumps(value, allow_nan=False)
    except (UnicodeError, ValueError, RecursionError) as exc:
        raise InputError("Invalid or non-finite JSON configuration") from exc
    if not isinstance(value, dict):
        raise InputError("JSON configuration must be an object")
    return value


def load_config(users_path: Path, resources_path: Path) -> tuple[Users, Resources]:
    try:
        return (
            Users.model_validate(load_json(users_path.read_bytes())),
            Resources.model_validate(load_json(resources_path.read_bytes())),
        )
    except OSError as exc:
        raise InputError("Required user/resource configuration is missing or unreadable") from exc


def parse_scenario(data: bytes, schema_path: Path, maximum: int = 65536) -> Scenario:
    value = load_yaml(data, maximum)
    try:
        jsonschema.Draft202012Validator(
            json.loads(schema_path.read_text(encoding="utf-8")),
            format_checker=jsonschema.FormatChecker(),
        ).validate(value)
    except jsonschema.ValidationError as exc:
        raise InputError(f"Schema validation failed at {list(exc.absolute_path)}") from exc
    return Scenario.model_validate(value)


def prepare(
    scenario: Scenario, users: Users, resources: Resources, allow_external: bool = False
) -> Scenario:
    by_key = {u.key: u for u in users.users}
    if set(scenario.requiredUsers) - by_key.keys():
        raise InputError("Scenario references an unknown demo user")
    if set(scenario.requiredChannels) - resources.channels.keys():
        raise InputError("Configure all required channel aliases in resources file")
    value = scenario.model_dump(mode="json")

    def replace(text: str) -> str:
        def substitution(match: Any) -> str:
            user = by_key.get(match[1])
            if user is None:
                raise InputError("Placeholder references an unknown demo user")
            return str(getattr(user, match[2]))

        result = PLACEHOLDER.sub(substitution, text)
        if "{{" in result or "}}" in result or "{%" in result:
            raise InputError("Unsupported placeholder/expression")
        return result

    for activity in value["activities"]:
        activity["body"] = replace(activity["body"])
        if activity["type"] == "email":
            activity["subject"] = replace(activity["subject"])
    prepared = Scenario.model_validate(value)
    for action in prepared.activities:
        if isinstance(action, Email):
            for recipients in (action.to, action.cc):
                for index, recipient in enumerate(recipients):
                    if recipient in by_key:
                        continue
                    if not allow_external:
                        raise InputError("Recipients must be configured logical demo-user keys")
                    recipients[index] = str(TypeAdapter(EmailStr).validate_python(recipient))
            if action.bodyType == "html":
                action.body = nh3.clean(
                    action.body,
                    tags={"p", "br", "b", "strong", "i", "em", "ul", "ol", "li"},
                    attributes={},
                    link_rel=None,
                )
    return prepared
