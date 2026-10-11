# Desired State repository guidance

## Start every handoff here

1. Locate the repository root with `git rev-parse --show-toplevel`; do not assume either PC uses the same absolute path.
2. Read `help/current-state.md`, `help/app-development-plan.md`, `help/codex-handoff.md`, `help/roadmap.md`, and `help/project-log.md`. The root `project-log.md` contains historical entries; use `help/project-log.md` for new entries.
3. Inspect `git status --short --branch`, recent commits, and the relevant code before editing. Preserve unrelated local changes, including generated Flutter plugin files. Do not reset, regenerate, or commit them incidentally.
4. Distinguish code present, automated verification, user-reported hardware results, and pending validation. Old log entries describe their time, not necessarily today's behavior.

## Agreed architecture

- Flutter is the mobile and Windows application direction, with layouts suited to each platform. Android currently works; Windows parity is pending.
- Python owns analysis/modeling and reusable processing. Keep it usable without Flask or a Pi.
- Flask is an optional API/research adapter. Raspberry Pi is optional, including for additional sensors; neither is a prerequisite for the mobile app.
- Preserve raw RR values, acquisition order, packet position, participant/device identity, and timestamp provenance. Keep derived metrics, quality flags, inferred state, and decisions separate. Never replace raw data with filtered values.
- Packet receipt time is not an exact beat timestamp. RR-based screening is provisional, not ECG-verified NN classification or a complete psychological state measurement.
- Keep local session files inspectable and portable. Version schema/processing changes and maintain compatibility deliberately.
- `SessionController` is owned above navigation by the app. Screens observe it; they must not dispose it, own recording subscriptions, or reopen files during reconnect. Respect pause/stop/manual-disconnect intent. Preserve `continuity_segment` breaks when deriving RR pairs.
- Quick markers, History MVP and core configurable processing/plots are implemented. User currently prioritizes Muse S Athena Diagnostics before persistent Users/profiles. Validate BrainFlow Android bridge first, then add Athena session logging/export with pause/stop/reconnect tests; persistent Users/default strap assignments follow. Recovery hardening/feedback is later. Shared v2 analysis must stay separate from fixed-v1 capture flags/Android notification; preserve configuration events and processing_views.jsonl in exports. Usable-fraction gates are not elapsed-time coverage. Preserve recovery checkpoint `15caeee`. Read optional marker snapshots/IDs, `marker_notes.jsonl` and `history_edits.jsonl` alongside legacy events. History edits preserve originals, previous/new values and the marker-note watermark; do not rewrite raw rows or historical marker labels. Avoid a broad refactor; include bounded plots, contrasting colors and keyboard-safe forms in touched screens.

- Startup is Overview, with persistent Live and Analyze (existing History). Navigation uses an outer Screens drawer and nested Navigator, not a bottom bar/rail; keep the menu accessible from Devices and detail routes. Keep ACC XYZ/counts, ring measurements and all selected metric summaries visible on Live, with scrollable content and bounded time browsing. Keep advanced phone options available for now; Windows uses the same codebase with richer responsive layouts, not a separate recording implementation. Separate consumer/internal builds are deferred. Overview selection uses legacy saved-name snapshots until stable profiles ship; never mix all-user/unassigned/mixed-user recordings into personal summaries or change active recording ownership when viewing a profile. Keep Live available without recreating its controller. Live uses a compact, independently scaled relative overlay (initial HR/BPM and RMSSD), with native units in single-line summaries; detailed plots retain native axes. Keep device discovery/reconnect in its own screen. Built-in processing Default is assets/processing_default.json; presets must validate versions and preserve corrupt files. Existing saved preferences are not silently reset. Start/Stop do not require note popups. Active session annotations are allowed only via the owning Live notes action; History snapshots retain their active-session write guard. Existing participant filters are not persistent profiles.

## Code map and verification

