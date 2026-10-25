import argparse
import json
from pathlib import Path

from demo_loader.models import Scenario
from demo_loader.validation import load_config, parse_scenario, prepare


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate untrusted demo scenario YAML offline")
    parser.add_argument("scenario", type=Path, nargs="?")
    parser.add_argument("--users", type=Path, default=Path("config/demo-users.json"))
    parser.add_argument("--resources", type=Path, default=Path("config/resources.json"))
    parser.add_argument("--schema", type=Path, default=Path("schemas/demo-scenario.schema.json"))
    parser.add_argument("--write-schema", action="store_true")
    args = parser.parse_args()
    if args.write_schema:
        value = Scenario.model_json_schema()
        value["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        for destination in (
            args.schema,
            Path("skills/demo-scenario-creator/schema/demo-scenario.schema.json"),
        ):
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        return
    if args.scenario is None:
        parser.error("scenario is required unless --write-schema is supplied")
    users, resources = load_config(args.users, args.resources)
    scenario = prepare(parse_scenario(args.scenario.read_bytes(), args.schema), users, resources)
    print(f"Valid: {scenario.scenarioId}; {len(scenario.activities)} activities; no Graph calls")


if __name__ == "__main__":
    main()
