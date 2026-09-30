# Desired State current state

Last reconciled: 2026-09-30, recovery checkpoint `15caeee` and revised quick-markers-first priorities. Paths below are relative to the repository root.

## Existing recovery checkpoint: implemented, awaiting hardware validation

- The app owns `lib/session_controller.dart` above screen navigation. It owns the logger, participant snapshot, recording state, RR history, timeline, markers, subscriptions, watchdog and foreground notification updates. Screen removal/recreation does not end recording.
- During an open session, **Reconnect H10** rebuilds the same selected device's connection and subscriptions. Automatic recovery runs on disconnect or ten seconds without a measurement. Each recovery cycle allows three attempts, with 2/4-second delays between failures. Each connected attempt must receive a measurement within ten seconds; a BLE connection alone is not success. After exhaustion, explicit Reconnect or Continue after pause permits another cycle.
- Pause cancels pending recovery and excludes measurements; explicit reconnect while paused restores only the link. Stop cancels recovery before closing files. Manual Disconnect suppresses automatic retries and keeps the session open; only explicit Reconnect resumes that connection. Native operations already in flight may finish before cleanup, but generation checks reject obsolete callbacks and prevent session writes.
- Recovery retains the same session ID, files, participant, description, saved notes and markers. It logs disconnection, staleness, gap, attempt, failure, success and exhaustion events. The dashboard shows actual connection state and monotonic last-data age. The foreground notification refreshes without requiring incoming packets and clears unavailable values.
- Gaps and pauses break RR adjacency and chart segments. Additive `continuity_segment` fields on measurement/RR rows and manifest `continuity_version: 1` expose the same boundaries for future readers. Existing schema-1 fields remain compatible; raw RR values, packet-local indices, order and receipt timestamps are unchanged. No missing measurements are fabricated, and equal valid packets are not deduplicated by value.
- Recovery targets the selected device identifier; address changes and process-death recovery are not implemented. Settings and later roadmap work remain pending.

### Recovery of the work-PC source tree

The F: app directory was absent. Before any recovery, the complete C: source copy (including its existing generated files) was backed up outside Git to `F:\1dev\desired-state-backups\recovery-20260930-143127\C-app`; the absent F: directory is recorded beside it. The backup contains 1,345 files, about 1.256 GB. Keep it until the user confirms recovery. An earlier partial Copy-Item backup is also retained; the named Robocopy backup completed with zero failures.

Copied source/platform/configuration files into the authoritative F: checkout, excluding build, `.dart_tool`, `.gradle`, ephemeral/symlink/Pods caches and generated plugin metadata. All tracked app files were supplied by C:, so no HEAD restore was needed. No tracked deletions remained. App source matched HEAD before implementation; seven generated desktop plugin files remained locally modified and are excluded from the stage 1 commit. C: was not edited.

### Verification and exact next step

Recovered baseline: analysis passed and all nine tests passed before implementation. Stage 1: Dart formatting passed (11 files, final check unchanged), `flutter analyze --no-pub` reported no issues, and all 20 tests passed with `flutter test --no-pub`. `flutter build apk --debug --no-pub` succeeded with command-scoped `GRADLE_OPTS=-Dorg.gradle.project.kotlin.incremental=false` after a confirmed C:/F: Kotlin incremental-cache error. APK: `mobile/desired_state_app/build/app/outputs/flutter-apk/app-debug.apk` (ignored, not committed). See [project-log.md](project-log.md). No phone/H10 test has been performed for stage 1.

**Next implementation step:** persistent custom quick markers: add/remove/rename/reorder buttons, stable IDs and historical label snapshots, one-tap timestamped events without typing, optional notes afterward, and persistence across restart/update. Use the existing participant/session fields. Then ship History MVP before the full Users screen or larger restructuring.

**History MVP requirements:** find/list/open existing saved sessions; HR/RR/RMSSD plots with event markers, gaps and value inspection; raw versus current screened data from the first version, including excluded raw RR values. Prioritize viewing events and adding "what helped/how I felt" notes, editable descriptions/notes/outcome tags and re-export with annotations while preserving raw files and edit provenance. Clearly distinguish recorded flags from any current-method recomputation and incomplete logs from completed sessions. Advanced metrics and automatic interpretation are later work.

