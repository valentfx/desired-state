# App development plan — 2026-09-30

## Status and architecture

Baseline inspected: GitHub commit 3947812. User confirmed Android app builds and runs on work PC/S24 Ultra. Newer local Codex edits may exist; inspect them before implementing. This document records agreed scope, not completed implementation.

Current code includes single-H10 acquisition, explicit start/pause/resume/stop, participant and session description, optional-text markers, live HR/RMSSD plots, raw-preserving RR screening, session JSONL logging, ZIP export, outcome notes, and Android foreground-service support. Recovery, history UI, profile persistence, and simultaneous Flutter straps remain planned. Hardware reliability must be tested.

Flutter owns mobile/Windows UI, local acquisition/storage and live processing. Python owns canonical analysis/modeling; Flask is an optional integration boundary. Pi is optional for additional sensors. Recording must be independent of navigation. Preserve raw signals and clock provenance; packet receipt time is not exact beat time.

## Required changes

1. Bluetooth recovery: manual Reconnect H10, automatic reconnect and stale-measurement watchdog. Preserve session/files/participant/events; cancel old subscriptions; avoid duplicate callbacks. Log gap/recovery; do not fabricate missing data or calculate adjacent RR pairs across gaps. Stop/pause intent must override recovery; bounded retries and clear status/last-data age.
2. Persistent quick markers: add/remove/rename/reorder custom labels (examples anxious, palpitations, dizzy, breath hold). One tap saves label/type, timestamp, participant and session without typing. Optional later notes. Stable definition IDs and recorded label snapshots; persistence across restart/update, not guaranteed across uninstall. Preserve historical labels when definitions change.
3. Persistent users: stable user ID, display name, preferred H10 ID, optional notes and default user. Capture historical session assignment. Model multiple users/devices now; simultaneous collection is a separate validated step.
4. Configurable processing: Raw initial view; Range only and Artifact screened options. Adjustable RR bounds, deviation threshold/reference length, time-window duration, minimum coverage. Current filter uses 300–2000 ms and 25% deviation from nine accepted intervals; sustained real changes can be over-rejected. Raw remains immutable. Raw means no physiological screening, with unusable numerical inputs handled explicitly. Recompute view on setting change; record processing configuration/version and changes. Same processing interface for Live/History. No bridging pauses/disconnects/rejections; show missing results and exclusion reasons. Replace unconditional Good signal label.
5. Navigation/forms: Live, History, Users, Settings; restore defaults at startup, recording begins explicitly. Navigation never stops recording; persistent recording indicator. Mobile bottom navigation respects system insets; desktop wider navigation rail/panels. Text forms top-aligned or full-screen with reachable top Save action; keyboard and Android system-navigation safe areas.
6. History/analysis: session list filtered by user, strap, date, event type and outcome tags. Session detail synchronized plots, markers and gaps. Summary HR, RMSSD, SDNN, coverage/exclusions, selected-segment and before/after-marker comparisons. Editable user assignment, description, notes, tags and marker labels/times with original data and edit history retained. Separate subjective improved/worse/helpful factors from measured trends. Higher RMSSD is not automatically improvement. Import/export integration follows explicit validation.
7. Plotting: contrasting blue/orange/purple candidates, matching labels/styles. Selectable metric cards/series saved per user. Prefer stacked plots with shared time axis and native units. Follow live and Inspect modes. Vertical pan locked by default, bounded horizontal pan/zoom, no empty off-data viewport. Fit data and Back to live; 30 s/1 min/5 min/All presets, optional fixed Y range. Stable autoscale with padding. Tap/long-press cursor shows actual timestamps, values, units, processing/window/quality; shared across plots. Marker inspection/edit; explicit interval-selection mode with summary. Desktop hover/wheel/selection. Recording continues during inspection. Display-only downsampling preserves extremes and raw data; inspection/calculation use original samples.
8. Metrics: initial HR, raw RR/IBI, RMSSD, lnRMSSD, SDNN, pNN50, coverage/exclusions and baseline change. Default HR/RMSSD; RR easy to enable. Specify time windows, minimum samples/pairs/coverage and warm-up behavior. Do not represent HRV as diagnosis or LF/HF as autonomic balance. Spectral/nonlinear metrics deferred pending validation.
9. Feedback later: configurable sustained HR/HRV trend, loss/quality and recovery rules. Window, threshold, baseline, coverage gate, persistence and cooldown. Save automatic detections separately from user markers with rule version/evidence; allow confirmation/dismissal. Optional neutral audio cues and silent mode; do not equate trends with good/bad physiology or diagnose rhythm disorders.

## Implementation sequence

1. Session controller and Bluetooth recovery.
2. Profiles, settings persistence and one-tap markers.
3. Configurable processing and metric/quality reporting.
4. Navigation, accessible forms and bounded interactive charts.
5. History, annotations and segment comparisons.
6. Feedback rules/audio; later simultaneous straps and expanded desktop analysis.

Refactor incrementally: lib/app, domain, acquisition, recording, processing, feedback, storage, features/{live,history,users,settings}, widgets. Start by extracting recording ownership from main.dart. Avoid empty scaffolding or a wholesale move without behavior improvements.

Evaluate fl_chart behind an app-owned plot component; verify tooltips, bounded movement, shared cursors and long-session performance before adopting broadly. Syncfusion is an alternative subject to applicable license. Keep chart library separate from acquisition and metric computation.

## Validation and handoff

Inspect git status/log and existing changes first. Do not overwrite local work. Implement in reviewable stages; update current-state and project-log after each stage. Run format/analyze and focused regression tests. Required tests: reconnect/stale stream and duplicate prevention; same-session raw retention; pause/stop during recovery; marker/profile persistence; raw versus screened metric math, gaps and settings replay; navigation preserving recording; bounded viewport and keyboard-safe forms; history edit provenance. Real device checks: out-of-range/return, manual recovery, screen-off recording, repeated marker taps and persistence after restart. Label tests/builds not actually run.

At handoff report completed scope, checks, limitations, modified files and exact next step. Commit only intended files and push when explicitly requested. Keep raw participant recordings out of code commits.
