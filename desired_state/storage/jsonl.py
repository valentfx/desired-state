"""Append-only prototype session storage."""
import json
from pathlib import Path


class SessionWriter:
    def __init__(self, root: Path, session_id: str, assignments: dict[str, str]):
        self.path = root / session_id
        self.path.mkdir(parents=True, exist_ok=False)
        (self.path / "manifest.json").write_text(
            json.dumps({"schema_version": 1, "session_id": session_id, "assignments": assignments}, indent=2) + "\n"
        )
        self.files = {name: (self.path / f"{name}.jsonl").open("a", buffering=1)
                      for name in ("events", "measurements", "rr")}
        self.counts = {name: 0 for name in self.files}

    def write(self, stream: str, row: dict):
        self.files[stream].write(json.dumps(row, separators=(",", ":")) + "\n")
        self.counts[stream] += 1

    def close(self):
        for file in self.files.values():
            file.close()
