# Desired State roadmap

Updated 2026-09-30. Stage 1 software is implemented; phone/H10 validation remains pending. This is the agreed sequence, not a claim that later features exist. See [current-state.md](current-state.md), [app-development-plan.md](app-development-plan.md) and [project-log.md](project-log.md).

## 1. Validate recording ownership and Bluetooth recovery

Completed software is documented in current state: app-owned SessionController, manual reconnect, disconnect/stale watchdog, bounded retries, cancellation, status/age, event logging and RR continuity segments.

Remaining gate: S24/H10 trials for manual reconnect, strap loss/return, Bluetooth toggles, pause/stop during recovery, exhaustion/manual retry, screen-off/background recording and saved ZIP reconciliation. Verify one session/participant, no duplicate packets, unchanged raw RR, and no adjacency across gaps. Do not promise overnight or process-death recovery. Preserve external source backups until recovery is confirmed by the user.

## 2. Persistent users and custom quick markers

Stable user IDs, display names, preferred strap, optional notes and a default user. Keep historical assignment snapshots independent of edits. Add/remove/rename/reorder custom quick-marker definitions with stable IDs and recorded label snapshots. One tap saves label/type/time/session/participant; notes remain optional. Verify persistence across restart/update and export compatibility. Simultaneous acquisition remains separate work.

## 3. Configurable raw/screened metrics

Raw initial view, range-only and artifact-screened options; configurable bounds, deviation reference, time windows and minimum coverage. Record versioned processing configuration and changes. Never overwrite raw input. Share processing between Live/History; expose missing results, exclusions, gaps and insufficient coverage. Address seed lock-in/sustained rate changes. Initially HR, RR/IBI, RMSSD, lnRMSSD, SDNN, pNN50, coverage and baseline change. No ECG-verified NN or physiological-state claim from RR screening alone. Verify metric math, gap boundaries and settings replay.

## 4. Bounded interactive plots

Follow-live/inspect modes, bounded horizontal pan/zoom, vertical pan locked by default, fit/back-to-live and window presets. Prefer stacked native-unit plots with shared time axis, contrasting series and saved selections. Inspection uses original data; display downsampling preserves extremes. Shared cursor, marker inspection and explicit interval selection; desktop hover/wheel behavior. Prove no empty off-data viewport and continued recording during inspection. Chart library choice remains open.

## 5. Navigation and forms

Live, History, Users, Settings; mobile navigation respects system insets and desktop uses wider panels. Screens receive the existing app controller and must not own/dispose recording. Persistent recording indicator. Reachable save controls and keyboard-safe forms. Verify navigation during active recovery/recording and form behavior on the phone.

## 6. History analysis and annotation

Discover/reopen sessions across restarts; filter by user/device/date/event/outcome. Synchronized plots with gaps and markers, HR/HRV/coverage summaries, selected-segment and before/after-marker comparisons. Editable assignment/description/notes/tags/markers retain originals and edit history. Existing free-text outcomes remain compatible; distinguish subjective outcomes from trends. Define incomplete-session handling. Higher RMSSD is not automatically improvement. Verify old/new/incomplete fixtures, edits and export round-trips.

## 7. Feedback rules

Only after the above: versioned sustained-trend, data-loss/quality and recovery rules with baseline, coverage, persistence and cooldown gates. Save evidence and automatic detections separately from user markers; optional confirmation/dismissal, neutral audio and silent mode. No diagnosis or unvalidated good/bad physiological labels.

## Later integration and validation

- Multiple straps: stable per-device identity and isolated state; prove two independent disconnect/reconnect paths before experimental 4/6/8-strap targets. Python concurrency is a starting point, not Flutter completion evidence.
- Offline Python session importer, optionally exposed through Flask: compatible old/new schemas, continuity segments and pause/gap events, UTC receipt provenance, processing versions, safe archive paths/size limits, duplicate IDs and atomic publication. Validate export/import/history round-trips before claiming metric equivalence. Flask/Pi are not prerequisites.
- Windows: validate BLE backend, permissions, storage/export and foreground-service guards/replacement with a desktop layout. Runner files do not establish parity.
- Modeling, baseline personalization, stimulus and optional additional sensors follow validated acquisition/analysis contracts. No adaptive model or LF/HF autonomic-balance interpretation is implemented.

Update current state and the help log as work lands; retain raw/derived/inferred/decision distinctions. Follow [../AGENTS.md](../AGENTS.md) on both PCs.
