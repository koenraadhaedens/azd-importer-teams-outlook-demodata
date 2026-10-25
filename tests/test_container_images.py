import json
from pathlib import Path

import pytest
import yaml


@pytest.fixture
def image_config() -> dict:
    return json.loads(Path("config/container-images.json").read_text("utf-8"))


def test_requested_image_defaults(image_config: dict) -> None:
    assert image_config == {
        "services": {
            "app": {"image": "acrdefcontainer.azurecr.io/azd-m365-demo-loader"},
            "caddy": {"image": "acrdefcontainer.azurecr.io/caddy:2.11.4-alpine"},
        }
    }


def test_compose_inherits_both_images_without_building(image_config: dict) -> None:
    compose = yaml.safe_load(Path("compose.yaml").read_text("utf-8"))
    for name in image_config["services"]:
        service = compose["services"][name]
        assert service["extends"] == {
            "file": "config/container-images.json",
            "service": name,
        }
        assert "image" not in service
        assert "build" not in service
    assert "ports" not in compose["services"]["app"]
