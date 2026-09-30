# Desired State roadmap

Reprioritized 2026-09-30: quick markers first, then History MVP. This order supersedes the earlier recovery/users-first plan. See [current-state.md](current-state.md), [app-development-plan.md](app-development-plan.md) and [project-log.md](project-log.md). Quick-marker software is now implemented; History MVP is next. Later stages and phone validation remain pending except for the existing recovery checkpoint.

## Existing recovery checkpoint: preserve

Commit `15caeee` already implements app-owned recording, manual Reconnect H10, bounded automatic recovery, stale-data detection, subscription cancellation, status/age and gap continuity logging. Keep this work. Prior validation: 20 tests, clean analysis and an Android debug APK; phone/H10 reliability remains unverified. Retain the outstanding device checks and external backups. Do not delay markers/history for broader recovery work or a major refactor; fix demonstrated recording/data-loss defects promptly.

## 1. Quick markers - software completed

Persistent custom buttons, add/rename/remove/reorder, immutable event snapshots, optional later notes and annotation-aware export are implemented. See [current-state.md](current-state.md) for storage contracts and automated evidence. Remaining device checks: confirm labels/order after phone restart/update, repeated taps during H10 recording, note entry while recording/paused/after Stop, and exported annotations. This does not block History MVP.

## 2. History MVP - next

Prioritize finding a session, viewing its events and adding "what helped/how I felt" notes. List/open existing local sessions across restarts, using current participant/device metadata. Show HR/RR/RMSSD plots with event markers, gaps and timestamp/value inspection. Expose **raw versus current screened data immediately**, including excluded raw RR values, with explicit method/window labels. Preserve recorded flags and distinguish them from any current-method recomputation; raw rows never change and RR pairs never bridge gaps or exclusions.

Read existing marker event IDs/label snapshots and optional `marker_notes.jsonl`, while supporting older files without them. Edit descriptions, notes and outcome tags with originals/edit provenance retained. Re-export the selected session including annotations. Handle older files and incomplete/interrupted sessions explicitly. Do not require a full Users screen, configurable filters, advanced metrics, segment comparisons or automatic interpretation first. Use existing session files with deliberate compatible metadata extensions.

Completion: old/new/incomplete-session fixtures; restart/list/open; known excluded RR visible in raw view; screened math and gap boundaries; event/value inspection; annotation persistence and export round-trip without raw changes. Include contrasting plot colors, bounded movement and keyboard-safe forms in this MVP.

## 3. Processing and plots

Expand the MVP comparison to configurable raw/range-only/artifact-screened analysis, RR bounds/deviation reference, windows and coverage gates. Choose metrics and improve plot interactions, colors and bounds; share processing between Live/History and record configuration/version changes. Address filter seed lock-in and sustained rate changes without replacing raw input. More advanced metrics/segment comparisons follow the usable history flow.

Completion: processing math, settings replay, missing-result/exclusion reporting, bounded viewport/inspection and recording during plot interaction. No ECG-verified NN or physiological-state claim from RR screening alone.

## 4. Users

Persistent profiles, stable user IDs, defaults/preferred strap assignments and history filtering by user/device. Preserve historical assignment snapshots when profiles change. Existing participant information supports stages 1-3; simultaneous collection remains separate.

Completion: restart/update persistence, historical identity stability, assignment changes and user/device filtering. Add focused navigation when needed, not a prerequisite app-wide restructuring.

## 5. Recovery and feedback

Validate/harden existing automatic Bluetooth recovery where needed; manual reconnect is already available. Device checks remain strap loss/return, radio toggles, manual recovery, pause/stop races, retry exhaustion, screen-off/background behavior and saved-file reconciliation. Do not claim force-stop or overnight reliability.

Later add background trend detection and optional neutral audio cues, with versioned rules, evidence, baseline/coverage gates, persistence and cooldown. Automatic detections stay separate from user markers. Verify cancellation, sustained detection/cooldown and silent mode. No diagnosis or unvalidated good/bad physiological labels.

## Requirements across touched screens

Improve contrasting colors, bound plots where present, and keep forms keyboard/system-inset safe with reachable Save controls. Navigation and inspection must retain the existing app-owned recording controller. Keep changes focused on markers/history first; larger restructuring is deferred. Preserve raw data and distinguish subjective outcomes from measured trends; higher RMSSD is not automatically improvement.

## Later integration and validation

- Multiple straps: stable per-device identity and isolated state; prove two independent disconnect/reconnect paths before experimental 4/6/8-strap targets. Python concurrency is a starting point, not Flutter completion evidence.
- Offline Python session importer, optionally exposed through Flask: compatible old/new schemas, continuity segments and pause/gap events, UTC receipt provenance, processing versions, safe archive paths/size limits, duplicate IDs and atomic publication. Validate export/import/history round-trips before claiming metric equivalence. Flask/Pi are not prerequisites.
- Windows: validate BLE backend, permissions, storage/export and foreground-service guards/replacement with a desktop layout. Runner files do not establish parity.
- Modeling, baseline personalization, stimulus and optional additional sensors follow validated acquisition/analysis contracts. No adaptive model or LF/HF autonomic-balance interpretation is implemented.

Update current state and the help log as work lands; retain raw/derived/inferred/decision distinctions. Follow [../AGENTS.md](../AGENTS.md) on both PCs.