- Flutter: `mobile/desired_state_app/lib/`; tests in the adjacent `test/`. Android recording service: `android/app/src/main/kotlin/com/example/desired_state_app/` beneath that app.
- Python: all importable modules under `src/desired_state/`, with `devices/`, `storage/`, `processing/`, `api/`, and `platforms/`; tests in root `tests/`.
- For Flutter changes, from the app directory run `dart format lib test`, `flutter analyze`, `flutter test`, and `flutter build apk --debug` when Android tooling is available. After dependencies resolve, `--no-pub` avoids desktop plugin setup on machines without Developer Mode. For a confirmed cross-drive Kotlin incremental-cache failure, set `GRADLE_OPTS=-Dorg.gradle.project.kotlin.incremental=false` for the build process only. Do not upgrade dependencies or change global SDK settings incidentally.
- Discover device IDs with `flutter devices`; use `flutter run -d <device-id>`. Do not copy machine-specific SDK paths into shared guidance. Automated tests/builds are not phone/H10 validation.
- For Python changes, use the project's Python environment and run `python -m unittest discover -s tests -v` from the repository root. Setup and optional Pi/Flask commands are in `help/quickstart.md`; dependencies/entry points are in `pyproject.toml`.
- Documentation-only edits need content/link/diff checks, not an app rebuild. Report what was actually run and any environment limitations.

## Keep the next chat independent of old conversations

After meaningful implementation, architecture decisions, or hardware validation, update these documents in the same change:

- `help/current-state.md`: implemented behavior, platform-specific limits, evidence, and remaining validation.
- `help/roadmap.md`: pending work and completion criteria; move completed items into current state rather than leaving them as plans.
- `help/project-log.md`: dated entry with what changed, why, verification, and remaining risks.
- This file when working conventions or architecture change.

Do not call a planned feature implemented merely because a scaffold, dependency, related Python feature, or UI label exists. Record unresolved decisions explicitly. Never commit credentials, participant recordings, backups, generated plugin files, or build outputs. The earlier September 30 handoff was documentation-only; stage 1 implementation is recorded separately in the help log.

## Current feedback and commit conventions

Use help/state-feedback-and-upload-contract.md for current rating and backend contracts. User/Research experiences share acquisition and storage; detailed setup lives outside Live. Feedback is optional and Stop is immediate. Never reuse a prior feeling score as a new response. Every meaningful change updates help/current-state.md, help/roadmap.md and help/project-log.md, reviews its diff, runs appropriate checks and uses a descriptive commit explaining behavior, purpose and actual validation. Never describe unrun checks or planned backend functionality as complete.

## Copyable Git messages — user requirement 2026-10-08
For each meaningful delivery, provide complete copyable PowerShell staging and commit commands, beginning with the exact `cd` and `cls`; a commit message alone is insufficient. Do not execute the commit unless requested. Add a descriptive commit title/body to help/git-updates.md and output that message in chat so the user can commit locally. Keep actual validation limits in the message. Continue updating help/project-log.md, current-state.md and roadmap.md; Git updates is a separate message record, not their replacement. Do not automatically commit on the user PC unless requested or the installer is invoked with an explicit commit option.

## App structure map — 2026-10-11

`help/app-map.md` is the maintained route/action map. Update it in the same change whenever adding, moving, removing, or renaming screens or options. Keep its overview diagram compact and its action table complete at screen level. Capture/setup belongs in Recording; saved data review belongs in Analyze; profile administration and saved-recording participant corrections belong in Settings → Participants; sensor discovery and diagnostics belong in Devices. Use `PlotTemplate` and the recording-wide `PlotInspectionScope` for new time-series plots, preserving per-signal units and timestamp provenance. Recording is the visible name; existing session schema and implementation identifiers remain compatible.

## Source package file picker — 2026-10-10

For subsequent Windows source ZIP deliveries, provide a file-picker launch command rather than assuming a Downloads filename. Use a distinct descriptive package name and a fresh temporary extraction directory; renamed downloads and browser `(1)` suffixes must work. Include `source-package.json` with the relative installer path. `tools/install_source_package.ps1` provides the reusable picker/extractor once installed. Keep backups and git apply preflight; run analysis, tests and APK with existing dependency locks. Report home logs separately from workspace checks.

## Flutter regression prevention — 2026-10-10

Read `help/flutter-regressions.md` before Flutter changes/deliveries and update it with diagnosed failures. Prioritize the user's development turnaround: reproduce the cause, verify affected tests before the full suite/APK, capture complete layout diagnostics, and bundle related fixes. Check the actual selected package in transcripts before treating repeated failures as a result of a new correction. Clearly identify verification unavailable in the workspace; do not claim standalone syntax checks replace Flutter analysis/tests.

Before every Flutter build, read `help/flutter-regressions.md`, check the applicable failure-prevention items, and update the error ledger after failures or confirmed resolutions. Distribute this file and these instructions with source ZIP updates.
