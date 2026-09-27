"""Persist observed H10 identities and editable participant assignments."""
import json
import os
from pathlib import Path
import re
from threading import Lock

ID = re.compile(r"[A-Za-z0-9_-]{1,80}\Z")


class DeviceRegistry:
    def __init__(self, path: Path):
        self.path = path
        self.lock = Lock()

    def _read(self):
        if not self.path.exists():
            return {}
        return json.loads(self.path.read_text())

    def _write(self, devices):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(json.dumps(devices, indent=2) + "\n")
        os.replace(temporary, self.path)

    def list(self):
        with self.lock:
            return list(self._read().values())

    def observe(self, devices):
        with self.lock:
            known = self._read()
            for device in devices:
                key = device["polar_id"].upper()
                previous = known.get(key, {})
                known[key] = {**previous, **device, "polar_id": key,
                              "participant_id": previous.get("participant_id", "")}
            self._write(known)
            return [known[device["polar_id"].upper()] for device in devices]

    def assign(self, polar_id, participant_id):
        key = polar_id.strip().upper()
        if not ID.fullmatch(key) or not isinstance(participant_id, str) or (participant_id and not ID.fullmatch(participant_id)):
            raise ValueError("Invalid Polar ID or participant ID")
        with self.lock:
            known = self._read()
            if key not in known:
                raise ValueError("Scan the strap before assigning it")
            known[key]["participant_id"] = participant_id
            self._write(known)
            return known[key]
