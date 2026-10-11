# Git updates

Use this file for copyable commit titles/bodies. Record detailed work evidence in project-log.md; maintain current-state.md and roadmap.md separately. Show the proposed commit message in chat whenever delivering a change. State only checks actually run. Never include credentials or participant recordings.

## EEG powerbands and optical capture — ready to validate on PC

Title:
Add unscreened EEG powerbands, optional artifact comparisons and Athena optical capture

Body:
Reuse five-band dB plots and screened/unscreened comparisons across Metric details and Analyze. Add Gamma, raw EEG overlays, persistent screening/optical choices and concise RR comparison tools. Preserve original logs and the compact Session layout. Capture experimental raw Athena optical data without claiming calculated brain oxygenation.

Validation before installation: 14 standalone numerical EEG checks, preference persistence/migration checks, Dart syntax/format checks, bundled BrainFlow API signatures and package/diff checks. Full Flutter analysis/tests/builds and physical sensor/UI acceptance remain pending. Installer appends actual PC validation below after successful checks.

## Work-PC package repair — 2026-10-08

Title:
Rebase EEG update onto current work PC source and record copyable Git messages

Body:
Refresh guarded installer baseline to main commit 05d61b1; preserve current timer, compact layout and diagnostic changes. Separate copyable Git messages into help/git-updates.md and require future delivery responses to include them. Package source checks pass against the current committed work PC files; full Flutter and hardware acceptance remain pending.

## Preserve local guidance during installation — 2026-10-08

Title:
Preserve local repository guidance in EEG update installer

Body:
Append the Git-message workflow to AGENTS.md instead of replacing machine-local guidance. Keep application source and package hash checks intact. Verified append-only installer structure and ZIP contents; PC execution remains pending.

Title: Guard optical setting error UI after asynchronous saves
Body: Check State and builder context lifetimes before displaying save errors. Full PC validation pending.

## EEG comparison and preset regressions — 2026-10-08

Title:
Update raw-default and EEG comparison regression tests

Body:
Verify raw processing presets and current Analyze dB/µV²/overlay controls. Start the absolute EEG power axis at zero. Work-PC analysis passed before this change; full suite and builds remain pending.

PC validation: Flutter analysis, full tests, Windows release and Android debug builds passed; shared phone upgraded in place. Physical optical acquisition and viewport acceptance remain pending.

# Copyable Git messages

## 2026-10-09 — Apple bootstrap

Title: Prepare Apple Bluetooth acquisition and manual cloud build/TestFlight workflows

Body:
Use iOS Bluetooth authorization rather than Android scan/connect permissions; declare BLE background capability and Mac sandbox access. Route Android foreground-service calls only on Android so Apple recording can start with the shared logger. Add platform regressions, manually triggered macOS build and iPhone/iPad TestFlight workflows, and Windows signing helpers. Preserve raw streams, Android identity, dependencies and generated plugins.

Native configuration, Bash syntax, workflow parsing and Git diff checks pass. Flutter analysis/tests, Xcode builds/signing and Apple hardware validation remain pending; no TestFlight upload performed. Muse remains Android-only; Apple background recording is not yet validated.


## 2026-10-10 — Recording update
```text
Consolidate Recording settings and add elapsed-time touch inspection

Rename Session to Recording; reopen full setup for the next recording. Persist recording-type popularity and configurable readout fields, defaulting ECG off. Route H10 metric/filter choices through one settings screen, add shared elapsed-time axes/readouts, and expose optional marker notes and audited analysis event edits. Preserve original logs and type snapshots.

Validation: Dart formatting/syntax, six injected-directory storage checks and patch/ZIP checks pass. Flutter analysis/full widget tests, APK build and phone validation remain pending on the PC.
```

## 2026-10-11 — Recording / Analyze structure

```text
Unify Recording plots and simplify Analyze navigation

Add elapsed-time axes and a recording-wide touch cursor/readout across H10, EEG,
ECG and other signals, using a shared H10 plot frame. Consolidate Recording
settings, preserve configurable popup defaults and automatically register fields.
Make Analyze titles descriptive, remove redundant capture tiles, and move saved
participant corrections to Settings / Participants. Track screen options in
help/app-map.md and require updates in AGENTS. Retain raw capture/schema and
metadata revision guards. Include prior Recording setup/type/event-note fixes.

Validation: 35 changed Dart files formatted/parsed; six standalone storage checks
passed. Flutter analysis/widget tests/APK and hardware checks pending here;
installer runs Flutter verification on the home PC. No commit or push performed.
```

## 2026-10-10 — Home analyzer correction

```text
Fix Recording overlay initialization and analyzer issues

Initialize the optional overlay origin and pass the recording start from the
processing view. Fix all 24 home-reported analyzer issues: missing final-field
initialization, multiline guard braces, redundant null assertions and inherited
parameter naming. Preserve elapsed-time plotting and existing dependencies.

Validation: nine corrected Dart files formatted/parsed, six standalone storage
checks passed, and correction patch preflight/source comparison passed. Flutter
analysis, widget tests and debug APK remain pending on the home rerun.
```

## 2026-10-10 — Widget follow-up / ZIP picker

```text
Fix Recording preview/layout and add source package picker

Include pre-controller EEG preview frames in the plot range. Keep primary
capture controls fixed and secondary actions scrollable on compact screens.
Update widget interactions for Recording labels, shared plot inspection,
lazy settings/history construction, scroll layout and asynchronous loading.
Add a reusable ZIP picker and require manifests for subsequent packages.

Validation: home analyzer is clean; previous widget run had 177 passes and
9 failures. Source format/syntax, storage and patch checks passed here.
Flutter widget rerun and APK build remain pending on the home PC.
```

## Widget follow-up — 2026-10-10

```text
Release recording type write queue and fix lazy settings navigation

Release completed usage writes so History loads across widget-test clocks.
Scroll to the lazy advanced-tools row before opening Processing & plots.
Print the full compact layout overflow diagnostic without suppressing failure.

Home: analyzer clean, 182 passing / four failing before this correction.
Workspace: format, storage and patch checks; Flutter/APK rerun pending.
The compact layout overflow remains unresolved.
```

## Flutter regression prevention — 2026-10-10

Record recurring Flutter failures and show source package progress

Track required checks for queues, lazy lists, timer/I/O waits, UI labels and layout diagnostics. Print selected ZIP and installer identity. Workspace documentation/diff checked; home follow-up tests and APK pending.

## Overview overflow correction — 2026-10-10

```text
Fix Overview recording banner overflow and track Flutter regressions

Scroll the recording status banner with Overview content in all loading states.
Scope processing test gestures to the active route. Include the error ledger,
mandatory pre-build guidance, copyable commit requirement and picker progress.

Home before correction: clean analyzer, 186 passing / one failing test.
Workspace format, storage regression and patch checks passed.
Final Flutter suite and APK rerun pending on home PC.
```
