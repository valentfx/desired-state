# Desired State roadmap

Reprioritized 2026-09-30: quick markers first, then History MVP. This order supersedes the earlier recovery/users-first plan. See [current-state.md](current-state.md), [app-development-plan.md](app-development-plan.md) and [project-log.md](project-log.md). Quick markers, History MVP and the core configurable processing/plots scope are implemented; Users is next. Later stages and phone validation remain pending except for the existing recovery checkpoint.

## Existing recovery checkpoint: preserve

Commit `15caeee` already implements app-owned recording, manual Reconnect H10, bounded automatic recovery, stale-data detection, subscription cancellation, status/age and gap continuity logging. Keep this work. Prior validation: 20 tests, clean analysis and an Android debug APK; phone/H10 reliability remains unverified. Retain the outstanding device checks and external backups. Do not delay markers/history for broader recovery work or a major refactor; fix demonstrated recording/data-loss defects promptly.

## 1. Quick markers - software completed

Persistent custom buttons, add/rename/remove/reorder, immutable event snapshots, optional later notes and annotation-aware export are implemented. See [current-state.md](current-state.md) for storage contracts and automated evidence. Remaining device checks: confirm labels/order after phone restart/update, repeated taps during H10 recording, note entry while recording/paused/after Stop, and exported annotations. This does not block History MVP.

## 2. History MVP - software completed

Local session discovery/search/reopening, events, raw/current-screened HR/RR/RMSSD plots, gap-aware value inspection, bounded time range, description/outcome/event notes and tags, append-only edit provenance, and annotation-aware re-export are implemented. Legacy and interrupted logs are covered by fixtures. Recording remains app-owned during History navigation. See [current-state.md](current-state.md) for storage contracts, 40-test evidence, compatibility limits and APK validation.

Remaining device checks: restart/update, existing real recordings, keyboard/touch/inspection, re-export/share contents, History during H10 recording and long-session performance. Selected-session files currently load in memory; scalable analysis, multi-device history and import remain later work.

## 3. Processing and plots - core software completed

Shared Live/History configurable analysis, persistent versioned defaults, raw/range/screened modes, bounds/deviation/reference/window/sample/pair/usable-fraction gates, prospective reference reset, metric selection and bounded follow/inspect controls are implemented. Acquisition flags and the Android notification remain fixed-v1; Live now embeds the configurable view with visible-range min/max/average summaries. Configuration changes and History applications are logged and exported. See [current-state.md](current-state.md) for the v2 contract and current 55-test evidence, including direct Live filters/notes/statistics.

Pending device checks: preferences across phone restart/update, keyboard/touch behavior while recording, frozen/return-to-live plots, configuration export and long-session performance. Follow-up features: elapsed-time coverage (current gate is usable sample fraction), fixed Y bounds, desktop hover/wheel, historical configuration picker, segment comparisons and memory/UI-isolate scaling. No ECG-verified NN or physiological-state claim from RR screening alone.

## 4. Persistent Users/profiles - next

Persistent profiles, stable user IDs and defaults/preferred strap assignments remain pending. History already opens first and filters existing participant snapshots, session/device ID and local date range. Preserve historical assignment snapshots when profiles change. Existing participant information supports stages 1-3; simultaneous collection remains separate.

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
