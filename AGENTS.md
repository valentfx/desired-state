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
- Quick markers, History MVP and core configurable processing/plots are implemented. Next: Users, then recovery hardening/feedback. Shared v2 analysis must stay separate from fixed-v1 capture flags/Android notification; preserve configuration events and processing_views.jsonl in exports. Usable-fraction gates are not elapsed-time coverage. Preserve recovery checkpoint `15caeee`. Read optional marker snapshots/IDs, `marker_notes.jsonl` and `history_edits.jsonl` alongside legacy events. History edits preserve originals, previous/new values and the marker-note watermark; do not rewrite raw rows or historical marker labels. Avoid a broad refactor or Users prerequisite before markers/history ship; include bounded plots, contrasting colors and keyboard-safe forms in touched screens.

- Startup is Users & History; keep Live available without recreating its controller. Live embeds configurable plots and visible-range finite-sample min/max/average. Start/Stop do not require note popups. Active session annotations are allowed only via the owning Live notes action; History snapshots retain their active-session write guard. Existing participant filters are not persistent profiles.

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
