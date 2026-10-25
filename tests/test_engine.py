import asyncio
from pathlib import Path

import pytest
from conftest import FakeGateway

from demo_loader.engine import Engine, ExecutionError
from demo_loader.graph import GraphError
from demo_loader.journal import Journal, JournalError
from demo_loader.models import Scenario


async def test_dry_run_and_idempotency(
    tmp_path: Path, fake: FakeGateway, raw_scenario: dict
) -> None:
    engine = Engine(Journal(tmp_path / "runs.json"), fake)
    scenario = Scenario.model_validate(raw_scenario)
    run = engine.create(scenario, "operator")
    assert engine.dry_run(run)["graphWrites"] == 0
    assert not fake.calls
    with pytest.raises(ExecutionError):
        engine.start(run, True)
    with pytest.raises(ExecutionError, match="already"):
        engine.create(scenario, "other")
    raw_scenario["dryRun"] = False
    raw_scenario["scenarioId"] = "executable"
    run = engine.create(Scenario.model_validate(raw_scenario), "operator")
    engine.start(run, True)
    await engine.execute_ready(run, None, None)
    await engine.execute_ready(run, None, None)
    assert [a[0] for a in fake.calls] == ["kickoff", "update"]
    assert all(s["status"] == "success" for s in engine.report(run)["steps"].values())
    restarted = Engine(Journal(tmp_path / "runs.json"), fake)
    await restarted.execute_ready(run, None, None)
    assert len(fake.calls) == 2
    restarted.retire(run)
    assert restarted.get(run)["scenario"] is None
    with pytest.raises(ExecutionError):
        restarted.create(Scenario.model_validate(raw_scenario), "operator")


async def test_cancel_and_restart_unknown(
    tmp_path: Path, fake: FakeGateway, raw_scenario: dict
) -> None:
    raw_scenario["dryRun"] = False
    engine = Engine(Journal(tmp_path / "runs.json"), fake)
    run = engine.create(Scenario.model_validate(raw_scenario), "operator")
    engine.start(run, True)
    engine.update_step(run, "kickoff", status="running")
    recovered = Engine(Journal(tmp_path / "runs.json"), fake)
    assert recovered.report(run)["steps"]["kickoff"]["status"] == "unknown"
    await recovered.execute_ready(run, None, None)
    assert recovered.report(run)["steps"]["update"]["status"] == "skipped"
    assert not fake.calls
    recovered.cancel(run)
    assert recovered.get(run)["cancelled"]


async def test_assisted_identity_and_parent(tmp_path: Path, fake: FakeGateway) -> None:
    from demo_loader.validation import load_yaml

    raw = load_yaml(await asyncio.to_thread(Path("examples/teams-assisted.yaml").read_bytes))
    raw["dryRun"] = False
    for activity in raw["activities"]:
        activity["delaySeconds"] = 0
    engine = Engine(Journal(tmp_path / "runs.json"), fake)
    run = engine.create(Scenario.model_validate(raw), "operator")
    engine.start(run, True)
    await engine.execute_ready(run, "diego", "diego-token")
    assert not fake.calls
    await engine.execute_ready(run, None, None)
    await engine.execute_ready(run, "adele", "adele-token")
    assert len(fake.calls) == 1
    await engine.execute_ready(run, "christie", "christie-token")
    await engine.execute_ready(run, "diego", "diego-token")
    await engine.execute_ready(run, "alex", "alex-token")
    await engine.execute_ready(run, None, None)
    assert [call[0] for call in fake.calls] == [
        "kickoff",
        "launch-post",
        "timeline-reply",
        "summary-post",
        "wrapup",
    ]


async def test_ambiguous_failure_no_replay(tmp_path: Path, raw_scenario: dict) -> None:
    class FailingGateway(FakeGateway):
        async def execute(self, action, delegated_token, parent_id, correlation_id):
            raise GraphError("Network uncertain", ambiguous=True)

    raw_scenario["dryRun"] = False
    engine = Engine(Journal(tmp_path / "runs.json"), FailingGateway())
    run = engine.create(Scenario.model_validate(raw_scenario), "operator")
    engine.start(run, True)
    await engine.execute_ready(run, None, None)
    steps = engine.report(run)["steps"]
    assert steps["kickoff"]["status"] == "unknown"
    assert steps["update"]["status"] == "skipped"
    assert "body" not in str(engine.report(run))


def test_storage_failure_poisoning(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    journal = Journal(tmp_path / "runs.json")

    def fail(*args):
        raise OSError("disk unavailable")

    monkeypatch.setattr("os.replace", fail)
    with pytest.raises(JournalError):
        journal.mutate(lambda data: data.update(test=True))
    with pytest.raises(JournalError):
        journal.snapshot()
