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
- Added parser checks for multi-RR packets, 16-bit heart rate, energy field, and malformed RR data. Offline tests passed; live Pi Bluetooth behavior is unverified.

## 2026-09-26 — layout review v0.2

- Removed empty root-level placeholders for future modules. All Python feature modules belong under `src/desired_state/`; this avoids parallel `devices/` and `src/desired_state/devices/` trees and keeps imports and packaging predictable.
- Added this log so architecture decisions and verification remain reviewable across PC → Git → Pi handoffs.
- Kept the first milestone narrow: one strap, participant assignment, recorded session; then two straps and disconnect/reconnect; then sustained 4, 6, and 8 strap trials. The 4–8 target is experimental, not a proven adapter limit.

## Next work

1. Run the Pi scan and 60-second single-strap recording; inspect events, HR rows, RR rows, and device identity after reconnection.
2. Test two simultaneous straps and observe discovery/connect behavior, packet gaps, reconnect times, and participant identity.
3. Define stable `core/` session and signal types and a persistent sensor-to-participant registry after real advertisements establish the best stable Polar identifier.
4. Add HRV processing with transparent window/quality rules, then event marking, baseline, audio stimulus, replay, and research API/UI.

## Known limits

- Assignment is supplied on the command line per recording; no persistent assignment registry or Assign Sensor UI yet.
- Current JSONL append calls are synchronous and intended for low-rate HR/RR data; measure sustained multi-sensor runs before choosing a storage queue or database.
- BLE reconnect currently retries the initially discovered address. Validate address stability and rediscovery on the Pi; BLE adapters, RF conditions, and H10 receiver slots may constrain concurrent sessions.
- No live hardware test has been performed in this workspace. No physiological interpretation or adaptive session logic is implemented.
