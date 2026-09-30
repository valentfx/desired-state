# Desired State Flutter app

Android app for single-Polar-H10 HR/RR recording, persistent quick markers and local session review. Recording belongs to the app's session controller and continues when opening History. Windows support still needs platform validation.

## Use

1. On Live, connect the H10, enter participant/session information and explicitly start recording. Quick-marker buttons record events without typing; optional notes can follow. Pause, Stop and Reconnect H10 remain available on Live.
2. Open **History** to search saved local sessions by participant, device, description, marker or tag. Open a session and expand **Events & notes** to review markers. Active sessions are read-only saved-data snapshots; Refresh reads more flushed data.
3. Compare **Raw** with **Current screened**, tap/long-press a plot to inspect values, and use Previous/Next RR for intervals with the same packet receipt time. The shared time-range slider stays within saved timestamps; **Fit data** restores the full range.
4. After Stop, **Edit notes & tags** saves the description, what helped/how you felt and outcome tags. Event notes have a separate edit action. **Re-export session** opens the platform share sheet with originals and annotations in a ZIP.

Current screening is provisional, not ECG-verified NN classification. It uses 300–2000 ms and 25% deviation from the median of up to nine accepted RR intervals. RMSSD uses the latest 60 acquired readable intervals, at least three usable values and one adjacent pair. Rejected intervals and gaps break pairs; receipt timestamps are not exact beat times. Raw data and originally recorded screening flags are never replaced by this comparison.

## Storage and compatibility

App documents contain `desired_state_sessions/<session_id>/` with schema-1 manifest and JSONL event/HR/RR files. Optional `marker_notes.jsonl` and `history_edits.jsonl` retain annotations without rewriting originals. History edits include previous/new values and edit UTC; old readers continue to see original metadata. Exports include both journals. Custom buttons live in `desired_state_settings/quick_markers.json`.

Older single-device sessions and readable portions of interrupted logs can be reviewed with warnings. Unknown manifest versions cannot be opened; damaged edit journals disable editing/export. History currently loads selected-session data into memory. External ZIP import, multiple devices, configurable processing, advanced comparisons and Windows parity are not implemented. App data survives ordinary updates, but not uninstall/data clearing.

## Development

From this directory with Flutter/Dart on PATH:

```powershell
flutter pub get
dart format lib test
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --no-pub
flutter devices
flutter run --no-pub -d <device-id>
```

APK: `build/app/outputs/flutter-apk/app-debug.apk`. Keep generated outputs and private recordings out of Git. On the work PC, a confirmed C:/F: Kotlin cache issue is worked around for the build command with `$env:GRADLE_OPTS = '-Dorg.gradle.project.kotlin.incremental=false'`; do not change global SDK settings.

See [current state](../../help/current-state.md) for actual validation and phone/H10 checks, [roadmap](../../help/roadmap.md) for next work, and [repository guidance](../../AGENTS.md) before editing. Current next stage is configurable processing and plots; software tests do not establish background/Bluetooth hardware reliability.