**Revised order:** 1. Quick markers; 2. History MVP; 3. Processing and plots; 4. Users; 5. Recovery hardening and feedback. These are planned deliverables, not implemented features. Retain the controller and manual/automatic recovery checkpoint. Include improved colors, bounded plots and keyboard-safe forms wherever those screens are touched; avoid a broad refactor before markers/history ship.

**Outstanding hardware checks (not a prerequisite to marker/history implementation):** install the debug APK on the S24 Ultra and record one identified session with markers before/after gaps. Test manual Reconnect, strap out-of-range/return, Bluetooth off/on, pause and stop during recovery, exhaustion/manual retry, and 10-15 minutes locked/backgrounded. Export and verify one ID/assignment, unchanged raw RR, gap events/segments, no duplicate callbacks and no paused/post-stop rows. Confirm notification status/age. Fix demonstrated data-loss defects promptly; do not claim unattended reliability. Preserve backups until the recovered app is confirmed.

This priority update changes documentation only. The recovery validation above is from the previous implementation; no new app tests/builds or hardware checks were run for this plan change.

## Direction and evidence

Flutter is the agreed mobile and Windows client, with different layouts. Python is for analysis/modeling; Flask is an optional API and Pi an optional sensor host. The product direction remains desired state -> current state -> baseline -> personalized session -> outcome; adaptive behavior is not implemented.

The user reports that the app now builds and runs on their S24 Ultra from the work PC. This supersedes older statements that no phone build/run has occurred, but does not establish that every recording, export, or background scenario has passed.

Recent commits inspected:

- `3947812` (2026-09-29), "latest v.2 versionn working.": compact recording dashboard, timeline interactions, notification updates, pause sequence breaks, session description/outcome notes.
- `b2f3d2e` (2026-09-28), Flutter checkpoint: RR screening, explicit recording lifecycle, persistence, ZIP sharing, Android foreground-service foundation.
- `5d2fb74` (2026-09-27): initial Flutter Android collector.
- Earlier Python commits include discovered-device BLE connection handling (`a92f6dd`), recorded HRV (`15ee809`), quiet launcher (`a8c09af`), and device session history (`3b539ca`).

The earlier September 30 documentation-only inspection found seven pre-existing generated plugin-file modifications under Flutter's Linux, macOS, and Windows directories. No build, test suite, or hardware trial was rerun for that earlier handoff. Its prior validation claims are historical; the stage 1 validation above is current.

## Implemented: Flutter Android collector

- Scan/select/connect one BLE heart-rate device using `lib/polar_h10_service.dart`; parse HR and all RR intervals in a notification. One service/device and one participant per active session; stage 1 adds bounded automatic and manual recovery.
- Separate connect, recording/paused dashboard, and completed-session screens in `lib/main.dart`. Participant and optional description are entered at session start; blank participant becomes `unassigned`. Timestamped event notes and optional free-text outcome/after-state notes are saved. These are not structured before/after feedback.
- Explicit start, pause, resume, stop/save. Connection alone does not record. Live values update outside recording, but only recorded measurements enter session files and RR statistics. Pause/resume breaks RMSSD adjacency; elapsed time is wall time since start, including pauses.
- HR and cleaned-RR RMSSD timeline with event markers, 2/10/30-minute, one-hour and all-session ranges, pan/zoom, and separate numeric axes. This is the current in-memory session, not a saved-session browser.
- `lib/session_logger.dart` writes `manifest.json`, `events.jsonl`, `measurements.jsonl`, and `rr.jsonl` under the application documents directory at `desired_state_sessions/<session_id>/`. Writes are queued with open sinks, flushed after 16 rows or every five seconds, and closed on stop.
- Completed-session ZIP export through the platform share sheet, retaining the session-directory structure. Exports live under `desired_state_exports/`; source files remain. UI access is through the most recently completed logger in memory, with no restart-time history loading. No automatic upload or Flask importer exists.
- Android connected-device foreground service and public notification show recording/paused and connection status, last-data age, elapsed time, HR, RMSSD and artifact count, omitting participant names and notes. The controller refreshes at five-second intervals even without data. Pause keeps the service active; stop ends it. Force-stop recovery is absent.

