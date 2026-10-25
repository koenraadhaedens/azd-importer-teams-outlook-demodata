from pathlib import Path
from unittest.mock import Mock

import pytest
from azure.core import MatchConditions
from azure.core.exceptions import ResourceModifiedError, ResourceNotFoundError
from azure.storage.blob import BlobClient

from demo_loader.journal import Journal, JournalError


def test_blob_etag_compare_and_swap_and_conflict(tmp_path: Path) -> None:
    blob = Mock(spec=BlobClient)
    blob.download_blob.side_effect = ResourceNotFoundError("No journal yet")
    blob.upload_blob.return_value = {"etag": "version-1"}
    journal = Journal(tmp_path / "unused.json", blob)
    assert blob.upload_blob.call_args_list[0].kwargs["overwrite"] is False
    journal.mutate(lambda data: data.update(test="durable"))
    assert blob.upload_blob.call_args.kwargs["etag"] == "version-1"
    assert blob.upload_blob.call_args.kwargs["match_condition"] == MatchConditions.IfNotModified
    blob.upload_blob.side_effect = ResourceModifiedError("Competing writer")
    with pytest.raises(JournalError):
        journal.mutate(lambda data: data.update(test="conflicting"))
    with pytest.raises(JournalError):
        journal.snapshot()


def test_corrupted_journal_is_not_silently_replaced(tmp_path: Path) -> None:
    path = tmp_path / "journal.json"
    path.write_text("not JSON", encoding="utf-8")
    with pytest.raises(ValueError):
        Journal(path)
    assert path.read_text("utf-8") == "not JSON"
