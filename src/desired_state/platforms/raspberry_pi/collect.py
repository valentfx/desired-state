"""BLE acquisition CLI. No web server is needed to collect a session."""
import argparse
import asyncio
from datetime import datetime, timezone
import time
import re
from pathlib import Path
from uuid import uuid4

from bleak import BleakClient, BleakScanner

from desired_state.devices.polar_h10.parser import parse_heart_rate
from desired_state.storage.jsonl import SessionWriter

HR_CHARACTERISTIC = "00002a37-0000-1000-8000-00805f9b34fb"


def now():
    return {"received_monotonic_ns": time.monotonic_ns(),
            "received_utc": datetime.now(timezone.utc).isoformat()}


def polar_id(device):
    # H10 advertises a stable ID as part of its name, e.g. Polar H10 12345678.
    return (device.name or "").split()[-1].upper()


async def discover_h10(seconds: float):
    results = await BleakScanner.discover(timeout=seconds)
    return {polar_id(d): d for d in results
            if (d.name or "").lower().startswith("polar h10 ")}


async def scan(seconds: float):
    devices = await discover_h10(seconds)
    for sensor_id, device in sorted(devices.items()):
        print(f"{sensor_id:16} {device.address:20} {device.name}")


async def acquire(sensor_id, participant_id, address, session_id, writer, deadline):
    delay = 1.0
    while time.monotonic() < deadline:
        disconnected = asyncio.Event()
        def on_disconnect(_client):
            disconnected.set()
        try:
            async with BleakClient(address, disconnected_callback=on_disconnect, timeout=20) as client:
                writer.write("events", {"event": "connected", "session_id": session_id,
                                        "polar_id": sensor_id, "user_id": participant_id, **now()})
                delay = 1.0
                def on_packet(_characteristic, data):
                    stamp = now()
                    common = {"session_id": session_id, "polar_id": sensor_id,
                              "user_id": participant_id, **stamp}
                    try:
                        packet = parse_heart_rate(bytes(data))
                    except ValueError as exc:
                        writer.write("events", {**common, "event": "invalid_packet", "detail": str(exc)})
                        return
                    writer.write("measurements", {**common, "heart_rate_bpm": packet.bpm,
                                                  "contact_detected": packet.contact_detected,
                                                  "rr_count": len(packet.rr_ticks)})
                    for index, ticks in enumerate(packet.rr_ticks):
                        writer.write("rr", {**common, "rr_index": index, "rr_ticks": ticks,
                                            "rr_ms": ticks * 1000 / 1024})
                await client.start_notify(HR_CHARACTERISTIC, on_packet)
                try:
                    await asyncio.wait_for(disconnected.wait(), timeout=max(0, deadline - time.monotonic()))
                except asyncio.TimeoutError:
                    pass
                writer.write("events", {"event": "disconnected", "session_id": session_id,
                                        "polar_id": sensor_id, "user_id": participant_id, **now()})
        except Exception as exc:
            writer.write("events", {"event": "connection_error", "session_id": session_id,
                                    "polar_id": sensor_id, "user_id": participant_id,
                                    "detail": str(exc), **now()})
        if time.monotonic() < deadline:
            await asyncio.sleep(min(delay, deadline - time.monotonic()))
            delay = min(delay * 2, 30.0)


async def record(assignments, seconds, root, session_id=None):
    devices = await discover_h10(12)
    missing = set(assignments) - set(devices)
    if missing:
        raise SystemExit(f"Assigned H10 IDs not found: {', '.join(sorted(missing))}; run scan first")
    session_id = session_id or (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "_" + uuid4().hex[:8])
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", session_id):
        raise ValueError("invalid session ID")
    writer = SessionWriter(root, session_id, assignments)
    try:
        writer.write("events", {"event": "session_started", "session_id": session_id, **now()})
        deadline = time.monotonic() + seconds
        await asyncio.gather(*(acquire(sensor_id, user_id, devices[sensor_id].address,
                                       session_id, writer, deadline)
                               for sensor_id, user_id in assignments.items()))
    finally:
        writer.write("events", {"event": "session_ended", "session_id": session_id, **now()})
        writer.close()
    print(f"Session: {writer.path}\nRows: {writer.counts}")


def main():
    parser = argparse.ArgumentParser(description="Polar H10 multi-person HR/RR prototype")
    commands = parser.add_subparsers(dest="command", required=True)
    scanner = commands.add_parser("scan", help="list advertising H10 straps")
    scanner.add_argument("--seconds", type=float, default=12)
    recorder = commands.add_parser("record", help="record assigned straps")
    recorder.add_argument("--assign", action="append", required=True, metavar="POLAR_ID=USER_ID")
    recorder.add_argument("--seconds", type=float, default=60)
    recorder.add_argument("--output", type=Path, default=Path("sessions"))
    recorder.add_argument("--session-id", help="safe session ID assigned by session controller")
    args = parser.parse_args()
    if args.command == "scan":
        asyncio.run(scan(args.seconds))
    else:
        assignments = {}
        for entry in args.assign:
            sensor_id, separator, user_id = entry.partition("=")
            if not separator or not sensor_id.strip() or not user_id.strip():
                parser.error("--assign must be POLAR_ID=USER_ID")
            sensor_id = sensor_id.strip().upper()
            if sensor_id in assignments:
                parser.error(f"duplicate sensor: {sensor_id}")
            assignments[sensor_id] = user_id.strip()
        if args.seconds <= 0:
            parser.error("--seconds must be positive")
        try:
            asyncio.run(record(assignments, args.seconds, args.output, args.session_id))
        except KeyboardInterrupt:
            print("Session stopped")


if __name__ == "__main__":
    main()
