"""Manage one independent H10 collector process for the research UI."""
import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
from threading import Lock
from uuid import uuid4

from desired_state.platforms.raspberry_pi.collect import discover_h10
from desired_state.api.device_registry import DeviceRegistry

ID_PATTERN = re.compile(r"[A-Za-z0-9_-]{1,80}\Z")


class SessionController:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.registry = DeviceRegistry(self.root / "devices.json")
        self._lock = Lock()
        self._process = None
        self._session_id = None
        self._log = None

    def scan(self):
        with self._lock:
            if self._process is not None and self._process.poll() is None:
                raise RuntimeError("Stop the recording before scanning")
            devices = asyncio.run(discover_h10(8))
        return self.registry.observe([{"polar_id": key, "name": device.name, "address": device.address}
                                      for key, device in sorted(devices.items())])

    def known_devices(self):
        return self.registry.list()

    def assign_device(self, polar_id, participant_id):
        return self.registry.assign(polar_id, participant_id)

    def start(self, assignments: dict[str, str], seconds: int):
        if not assignments or len(assignments) > 32:
            raise ValueError("Assign between 1 and 32 sensors")
        if not isinstance(seconds, int) or not 10 <= seconds <= 86400:
            raise ValueError("Duration must be 10–86400 seconds")
        normalized = {}
        for sensor_id, user_id in assignments.items():
            if not isinstance(sensor_id, str) or not isinstance(user_id, str):
                raise ValueError("Sensor and participant IDs must be text")
            sensor_id = sensor_id.strip().upper()
            if not ID_PATTERN.fullmatch(sensor_id) or not ID_PATTERN.fullmatch(user_id):
                raise ValueError("Sensor and participant IDs must contain only letters, numbers, _ or -")
            if sensor_id in normalized:
                raise ValueError("Duplicate sensor ID")
            normalized[sensor_id] = user_id
        with self._lock:
            if self._process is not None and self._process.poll() is None:
                raise RuntimeError("A session is already recording")
            if self._log is not None:
                self._log.close()
            for sensor_id, user_id in normalized.items():
                self.registry.assign(sensor_id, user_id)
            session_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "_" + uuid4().hex[:8]
            log = (self.root / f"{session_id}.log").open("w")
            command = [sys.executable, "-m", "desired_state.platforms.raspberry_pi.collect",
                       "record", "--output", str(self.root), "--session-id", session_id,
                       "--seconds", str(seconds)]
            for sensor_id, user_id in normalized.items():
                command += ["--assign", f"{sensor_id}={user_id}"]
            try:
                process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            except Exception:
                log.close()
                raise
            self._log = log
            self._process = process
            self._session_id = session_id
            return {"session_id": session_id, "running": True}

    def stop(self):
        with self._lock:
            if self._process is None or self._process.poll() is not None:
                raise RuntimeError("No active session")
            # SIGINT lets asyncio.run cancel tasks and close the session writer.
            import signal
            self._process.send_signal(signal.SIGINT)
            return {"session_id": self._session_id, "stopping": True}

    def status(self):
        with self._lock:
            process = self._process
            session_id = self._session_id
            return_code = process.poll() if process else None
            running = process is not None and return_code is None
        log_path = self.root / f"{session_id}.log" if session_id else None
        output = log_path.read_text(errors="replace")[-1500:] if log_path and log_path.exists() else ""
        return {"session_id": session_id, "running": running, "return_code": return_code,
                "log_tail": output if not running else ""}

    def rows(self, session_id: str, stream: str, limit: int = 100):
        if not ID_PATTERN.fullmatch(session_id) or stream not in {"events", "measurements", "rr"}:
            raise ValueError("Invalid session or stream")
        if not 1 <= limit <= 500:
            raise ValueError("Limit must be 1–500")
        path = self.root / session_id / f"{stream}.jsonl"
        if not path.exists():
            return []
        # Read only the tail so polling stays bounded as sessions grow.
        with path.open("rb") as file:
            file.seek(0, 2)
            offset = file.tell()
            chunks = []
            newlines = 0
            while offset > 0 and newlines <= limit:
                amount = min(8192, offset)
                offset -= amount
                file.seek(offset)
                chunk = file.read(amount)
                chunks.append(chunk)
                newlines += chunk.count(b"\n")
        lines = b"".join(reversed(chunks)).splitlines()[-limit:]
        rows = []
        for line in lines:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass  # A concurrent read may catch an incomplete final line.
        return rows
