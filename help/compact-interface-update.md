# Compact interface, device diagnostics and posture calibration

This update includes the pending H10/O2Ring connection fixes. Source changes are prepared; Flutter and Android verification must run on the home PC.

## Where things live

- Live: BPM/HRV overlay, optional compact EEG, oxygen/posture, markers and Pause/Stop. The tune icon opens Live settings. Full ECG, raw EEG and acceleration plots are removed from Live. BPM and RMSSD values preview before Record.
- Devices: select H10, O2Ring or Athena. Each detail page contains connection controls, acquired signal trends and Recording settings. H10 adds posture calibration. Athena retains the existing detailed EEG panel, including raw EEG, band/channel controls and baseline tools. O2Ring retains its protocol diagnostics.
- Analyze: use Signals on the current-recording banner, or All session signals in a saved session. Both open the same timeline viewer. Choose 30/60/300-second windows, browse time, follow incoming saved data, and optionally show raw waveforms/motion. Existing processing/review tools remain available.
- Settings: Live display choices, recording defaults, participants, practice and storage. Participants and Practice are removed from the main drawer.

## Calibrate H10 posture

Connect H10, open its detail page, then Posture calibration. Wear it in its normal orientation. Lie on your back, settle, and capture for four seconds. Repeat right and left sides; upright and prone are optional. At least three seconds of received samples must be still and gravity-like. Captures too similar to another position are rejected. Name and save the calibration. A saved calibration can be selected again on the same page.

Calibrations belong to the participant identity when selected, or to a local/unassigned profile. They are associated with the H10 identity and wearing orientation. Classification uses the nearest calibrated gravity direction, with angle/margin and movement checks; unknown/moving remain valid outputs. This is a provisional posture classifier, not a validated clinical device.

A session retains its initial calibration in posture_calibration.json and logs subsequent calibration changes with full snapshots. Raw acceleration remains unchanged. Recalibrate after changing strap orientation. A stale/disconnected sensor does not show a current known posture.

## Display versus recording

Hiding a signal never turns off acquisition or saving. Device Recording settings select saved stream groups: heart rate/RR, ECG, acceleration/posture, ring oxygen/pulse, Athena EEG/bands/head motion, and raw H10 protocol packets. These are recording selections, not radio/acquisition power controls. All default to enabled. Mid-session changes are timestamped and create a continuity break. Existing files are not rewritten to remove earlier data.

## Long-session behavior and limits

Diagnostic previews are bounded. The common timeline viewer streams complete JSONL lines, retains partial final lines for the next read, uses file offsets while following an active recording, and caps display points with local-extrema reduction. Native file parsing is done in a worker isolate to avoid blocking acquisition/UI callbacks. Browsing a new historical interval scans source files, so an overnight file can take time to load. This is bounded-memory reading, not yet a persistent random-access index. Acquisition remains owned by SessionController.

Waveform alignment in the common viewer is based on phone receipt time and sample-rate reconstruction. Original device timestamps and provenance remain in the raw files; cross-device phase timing is approximate. Its RMSSD trace is a separately derived 60-interval estimate using recorded flags and continuity segments. EEG trends require all captured channels to pass screening; missing quality produces gaps. Bands are not sleep stages or a validated relaxation score.

## Validation and overnight check

Package checks: source delimiter/import checks, expected data keys, payload/baseline hashes, and ZIP integrity. Runtime analysis, tests and APK build are pending until the installer completes. New tests cover calibration capture/classification, preference persistence/corruption, configuration events, pre-record preview, calibration snapshots, incremental reads and compact Live. Existing device/recording/navigation tests are retained and adjusted for device detail navigation.

Before an overnight run: connect all sensors, capture posture references, confirm the intended recording groups, make a short combined recording, export it, then check screen-off acquisition/reconnect and free storage. Success requires hardware evidence; package validation alone is not proof of overnight stability.

## Revision 2

Corrects explicit statement braces, removes the unused Live status helper, and guards the O2Ring reconnect snackbar with the owning State mounted check. Accepts the already applied/formatted first package. Runtime analysis and tests must still complete on the home PC.

## Revision 3

Home verification of revision 2: analyzer passed; 37 affected tests passed and 3 failed. This revision adjusts navigation tests to finish route animations and tap only a visible Back button, and replaces a removed Live status-text expectation with recording controls/state. Recording, reconnect identity and raw-row checks remain in place. No application-source behavior changes from revision 2. Full suite, APK build and hardware validation remain pending.

## Revision 4

Home verification of revision 3: analyzer passed, 39 affected tests passed, one outdated REC label assertion failed. Corrects the assertion to the current label and verifies the same session logger, recording state and three RR samples after recreating Live. Application source remains unchanged. Full suite/build/hardware checks remain pending.

## Revision 5

Home verification of revision 4: analyzer and all 40 affected tests passed; full suite had 109 passes and one obsolete startup navigation expectation. Updates that test to select both device details and verify their visible scan controls. Application source remains unchanged. Full suite/build/hardware checks remain pending.
