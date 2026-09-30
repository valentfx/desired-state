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

## 2026-09-27 — Flutter RR artifact screening

- Added `mobile/desired_state_app/lib/rr_history.dart` as a separate, provisional processing layer. Preserve every raw RR interval in acquisition order for the in-memory session, including rejected values; store accepted RR separately and expose read-only histories. Removed the old 300-sample raw-history truncation. Disconnect clears both histories and the artifact count, as it previously cleared raw history; disk persistence is not implemented.
- Reject nonfinite RR and values outside 300–2000 ms. Accept the first in-range interval as the seed, then reject deviations greater than 25% from the median of up to nine recent accepted intervals. Rejected values never enter the median reference. This heuristic is not ECG-verified NN classification: a bad initial seed or sustained large rate change can cause excessive rejection; adaptive reseeding is deferred.
- Calculate provisional cleaned RMSSD over the latest 60 acquired intervals, requiring at least three accepted intervals and one adjacent accepted pair. Rejected intervals break pairs, so the calculation never bridges an artifact gap. A window without sufficient accepted data displays `--` rather than indefinitely retaining an old clean result.
- Collector UI labels RMSSD as clean and shows raw, accepted, and rejected session totals. Latest RR remains the raw received value. Empty-RR packets still update heart rate. Added an optional collector service injection point for UI regression tests; BLE scan, permissions, connection, packet parsing, notifications, and raw debug logging are unchanged.
- Verification: Dart formatting completed on the four changed Dart files; `flutter analyze` reported no issues; `flutter test` passed all eight tests. Coverage includes filtering thresholds, nonfinite values, raw retention beyond 300 samples, contiguous-pair math, rolling-window expiry, reset, and streamed UI updates. An initial asynchronous widget-test timing failure was corrected by waiting for rendering.
- Remaining validation: run the updated app on the S24 Ultra with the H10 and compare raw RR, accepted/rejected counts, and cleaned RMSSD. No live hardware test was performed for this change. Session histories grow in memory until disconnect; persistence and long-session storage remain future work.

## 2026-09-27 — Flutter identifiable session logs and event notes

- The mobile collector now creates one on-device session directory after it connects to an H10. It stores `manifest.json`, `events.jsonl`, `measurements.jsonl`, and `rr.jsonl` under the app's documents directory. The manifest records the source, session ID, advertised H10 name, stable Polar ID, and participant name entered before connection. The known strap `Polar H10 E9E53B2C` is normalized to `E9E53B2C`.
- Raw RR rows remain append-only and record the mobile artifact-screen result and reason without replacing or changing the raw interval. Measurement rows use the same keys as the Pi collector where applicable, so the existing Flask history/timeline reader can import them after an explicit transfer/upload path is added. Packet receipt timestamps remain timestamps of receipt, not inferred beat times.
- Added a participant-name text field, disabled during an active session so the manifest and rows identify one consistent participant. Added a two-line event-description field; MARK EVENT writes a `marked_event` row with the entered text and clears the field after saving.
- Added storage-plugin dependency `path_provider` and a session-log regression test. Dart formatting completed, `flutter analyze` reported no issues, and `flutter test` passed all nine tests. No phone build or live H10 run has been performed. Windows Developer Mode must be enabled before Flutter can build plugins with this environment.
- A Flask server cannot read Android-private storage directly. Next work: add a trusted-LAN import/upload endpoint and a deliberate Upload session action so the phone transfers a completed directory into the Flask `sessions/` root; keep automatic background transfer out of scope until the explicit flow is validated.

## 2026-09-27 — Explicit mobile recording lifecycle

- Bluetooth connection no longer starts a session automatically. Start Recording creates a new identifiable session and resets its RR/RMSSD history. Pause writes `session_paused` and leaves the H10 connected, but excludes incoming measurements and RR values from the session while paused. Continue writes `session_resumed` and appends to the same files. Stop & Save writes `session_ended`, closes the log, and retains the completed on-screen totals until the next Start.
- Live heart rate and latest RR remain visible before recording and while paused; derived RMSSD and session totals are limited to recorded data so saved files, displayed counts, and derived values share one scope. Participant name remains editable until a session starts.
- Flutter analysis reported no issues and all nine tests passed. The widget check verifies that pre-recording RR values do not enter a session. Live-device behavior remains to be checked on the S24 Ultra.

## 2026-09-27 — Completed-session share export

