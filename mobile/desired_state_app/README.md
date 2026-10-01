# Desired State Flutter app

Android app for single-Polar-H10 HR/RR recording, persistent quick markers and local session review. Recording belongs to the app's session controller and continues when opening History. Windows support still needs platform validation.

## Use

1. The app opens on **Users & History**. No recording or connection is required. Expand **Filter by user, ID, date** to select an existing participant, enter part of a session/device ID or choose an inclusive local date range. Free-text search also covers descriptions/events/tags.
2. Select the **Live** tab, open **Connect H10** (Bluetooth button) to scan/connect, return to Live and optionally enter the participant name inline. **START RECORDING** starts immediately without a setup popup. Blank participant names are recorded as unassigned.
3. Live overlays BPM and RMSSD by default; existing saved preferences remain. **Filters & metrics** opens Basic mode/metric selection, Advanced thresholds/windows/gates and Presets. The first three selected metrics share independently scaled relative trends; native-unit detailed plots remain under **Processing & plots**. One line per metric shows current/min/average/max over finite visible samples. Tap/drag freezes inspection; **Back to live** resumes the selected 30/60/300-second or All range.
4. Use **Session notes** in the Live toolbar to edit description, what helped/how you felt and tags while recording or paused, or after Stop. Save retains original data and appends edit provenance. Quick markers record events without typing. Stop saves immediately; there is no required outcome popup.
5. Browse History while recording and use its Live banner or the bottom tab to return to the same session. History's active snapshot is read-only; use Live for active notes. For stopped sessions, History can edit notes/tags/events and **Re-export session** shares originals plus annotations in a ZIP.

User filtering currently uses saved participant names; persistent profiles/default strap assignments are still pending. Screening is provisional, not ECG-verified NN classification. Recorded RR and original flags stay unchanged. Android notification and the History fixed-v1 comparison retain the original 60-interval method; configurable Live plots use v2 receipt-time windows and can differ.

## Configurable processing and plots

Live directly shows processing choices; use its **Filters & metrics** tune control for full settings. The **Processing & plots** toolbar action also opens a full-screen view from Live or History detail. Choose Raw, Range only or Artifact screened; RR bounds, deviation/reference, window seconds, minimum samples/pairs and usable RR percentage; and HR/RR/RMSSD/SDNN/pNN50/lnRMSSD plots. Apply saves defaults shared across Live/History and recomputes the derived view. Android notification and the fixed History comparison retain fixed-v1 screening; recorded flags never change.

The new `rr-configurable-v2` method restarts warm-up/reference after gaps and can reset its reference prospectively after a sustained cluster of in-range deviations. Rejected earlier RR remain excluded. Usable percentage counts accepted samples, not elapsed-time coverage. Missing/undefined values remain unavailable. Use 30/60/300-second or All presets, a bounded range slider, tap inspection and Back to live / Fit data; acquisition continues while inspecting a frozen interval.

Settings live in `desired_state_settings/processing.json`. Open sessions log initial/changed configurations; applying settings in stopped History appends `processing_views.jsonl`, included in exports. Do not equate experimental screening or HRV changes with clinical/psychological conclusions. Large-session responsiveness and phone behavior still require validation.

## Compact Live and presets

The Bluetooth button or connection-status line opens scan/reconnect/disconnect in a separate screen. During recording, reconnect retains the assigned strap/session; stop before changing devices. The first two ordered quick markers stay on Live; **More markers and events** opens the remaining buttons, management and notes. Normal portrait Live fits without vertical scrolling; small/landscape/large-text layouts can scroll to retain access.

Settings offer **Open preset**, **Save preset**, **Copy JSON** and **Import JSON**. Open/import stages the configuration; **Apply & save** activates it. Save uses a new custom name; built-ins cannot be overwritten. JSON transfers by clipboard/paste, not an OS file picker. **Default** loads the separate bundled assets/processing_default.json with the current screened v2 thresholds; **Unfiltered** uses raw mode. Default is a working configuration, not a validated best filter. Imported presets can be saved locally under a custom name. App updates retain existing saved preferences; initial raw mode is unchanged.

## Storage and compatibility

App documents contain `desired_state_sessions/<session_id>/` with schema-1 manifest and JSONL event/HR/RR files. Optional `marker_notes.jsonl` and `history_edits.jsonl` retain annotations without rewriting originals. History edits include previous/new values and edit UTC; old readers continue to see original metadata. Exports include both journals. Custom presets live in desired_state_settings/presets.json, a versioned JSON library; active processing preferences retain processing.json. Custom buttons live in `desired_state_settings/quick_markers.json`.

Older single-device sessions and readable portions of interrupted logs can be reviewed with warnings. Unknown manifest versions cannot be opened; damaged edit journals disable editing/export. History currently loads selected-session data into memory. External ZIP import, multiple devices, advanced comparisons, elapsed-time coverage and Windows parity are not implemented. App data survives ordinary updates, but not uninstall/data clearing.

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

See [current state](../../help/current-state.md) for actual validation and phone/H10 checks, [roadmap](../../help/roadmap.md) for next work, and [repository guidance](../../AGENTS.md) before editing. Current next stage is persistent Users/profiles; software tests do not establish background/Bluetooth hardware reliability.
