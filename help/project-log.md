# Desired State project log

Keep this file updated with each meaningful change. Record what changed, why, verification, and remaining risks. This is the project's working technical context; the short commands stay in [quickstart.md](quickstart.md).

## Product and architecture

- Goal: Desired State → Current State → Physiological Baseline → Personalized Session → Outcome. The system records interventions and responses so later sessions can learn from measured results and explicit user feedback.
- Reusable headless Python core. Raspberry Pi and Polar H10 are initial implementations; web UI, Windows, other sensors, stimulus devices, and eventual consumer clients connect through separate adapters.
- Preserve raw, derived, inferred, and decision data as distinct concepts. Avoid claiming HRV alone measures a complete physiological or psychological state.
- Session timeline, participant identity, device identity, and clock provenance must be explicit. A BLE packet can contain multiple RR intervals; its receipt time is not an exact timestamp for every beat.
- Prototype data is local-first. JSONL files make the first acquisition inspectable and replayable. Consider SQLite metadata and a raw-stream format after the acquisition schema and workload are measured.

## 2026-09-26 — initial acquisition prototype v0.1

- Added an installable `src/desired_state/` package and Pi CLI. Scan H10 advertisements, assign Polar IDs to participant IDs for a run, subscribe to standard Heart Rate Measurement notifications, parse HR and all RR intervals, save session manifest and JSONL streams, and retry connections after errors or drops.
- Kept the collector independent of Flask. Acquisition needs to work and be measured before adding a UI or adaptive logic.
- Added parser checks for multi-RR packets, 16-bit heart rate, energy field, and malformed RR data. Offline tests passed.

## 2026-09-26 — layout review v0.2

- Removed empty root-level placeholders for future modules. All Python feature modules belong under `src/desired_state/`; this avoids parallel `devices/` and `src/desired_state/devices/` trees and keeps imports and packaging predictable.
- Added this log so architecture decisions and verification remain reviewable across PC → Git → Pi handoffs.
- Kept the first milestone narrow: one strap, participant assignment, recorded session; then two straps and disconnect/reconnect; then sustained 4, 6, and 8 strap trials. The 4–8 target is experimental, not a proven adapter limit.

## 2026-09-26 — first Pi acquisition result

- On the Raspberry Pi, BlueZ initially reported Bluetooth `off-blocked`. After enabling the adapter, the scanner found Polar H10 `E9E53B2C`.
- The first 60-second recording produced 58 heart-rate measurement rows and 76 RR rows; the packet format can contain multiple RR intervals. Four event rows were reported but have not yet been inspected. This validates one live acquisition path, not multi-strap reliability.

## 2026-09-26 — Flask research interface v0.3

- Added `api/` as a transport adapter and `desired-state-web` as a separate executable. The Flask server starts a separate collector process and reads its existing JSONL streams; the BLE implementation stays independent of Flask.
- Added versioned REST endpoints for scan, start/stop, status, and recent session rows, plus a simple local research page for participant assignment and live values. One active session per web process avoids competing BLE scans.
- Session ID is supplied to the collector so API routes can identify the session before BLE discovery completes. A stop signal triggers the collector's `finally` block to append `session_ended` and close files.
- API state is process-local and deliberately single-worker. No persistent assignment registry, user login, WebSocket, or HRV derivation yet. The browser polls every second. Use the development server only on a trusted LAN.
- Added API route checks with a fake controller and bounded tail reads for efficient live polling as session files grow. Parser checks and Python compilation passed in the build workspace. Flask dependencies were unavailable in that workspace, so API checks and live Flask/BLE behavior still need Pi validation.

## Next work

1. Inspect the first session's four event rows; run the Flask UI with one H10 and verify start, live display, natural completion, and manual stop.
2. Test two simultaneous straps and observe discovery/connect behavior, packet gaps, reconnect times, and participant identity.
3. Define stable `core/` session and signal types and a persistent sensor-to-participant registry after real advertisements establish the best stable Polar identifier.
4. Add HRV processing with transparent window/quality rules, then event marking, baseline, audio stimulus, replay, and research UI improvements.

## Known limits

- Assignments are supplied for each session through CLI or web form; no persistent assignment registry yet.
- Current JSONL append calls are synchronous and intended for low-rate HR/RR data; measure sustained multi-sensor runs before choosing a storage queue or database.
- BLE reconnect currently retries the initially discovered address. Validate address stability and rediscovery on the Pi; BLE adapters, RF conditions, and H10 receiver slots may constrain concurrent sessions.
- One live acquisition on the Pi succeeded. Multi-strap collection, Flask control, interruption cleanup, and sustained operation have not yet been validated on hardware. No physiological interpretation or adaptive session logic is implemented.
# Session history update (Sep 26, 2026)

Added device-filtered recorded session history over existing JSONL sessions. A manifest identifies which Polar IDs participated and preserves the assignment at recording time. The reader counts and summarizes the complete HR and RR streams, while the detail API reduces plot points for browser display without changing raw files. The UI lists sessions for a saved H10 and plots HR and RR after selection. Next validation: run all tests and view an existing 60-second Pi recording; then compare the exact Battery Analyzer workflow if its project files become available.

# Provisional HRV update (Sep 26, 2026)

Added versioned offline RR metrics (`rr-time-domain-v1`) behind a session/device API and history detail view. It computes RMSSD on accepted contiguous pairs, sample SDNN, pNN50, and mean HR derived from RR. It exposes acceptance and gap counts, preserves raw intervals, and labels the output provisional because normal-to-normal beats are not ECG verified. Longer resting baselines, artifact review, and a validated processing method precede comparative or adaptive use. LF/HF and any stress score are deferred.

# Concurrent H10 connection fix (Sep 26, 2026)

The first Pi+Android attempt emitted a BlueZ device-path-not-found connection error. The collector passed a Bluetooth address into BleakClient after a separate discovery scan, which caused Bleak to perform another implicit discovery. Pass the scanned BLEDevice object directly. After a failed connection or disconnect, refresh it by advertised Polar ID before retrying. Hardware retest with HRV Logger and the Pi concurrently remains required; if it still fails, check the H10's two-receiver BLE setting and whether another app has occupied a slot.