- Added a deliberate export path for a completed mobile session. Stop & Save now exposes Share Completed Session, which writes a ZIP copy containing the session directory's `manifest.json`, `events.jsonl`, `measurements.jsonl`, and `rr.jsonl`, then opens the Android share sheet. Dropbox can be selected there when its app is installed and signed in; no Dropbox credentials are stored in Desired State.
- The ZIP keeps the session directory name, allowing a later Flask import utility to validate and unpack it atomically into the server's `sessions/` root. It does not automatically upload or delete the phone's private source files.
- Added ZIP-content verification to the session-log test. Flutter analysis reported no issues and all nine tests passed. Live Android sharing and a Flask importer remain to be tested and implemented respectively.

## 2026-09-27 — Screen-off mobile recording foundation

- Recording now starts an Android `connectedDevice` foreground service and its persistent low-priority notification. Pause and Stop end that foreground service; Start and Continue begin it while the app remains in the foreground. The manifest declares notification and connected-device foreground-service permissions, and the existing Bluetooth permission request includes notification permission.
- The foreground service is intended to keep the active Flutter process eligible to receive the already-subscribed H10 notifications when the screen is off or the user switches apps. It does not survive a force-stop, does not yet reconnect automatically after a strap or process disconnect, and needs a real S24 screen-off trial before use as an unattended overnight recorder.
- Removed per-packet debug console output. Session JSONL streams now use open file sinks, flushing after 16 rows or every five seconds, and flush/close on Stop. This lowers file-system work during sustained collection while bounding the loss from an unexpected process failure to unflushed recent data.
- Dart formatting and Flutter analysis passed; all nine Flutter tests passed; a debug Android APK built successfully. Next validation: grant notification permission, set the app battery setting to Unrestricted, run a 10–15 minute locked-screen test, then test an interruption/reconnect path before an overnight recording.

## 2026-09-30 - Repository handoff and architecture reconciliation

- Inspected code and commits through `3947812`, including the September 28 Flutter entries in the separate root `project-log.md`. Added root `AGENTS.md`, `help/current-state.md`, and `help/roadmap.md` so either PC can resume without the previous conversation. Use this help log for future dated entries; preserve the root log as historical evidence.
- Confirmed direction: Flutter mobile and Windows with different layouts; Python analysis/modeling; optional Flask API and optional Pi/additional sensors. Preserve raw RR and distinguish raw, derived, inferred and decision data.
- Recorded implemented mobile recording, local files, ZIP sharing, chart/notes and Android service separately from planned multi-participant/strap support, mobile saved-session history, structured feedback, improved RR quality, imports and Windows integration. Existing Python history, registry and concurrent acquisition code are not evidence of those Flutter features.
- Corrected current-state interpretation against code: mobile RMSSD uses 60 acquired intervals, not 60 seconds; pause retains the foreground service. Mobile/Python quality methods differ, and mobile rows lack monotonic timestamps. Import must handle pause/gap semantics explicitly.
- User reports successful S24 Ultra build/run from the work PC. Detailed screen-off, interruption, long-session and sharing validation remain unconfirmed. Historical automated/build results are labeled as historical; no app test, build or hardware run was performed for this documentation-only change.
- Verification: reviewed document claims against source, checked local document links and documentation diff. No app behavior was changed. Seven pre-existing generated Linux/macOS/Windows plugin-file modifications were left untouched.

## 2026-09-30 - Source recovery and stage 1 recording ownership/Bluetooth recovery

