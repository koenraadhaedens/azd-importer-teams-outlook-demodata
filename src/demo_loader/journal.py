from __future__ import annotations

import copy
import json
import os
import threading
from collections.abc import Callable
from pathlib import Path
from typing import Any

from azure.core import MatchConditions
from azure.core.exceptions import AzureError, ResourceNotFoundError
from azure.storage.blob import BlobClient


class JournalError(RuntimeError):
    pass


class Journal:
    """Single-process journal. Every mutation is persisted before returning."""

    def __init__(self, path: Path, blob: BlobClient | None = None) -> None:
        self.path = path
        self.blob = blob
        self.lock = threading.RLock()
        self.poisoned = False
        self.etag: str | None = None
        if blob:
            try:
                download = blob.download_blob()
                self.data = json.loads(download.readall())
                self.etag = download.properties.etag
            except ResourceNotFoundError:
                self.data = {"runs": {}}
                self._save()
        elif path.exists():
            self.data = json.loads(path.read_text(encoding="utf-8"))
        else:
            self.data = {"runs": {}}
        self.mutate(self._recover)

    @staticmethod
    def _recover(data: dict[str, Any]) -> None:
        for run in data["runs"].values():
            for step in run["steps"].values():
                if step["status"] == "running":
                    step.update(status="unknown", error="Process stopped; outcome requires review")

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            if self.poisoned:
                raise JournalError("Journal unavailable; restart and investigate storage")
            return copy.deepcopy(self.data)

    def check_available(self) -> None:
        with self.lock:
            if self.poisoned:
                raise JournalError("Journal unavailable; execution stopped")

    def mutate(self, operation: Callable[[dict[str, Any]], None]) -> None:
        with self.lock:
            if self.poisoned:
                raise JournalError("Journal unavailable; execution stopped")
            proposed = copy.deepcopy(self.data)
            operation(proposed)
            self.data = proposed
            self._save()

    def _save(self) -> None:
        raw = json.dumps(self.data, ensure_ascii=True, allow_nan=False).encode()
        try:
            if self.blob:
                options: dict[str, Any] = (
                    {"etag": self.etag, "match_condition": MatchConditions.IfNotModified}
                    if self.etag
                    else {}
                )
                result = self.blob.upload_blob(raw, overwrite=bool(self.etag), **options)
                self.etag = result["etag"]
            else:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                temporary = self.path.with_suffix(".tmp")
                with temporary.open("wb") as stream:
                    stream.write(raw)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.path)
        except (OSError, AzureError) as exc:
            self.poisoned = True
            raise JournalError(
                "Journal persistence failed; no further execution is allowed"
            ) from exc
