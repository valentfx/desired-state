"""Read saved session summaries without coupling the UI to BLE acquisition."""
import json
from pathlib import Path
import re
from desired_state.processing.hrv import summarize_rr

SAFE_ID = re.compile(r"[A-Za-z0-9_-]{1,80}\Z")


def _rows(path):
    if path.exists():
        with path.open() as source:
            for line in source:
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue


def sessions(root: Path, polar_id=None, limit=100):
    if polar_id is not None:
        polar_id = polar_id.upper()
        if not SAFE_ID.fullmatch(polar_id):
            raise ValueError("Invalid Polar ID")
    if not 1 <= limit <= 500:
        raise ValueError("Limit must be 1–500")
    result = []
    for directory in sorted(root.iterdir(), reverse=True) if root.exists() else []:
        if not directory.is_dir() or not SAFE_ID.fullmatch(directory.name):
            continue
        manifest = directory / "manifest.json"
        if not manifest.exists():
            continue
        try:
            data = json.loads(manifest.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        assignments = data.get("assignments", {})
        if not isinstance(assignments, dict) or polar_id and polar_id not in assignments:
            continue
        count = 0
        first = last = None
        hr_min = hr_max = None
        for row in _rows(directory / "measurements.jsonl"):
            if polar_id and row.get("polar_id") != polar_id:
                continue
            count += 1
            at = row.get("received_utc")
            if first is None:
                first = at
            last = at
            hr = row.get("heart_rate_bpm")
            if isinstance(hr, (int, float)):
                hr_min = hr if hr_min is None else min(hr_min, hr)
                hr_max = hr if hr_max is None else max(hr_max, hr)
        rr_count = sum(1 for row in _rows(directory / "rr.jsonl")
                       if not polar_id or row.get("polar_id") == polar_id)
        result.append({"session_id": directory.name, "assignments": assignments,
                       "started_utc": first, "last_measurement_utc": last,
                       "measurement_count": count, "rr_count": rr_count,
                       "hr_min": hr_min, "hr_max": hr_max})
        if len(result) >= limit:
            break
    return result


def timeline(root: Path, session_id: str, polar_id: str, max_points=800):
    if not SAFE_ID.fullmatch(session_id) or not SAFE_ID.fullmatch(polar_id):
        raise ValueError("Invalid session or Polar ID")
    directory = root / session_id
    manifest = directory / "manifest.json"
    if not manifest.exists():
        raise ValueError("Session not found")
    try:
        assignments = json.loads(manifest.read_text()).get("assignments", {})
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError("Session manifest unreadable") from exc
    if polar_id not in assignments:
        raise ValueError("Device was not assigned to this session")
    output = {}
    for name, value_key in (("measurements", "heart_rate_bpm"), ("rr", "rr_ms")):
        path = directory / f"{name}.jsonl"
        total = sum(row.get("polar_id") == polar_id for row in _rows(path))
        stride = max(1, (total + max_points - 1) // max_points)
        output[name] = [{"at": row.get("received_utc"), "value": row.get(value_key)}
                        for index, row in enumerate(r for r in _rows(path) if r.get("polar_id") == polar_id)
                        if index % stride == 0 or index == total - 1]
    return {"session_id": session_id, "polar_id": polar_id,
            "participant_id": assignments[polar_id], **output}


def hrv_metrics(root: Path, session_id: str, polar_id: str):
    # Reuse manifest membership and path validation from the timeline reader.
    record = timeline(root, session_id, polar_id, max_points=1)
    rows = (row for row in _rows(root / session_id / "rr.jsonl")
            if row.get("polar_id") == polar_id)
    return {"session_id": session_id, "polar_id": polar_id,
            "participant_id": record["participant_id"], **summarize_rr(rows)}