- F: is the authoritative work-PC Git checkout; the C: app was a non-Git local source copy. The entire F: app directory was absent before recovery. Backed up the full C: app to `F:\1dev\desired-state-backups\recovery-20260930-143127\C-app` (1,345 files, about 1.256 GB, zero Robocopy failures); recorded F: absence in the same backup folder. The first Copy-Item attempt failed on a long generated Android filename; that partial backup is retained too. Keep the complete backup until the user confirms recovery.
- Copied the C: source/platform/configuration files into F:, excluding generated build/tool/Gradle/ephemeral/symlink/Pods directories and generated plugin metadata. All tracked app files were present after copying, so no files required restoration from HEAD. No tracked deletions remained. App source matched HEAD before stage 1; seven pre-existing generated desktop plugin-file differences were preserved and excluded from the intended commit. C: remained unchanged.
- Verified the recovered baseline before implementation: `flutter analyze --no-pub` passed; `flutter test --no-pub` passed all nine tests. Initial ordinary analysis resolved dependencies but stopped on desktop plugin symlink support (Windows Developer Mode); no dependency constraints or lockfile changes were made.
- Added app-owned `SessionController`; screens receive/observe the controller and do not own recording lifetime. It retains the logger, participant snapshot, session ID, description, saved notes, markers, RR history and timeline through navigation and recovery. Start remains explicit. Stop disables recording/cancels recovery before closing the existing log. Manual disconnect keeps the session open while suppressing automatic retry.
- Added Reconnect H10, disconnect monitoring and a ten-second stale-measurement watchdog using monotonic elapsed time. Recovery allows three attempts with 2/4-second delays; each attempt requires an actual packet within ten seconds after connection. Exhaustion waits for user intent. Pause/stop/disconnect invalidate outstanding work; reconnect while paused restores only the link. Native BLE operations have their existing timeouts and may finish before serialized cleanup, but cannot reactivate obsolete packet callbacks.
- Serialized BLE connect/disconnect operations, canceled obsolete connection/notification subscriptions, guarded callbacks with connection generations and synchronous delivery, and retained every legitimate equal-valued packet. No value-based deduplication or raw-data filtering was added.
- Logged disconnect/stale/gap/recovery attempt/failure/success/exhaustion events. Added compatible optional `continuity_segment` fields to measurement/RR rows and manifest `continuity_version: 1`. RR adjacency and chart paths break across gaps/pauses; raw values, acquisition order, packet indices and receipt UTC remain unchanged. No inferred missing beats are written. Future import/analysis must honor these segments.
- Dashboard shows connection status and last-data age; foreground updates run without incoming packets and clear null HR/RMSSD values. Removed the unconditional Good signal claim. Completed sessions can return to device connection after a disconnect.
- Final automated verification: `dart format lib test` checked 11 files (final run: zero changes); `flutter analyze --no-pub` reported no issues; `flutter test --no-pub` passed all 20 tests. Tests include raw/session/participant/note/marker continuity, gap RMSSD, stale detection before a watchdog tick, silent-stream and radio-failure exhaustion, manual retry, pause/stop during connection, paused reconnect, manual disconnect suppression, screen disposal/recreation, obsolete BLE listeners and equal valid packets.
- Android verification: initial `flutter build apk --debug --no-pub` failed in share_plus Kotlin incremental caches; Gradle logs confirmed different C:/F: source roots. Retrying with command-scoped `GRADLE_OPTS=-Dorg.gradle.project.kotlin.incremental=false` succeeded, including the final code build. APK is at `mobile/desired_state_app/build/app/outputs/flutter-apk/app-debug.apk`, ignored and not committed. SDK/cache permissions required elevated tool execution; no global settings or shared SDK paths were changed.
- Documentation updated: root AGENTS, current state, roadmap, development-plan status and Codex handoff. Content/link/diff checks accompany the intended-file commit. No Python implementation changed; Python tests were not rerun.
- Still unverified: S24/H10 radio toggles, strap loss/return, manual recovery during recording, pause/stop races on native BLE, screen-off/background recovery, exhaustion/manual retry and real exported-file reconciliation. Foreground service does not survive force-stop/process death; address changes, Windows parity, and long-session memory bounds remain open. Exact next step is the device trial in current state, then persistent users/custom quick markers, configurable raw/screened metrics, bounded plots, navigation/forms, history analysis and finally feedback rules.

## 2026-09-30 - Reprioritize quick markers and History MVP

- User revised the next-work sequence: 1. persistent quick markers; 2. History MVP; 3. processing and plots; 4. Users; 5. recovery hardening and feedback. This supersedes the earlier recovery-validation/users-first ordering, not the completed implementation. Preserve checkpoint `15caeee`, its app-owned controller and manual/automatic recovery. Hardware reliability remains unverified; those checks do not block marker/history implementation. Address demonstrated data-loss defects promptly.
- Quick markers: persistent custom buttons, add/remove/rename/reorder, stable IDs and historical label snapshots, one-tap events without typing, optional later notes. Use existing participant/session information; profiles and broad restructuring are not prerequisites.
- History MVP: find/list/open saved sessions, HR/RR/RMSSD plots with event markers/gaps/value inspection, raw versus current screened data from its first version (including excluded RR), editable descriptions/notes/outcome tags and re-export. Prioritize events and "what helped/how I felt" notes ahead of advanced metrics or automatic interpretation. Preserve raw rows, recorded screening flags, metadata originals and edit provenance; label recomputation and incomplete logs explicitly.
- Include improved colors, bounded plots and keyboard-safe forms wherever screens are touched; larger configuration/interaction work follows in stage 3. Updated development plan, roadmap, current state, Codex handoff and AGENTS so the next implementation starts with quick markers, then history.
- Verification: reviewed current controller/logger code and Git state; checked document links, diff whitespace and consistent stage ordering. Documentation-only change: no app behavior changed and no new Flutter/Python tests, APK build or hardware checks were run. Prior validation belongs to the recovery checkpoint. Seven pre-existing generated desktop plugin-file changes and external backups remain untouched.
