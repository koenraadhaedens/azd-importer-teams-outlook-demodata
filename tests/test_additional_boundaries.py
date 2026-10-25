import asyncio
from pathlib import Path

import pytest
from conftest import FakeGateway

from demo_loader.engine import Engine, ExecutionError
from demo_loader.journal import Journal
from demo_loader.models import Scenario


async def test_duplicate_concurrent_clicks_send_once(
    tmp_path: Path, fake: FakeGateway, raw_scenario: dict
) -> None:
    raw_scenario["dryRun"] = False
    engine = Engine(Journal(tmp_path / "runs.json"), fake)
    run = engine.create(Scenario.model_validate(raw_scenario), "operator")
    engine.start(run, True)
    await asyncio.gather(
        engine.execute_ready(run, None, None), engine.execute_ready(run, None, None)
    )
    assert len(fake.calls) == 2


async def test_configuration_change_blocks_execution(
    tmp_path: Path, fake: FakeGateway, raw_scenario: dict
) -> None:
    raw_scenario["dryRun"] = False
    journal = Journal(tmp_path / "runs.json")
    engine = Engine(journal, fake, configuration_fingerprint="initial")
    run = engine.create(Scenario.model_validate(raw_scenario), "operator")
    engine.start(run, True)
    changed = Engine(journal, fake, configuration_fingerprint="changed")
    with pytest.raises(ExecutionError, match="configuration changed"):
        changed.start(run, True)
    with pytest.raises(ExecutionError, match="configuration changed"):
        await changed.execute_ready(run, None, None)
    assert not fake.calls


async def test_cancel_future_delayed_actions(
    tmp_path: Path, fake: FakeGateway, raw_scenario: dict, monkeypatch: pytest.MonkeyPatch
) -> None:
    raw_scenario["dryRun"] = False
    raw_scenario["activities"][0]["delaySeconds"] = 120
    engine = Engine(Journal(tmp_path / "runs.json"), fake)
    run = engine.create(Scenario.model_validate(raw_scenario), "operator")
    engine.start(run, True)
    waits = []

    async def cancel_during_wait(delay: float) -> None:
        waits.append(delay)
        engine.cancel(run)

    monkeypatch.setattr("demo_loader.engine.asyncio.sleep", cancel_during_wait)
    await engine.execute_ready(run, None, None)
    assert 119 < waits[0] <= 120
    assert not fake.calls
    assert all(step["status"] == "cancelled" for step in engine.report(run)["steps"].values())
