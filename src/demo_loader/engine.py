from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import time
from typing import Any
from uuid import uuid4

from demo_loader.graph import Gateway, GraphError
from demo_loader.journal import Journal
from demo_loader.models import Email, Scenario, TeamsReply

logger = logging.getLogger("demo_loader.audit")
TERMINAL = {"success", "failed", "unknown", "cancelled", "skipped"}


class ExecutionError(ValueError):
    pass


class Engine:
    def __init__(
        self,
        journal: Journal,
        gateway: Gateway,
        concurrency: int = 2,
        max_runs: int = 100,
        configuration_fingerprint: str = "",
    ) -> None:
        self.journal, self.gateway, self.max_runs = journal, gateway, max_runs
        self.configuration_fingerprint = configuration_fingerprint
        self.semaphore = asyncio.Semaphore(concurrency)
        self.tasks: set[asyncio.Task[None]] = set()
        self.batches: dict[tuple[str, str | None], asyncio.Task[None]] = {}

    def create(self, scenario: Scenario, owner: str) -> str:
        serialized = scenario.model_dump(mode="json")
        fingerprint = hashlib.sha256(json.dumps(serialized, sort_keys=True).encode()).hexdigest()
        run_id = str(uuid4())

        def operation(data: dict[str, Any]) -> None:
            runs = data["runs"]
            if any(
                r["fingerprint"] == fingerprint or r["scenarioId"] == scenario.scenarioId
                for r in runs.values()
            ):
                raise ExecutionError("Scenario already uploaded; open its existing run")
            if len(runs) >= self.max_runs:
                raise ExecutionError("Run limit reached; archive journal under operator control")
            runs[run_id] = {
                "id": run_id,
                "scenarioId": scenario.scenarioId,
                "fingerprint": fingerprint,
                "configurationFingerprint": self.configuration_fingerprint,
                "owner": owner,
                "created": time.time(),
                "started": None,
                "dryRun": scenario.dryRun,
                "cancelled": False,
                "retired": False,
                "scenario": serialized,
                "steps": {
                    a.id: {"status": "pending", "idempotencyKey": f"{fingerprint}:{a.id}"}
                    for a in scenario.activities
                },
            }

        self.journal.mutate(operation)
        return run_id

    def get(self, run_id: str) -> dict[str, Any]:
        try:
            return self.journal.snapshot()["runs"][run_id]
        except KeyError as exc:
            raise ExecutionError("Run not found") from exc

    def start(self, run_id: str, delivery_enabled: bool) -> None:
        if not delivery_enabled:
            raise ExecutionError("Delivery is disabled by administrator configuration")

        def operation(data: dict[str, Any]) -> None:
            run = data["runs"][run_id]
            self.check_configuration(run)
            if run["dryRun"]:
                raise ExecutionError(
                    "Scenario is dry-run-only; upload a reviewed executable scenario"
                )
            if run["cancelled"] or run["retired"]:
                raise ExecutionError("Run is cancelled or retired")
            if run["started"] is None:
                run["started"] = time.time()

        self.journal.mutate(operation)

    def dry_run(self, run_id: str) -> dict[str, Any]:
        self.check_configuration(self.get(run_id))
        report = self.report(run_id)
        report["mode"] = "dry-run"
        report["graphWrites"] = 0
        return report

    def check_configuration(self, run: dict[str, Any]) -> None:
        if run.get("configurationFingerprint", "") != self.configuration_fingerprint:
            raise ExecutionError(
                "User/resource configuration changed; this run cannot execute under new mappings"
            )

    def update_step(self, run_id: str, action_id: str, **changes: Any) -> None:
        self.journal.mutate(lambda data: data["runs"][run_id]["steps"][action_id].update(changes))

    def cancel(self, run_id: str) -> None:
        def operation(data: dict[str, Any]) -> None:
            run = data["runs"][run_id]
            run["cancelled"] = True
            for step in run["steps"].values():
                if step["status"] == "pending":
                    step["status"] = "cancelled"

        self.journal.mutate(operation)

    def retire(self, run_id: str) -> None:
        run = self.get(run_id)
        self.check_configuration(run)
        if any(s["status"] not in TERMINAL for s in run["steps"].values()):
            raise ExecutionError(
                "Cancel pending work and wait for running actions before retirement"
            )
        self.journal.mutate(lambda data: data["runs"][run_id].update(scenario=None, retired=True))

    def kick(self, run_id: str, actor_key: str | None, delegated_token: str | None) -> None:
        batch = (run_id, actor_key)
        if batch in self.batches:
            return
        if len(self.batches) >= 30:
            raise ExecutionError("Active execution batch limit reached; wait for current work")
        task = asyncio.create_task(self.execute_ready(run_id, actor_key, delegated_token))
        self.batches[batch] = task
        self.tasks.add(task)
        task.add_done_callback(self._completed)

    def _completed(self, task: asyncio.Task[None]) -> None:
        self.tasks.discard(task)
        self.batches = {key: value for key, value in self.batches.items() if value is not task}
        if not task.cancelled() and task.exception():
            # No exception text: external libraries can embed sensitive request details.
            logger.error(json.dumps({"event": "execution_worker_failed", "requiresReview": True}))

    async def execute_ready(
        self, run_id: str, actor_key: str | None, delegated_token: str | None
    ) -> None:
        # A click executes a ready batch, not a persistent delegated impersonation scheduler.
        while True:
            run = self.get(run_id)
            self.check_configuration(run)
            if run["cancelled"] or run["retired"] or run["started"] is None:
                return
            scenario = Scenario.model_validate(run["scenario"])
            candidates = []
            for action in scenario.activities:
                step = run["steps"][action.id]
                if step["status"] != "pending":
                    continue
                deps = [run["steps"][key]["status"] for key in action.dependsOn]
                if any(state in TERMINAL - {"success"} for state in deps):
                    self.update_step(run_id, action.id, status="skipped", error="Dependency failed")
                    continue
                if any(state != "success" for state in deps):
                    continue
                if isinstance(action, Email):
                    if actor_key is not None:
                        continue
                elif action.user != actor_key or not delegated_token:
                    continue
                base = max(
                    [run["started"]]
                    + [
                        run["steps"][key].get("finished", run["started"])
                        for key in action.dependsOn
                    ]
                )
                candidates.append((action, max(0, base + action.delaySeconds - time.time())))
            if not candidates:
                return
            await asyncio.gather(
                *(
                    self._perform(run_id, action.id, delay, delegated_token)
                    for action, delay in candidates
                )
            )

    async def _perform(self, run_id: str, action_id: str, delay: float, token: str | None) -> None:
        # Wait outside the concurrency semaphore; cancellation is checked before claiming.
        await asyncio.sleep(delay)
        async with self.semaphore:
            run = self.get(run_id)
            if run["cancelled"] or run["steps"][action_id]["status"] != "pending":
                return
            scenario = Scenario.model_validate(run["scenario"])
            action = next(a for a in scenario.activities if a.id == action_id)
            parent = (
                run["steps"][action.parent].get("remoteId")
                if isinstance(action, TeamsReply)
                else None
            )
            self.update_step(run_id, action_id, status="running")
            logger.info(json.dumps({"event": "action_started", "run": run_id, "step": action_id}))
            try:
                remote = await self.gateway.execute(action, token, parent, run_id)
            except GraphError as exc:
                self.update_step(
                    run_id,
                    action_id,
                    status="unknown" if exc.ambiguous else "failed",
                    error=str(exc),
                    finished=time.time(),
                )
            except Exception:
                self.update_step(
                    run_id,
                    action_id,
                    status="unknown",
                    error="Unexpected adapter failure; inspect outcome before replay",
                    finished=time.time(),
                )
                logger.exception("Unexpected adapter failure", exc_info=False)
                raise
            else:
                self.update_step(
                    run_id, action_id, status="success", remoteId=remote, finished=time.time()
                )
            logger.info(
                json.dumps(
                    {
                        "event": "action_finished",
                        "run": run_id,
                        "step": action_id,
                        "status": self.get(run_id)["steps"][action_id]["status"],
                    }
                )
            )

    def report(self, run_id: str) -> dict[str, Any]:
        run = self.get(run_id)
        return {
            key: run[key]
            for key in (
                "id",
                "configurationFingerprint",
                "scenarioId",
                "fingerprint",
                "created",
                "started",
                "dryRun",
                "cancelled",
                "retired",
                "steps",
            )
        }

    async def close(self) -> None:
        for task in list(self.tasks):
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
