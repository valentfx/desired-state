# Desired State Windows review v0.3

Desktop entry point: `mobile/desired_state_app/lib/main_windows.dart`. The Android entry point and recording code remain the shared project's existing implementation.

## First run

Use the included installer from PowerShell. It backs up the app source, adds Windows files/dependencies, creates a Windows runner if absent, formats/analyzes the new source, runs desktop regression tests, builds a release app, then launches it. Flutter and Visual Studio's **Desktop development with C++** workload are required. Visual Studio Code alone does not provide the C++ toolchain.

## Review

Import one exported phone session ZIP. Originals are retained locally. Existing session IDs are not overwritten by ZIP imports. Select a session from the searchable left panel. Whole session shows BPM, raw RR, recorded-screened RMSSD, ring oxygen/pulse, and screened EEG band power. Each signal uses native units and labeled axis limits on both sides. Gaps and unusable EEG channels remain unavailable; unavailable Delta is not zero.

Select 10 seconds to inspect beats; 1/5/30 minutes for trends. Click or drag a plot to move the shared inspection cursor, then zoom around it. Mouse wheel zooms. The range slider navigates within the session. Raw ECG/EEG/motion is limited to 60 seconds per read. Event lines appear on all plots; click an event to review its surrounding interval. Session events open from the top list button at narrower widths. Save review writes a JSON record of the selected range, signals, provenance and warnings.

The first session index scans every stream in a worker isolate. Later range reads seek to minute offsets. Indexes currently rebuild when a session is reopened. Initial indexing of multi-hour sessions can take time. Display reduction retains local extrema/gaps, but cursor values on reduced views are displayed samples, not an exhaustive beat viewer. Single sample runs cannot form a line. Phone receipt timing reconstructs sample spacing within batches; this is not device-clock synchronization. RMSSD uses latest 60 acquired intervals, recorded acceptance flags and adjacent accepted pairs; continuity changes and receipt gaps reset it. It is provisional, not ECG-validated NN data or a clinical interpretation. This version has no sleep-stage or arrhythmia classifier.

## USB phone sync and master archive

Connect one Android phone by USB, unlock it and authorize USB debugging. Click **Sync phone**. The installed phone app must be the debug build (`com.example.desired_state_app`) because Android `run-as` cannot read release app storage. ADB is discovered under `%LOCALAPPDATA%\Android\Sdk\platform-tools` or PATH.

The sync reads every finalized session, copies all top-level JSON/JSONL logs, verifies SHA-256 checksums and source stability, and reports per-session results. Stable sessions without a completion event import as incomplete snapshots. This status does not prove recording has stopped; changing files are rejected. Unchanged content is not copied again. Changed sessions replace the current local snapshot only after validation; the previous snapshot is retained in `revisions`. Nothing is deleted or modified on the phone. A later sync updates incomplete snapshots and marks them complete when a completion event appears. The Last sync report button reopens the saved per-session report (`sync_report.json`). Unknown nested files are unsupported.

Local storage is under the Windows application documents directory:

- `desired_state_desktop/desired_state_sessions/<session_id>/`: original logs and annotations.
- `desired_state_desktop/catalog.json`: versioned master catalog, source identity, sync date and per-file SHA-256 manifest.
- `desired_state_desktop/revisions/`: earlier snapshots of changed sessions.

This is a file archive plus catalog, not yet a SQL database or server. Catalog manifests provide a stable basis for a later server upload protocol. No networking, account or automatic background sync is included yet. Back up the complete `desired_state_desktop` directory. ZIP imports are discovered in the same archive.

## Build and rerun

```powershell
cd C:\1dev\desired-state\mobile\desired_state_app
cls
flutter doctor -v
flutter test test/desktop_store_test.dart test/desktop_plot_test.dart test/desktop_sync_test.dart
flutter build windows --release --target lib/main_windows.dart
& .\build\windows\x64\runner\Release\desired_state_app.exe
```

For iterative development:

```powershell
cd C:\1dev\desired-state\mobile\desired_state_app
cls
flutter run -d windows --target lib/main_windows.dart
```

Keep the entire Release folder together when distributing the executable. Windows build/runtime validation and USB transfer testing require your PC and phone; the patch authoring environment has neither Flutter/Dart nor a Windows compiler.

## Shared cursor and session details

Click or drag any plot. The right panel shows cursor values for every recorded supported signal, including raw ECG/EEG/motion even if their plots are hidden. A short indexed range is read again to inspect original samples rather than the reduced overview. Updates are debounced during dragging; obsolete requests cannot replace the newest selection. Each available value shows its actual receipt-based sample time and signed offset. No interpolation is performed. Waveform matches require proximity within 50 ms; trend/band matches within 1.5 seconds. Missing streams say No data; nonfinite screened windows say Rejected / unavailable. These thresholds are display matching tolerances, not synchronization accuracy. An EEG outage cannot show a stale value hours later. Raw RR packets may contain multiple intervals at the same receipt time; the inspector shows the last interval at a tied timestamp, not an ECG-resolved beat.

Hover a session for its ID, participant, local date/start/end, completion status, event-derived duration, devices, recorded stream filenames and data size. Incomplete durations are lower bounds based on the last event; they do not prove ongoing acquisition. Selecting a session adds its indexed recorded span and readable row counts. At smaller widths, open the sidebar using the Session events button. Technical events are collapsed separately from user markers. The installer saves a transcript in its backup folder so a failed update can be diagnosed.

This combined package includes all v0.2 sync changes; installing v0.2 separately is unnecessary. Flutter/runtime tests for the new changes must run on Windows through the installer; v0.1 analysis and its eight tests previously passed on the user's PC.