## RR data and processing contracts

Flutter manifest schema is version 1, source `desired_state_flutter`, with session ID, description, `assignments`, device metadata, start UTC, and processing identifier `mobile-median9-25pct-300-2000-v1`. Measurements carry session, Polar ID, participant as `user_id`, receipt UTC, HR, and RR count. RR rows retain `rr_ms`, packet-local `rr_index`, and artifact acceptance/reason. All received RR values during active recording are retained, including rejected values; paused/pre-recording values are intentionally outside the session.

`lib/rr_history.dart` rejects nonfinite/out-of-range values outside 300-2000 ms, then deviations greater than 25% from the median of up to nine accepted intervals. RMSSD uses the latest **60 acquired intervals**, not 60 seconds; it needs three accepted intervals and an adjacent accepted pair. Rejections and explicit pause breaks prevent pairing. Raw and accepted histories remain in memory until cleared; long-session memory is unbounded. Bad seeds/sustained rate shifts can cause excessive rejection. Quality flags do not establish ECG-verified normal beats.

Mobile rows have UTC receipt times but no Python-style monotonic receipt timestamps. A packet can carry several RR intervals with the same receipt time; do not treat that as beat timing. Preserve this distinction in future imports.

## Implemented: Python and optional Flask prototype

- `src/desired_state/platforms/raspberry_pi/collect.py`: Bleak scan and explicit Polar-ID-to-participant assignments; independent concurrent sensor tasks, rediscovery/retry, session manifests and JSONL. One recorded Pi trial in `help/project-log.md` reports 58 measurements and 76 RR rows over 60 seconds. Sustained multi-strap reliability is not established.
- `api/`: Flask research page, scan and start/stop/status/stream APIs, persistent known-device/participant registry (`sessions/devices.json`), and one active collector session per process. Collector is separate from Flask. No authentication; existing operator instructions target trusted local use.
- `storage/history.py`: device-filtered saved-session summaries and reduced display timelines over existing session directories, preserving raw files. Flask exposes history, timeline and metrics routes; these features do not imply Flutter history exists.
- `processing/hrv.py`: provisional `rr-time-domain-v1` RMSSD, sample SDNN, pNN50 and mean HR from RR, acceptance and pair counts. It uses a 300-2000 ms range and >20% adjacent-jump screen, excluding pairs across monotonic receipt gaps over five seconds. This differs from mobile screening and is not guaranteed to reproduce mobile RMSSD.
- `desired-state.sh` and `help/quickstart.md`: Pi operator/Flask launch workflow. Python requires >=3.11; `pyproject.toml` currently installs Bleak and Flask together even though Flask is architecturally optional.

## Pending or unverified

- Flutter multiple participants/straps, persistent assignments, saved-session history/reopening, structured before/after feedback, improved quality reporting, Python/Flask import, and Windows-specific layouts/integration: see [roadmap.md](roadmap.md).
- Windows runner files exist, but the recording MethodChannel is implemented only on Android. BLE, permissions, sharing, and service behavior need platform-specific work/validation; a runner scaffold is not a working Windows collector.
- Screen-off/switch-app recording, locked-screen notification accuracy, interruption/reconnect, long sessions, and live share export still need recorded S24 test results. Foreground service is a foundation, not an overnight reliability guarantee.
- Stage 1 clears unavailable notification values and refreshes without data. Locked-screen rendering/timing and Android power-management behavior still require a phone trial.
- Python import must account for missing mobile monotonic timestamps, pause events and differing screening methods. Current Python metrics do not consume mobile artifact flags or pause events, so simple file transfer is not sufficient to promise equivalent metrics.
- No learned model, adaptive protocol, stimulus control, verified physiological-state inference, or additional-sensor implementation was found.

## Documentation precedence

Use this snapshot and [roadmap.md](roadmap.md) for current status and plans, and [project-log.md](project-log.md) for dated evidence. The root `project-log.md` contains newer Flutter history absent from the help log; it remains historical. Older claims of no persistence, no registry, a 60-second mobile RMSSD window, or stopping the service on pause have been superseded by code. Root/app README files still contain early/scaffold descriptions. Future handoffs should follow [../AGENTS.md](../AGENTS.md).
