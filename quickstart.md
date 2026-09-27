# Pi quick start

From the cloned `desired-state` directory on the Pi:

```bash
clear
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e .
desired-state-h10 scan --seconds 12
```

Wear and moisten the strap. Note its advertised Polar ID from the scan. Assign a participant ID and record a 60-second session:

```bash
clear
source .venv/bin/activate
desired-state-h10 record --assign POLAR_ID=person_1 --seconds 60
```

For two straps, add another `--assign POLAR_ID=person_2`. The first scan establishes an ID; assignment is explicit on every invocation in this prototype. Session files are written under `sessions/<session_id>/`: `events.jsonl`, `measurements.jsonl`, `rr.jsonl`, `manifest.json`. Review the printed counts and inspect the JSONL files. Each row contains session, device, participant, monotonic and UTC receipt timestamps. RR rows preserve individual intervals and their position in the packet; their exact beat timestamps are **not** inferred.

Offline parser checks (no H10 required):

```bash
clear
python -m unittest discover -s tests -v
```

Architecture decisions and test findings belong in [project-log.md](project-log.md). Add a dated entry after each meaningful change or Pi validation run.

## Troubleshooting

- Scan finds nothing: wear the strap, check its battery and Pi Bluetooth service (`bluetoothctl show`), and disconnect other apps if the strap's two BLE receiver slots are occupied.
- Scan works but connection fails: move straps near the Pi; retry one strap first. Connection errors and reconnect attempts appear in `events.jsonl`.
- Browser/SSH cannot reach the Pi: check whether a VPN or tunnel adapter on the Windows PC is intercepting the local network before changing Pi networking.
- If Linux reports missing D-Bus/BlueZ, confirm Bluetooth is enabled and the Pi Bluetooth service is running.

Test sequence: one sensor for 60 seconds; two sensors with disconnect/reconnect; then 4, 6, and 8 with sustained sessions. Review missing data and reconnect behavior before increasing load.
