# Flutter delivery checks and recurring failures

Use this before each Flutter change and source-package delivery. Keep it brief and update it when a failure is diagnosed.

| Failure | Required prevention/check |
| --- | --- |
| Final constructor field omitted | Review constructor/field wiring; run Flutter analyzer. Dart parsing does not establish semantic correctness. |
| Retained completed static Future across test clocks | Retain only pending write queues; release tails after success/error. Cross-zone regression in recording_types_test.dart. |
| Lazy list item absent (`No element`) | Scroll within the owning list to construct the row, then pump before tapping. `ensureVisible` requires an existing element. |
| Ambiguous gesture/text finder | Scope to the intended route/widget; keep assertions on behavior. |
| `pumpAndSettle` timeout with live timers/I/O | Wait for a specific usable state with real I/O; use bounded route-transition pumps. Do not increase arbitrary timeouts to mask failure. |
| Small-screen overflow | Capture original FlutterErrorDetails at occurrence, including widget and constraints; verify affected screens at 360×640 and keyboard insets. Do not guess at unrelated layout changes. |
| Renamed UI breaks navigation tests | Search affected labels/tooltips and update route-specific interactions together. |
| Previous ZIP selected again | Print selected ZIP and installer path. Check transcript package identity before attributing unchanged failures to the new patch. |
| Silent installer startup | Print picker, extraction, backup and verification progress before operations. |

Delivery order: inspect the exact installed baseline; reproduce/diagnose; fix; run affected tests; run full analyzer/tests; build APK once software checks pass. Preserve failure logs. When Flutter is unavailable in the workspace, label the package as requiring PC validation and report exactly which standalone checks ran. Never describe source parsing as Flutter verification. Do not bypass a failed test gate or upgrade the SDK/dependencies incidentally. Bundle related diagnosed corrections into one source update.

Current home result (2026-10-10): analyzer clean, 182 passing / four failing on desired-state-widget-fix. The subsequent desired-state-widget-followup releases the usage queue, corrects lazy advanced-tools navigation and prints full overflow details. Its home validation is pending. The 21:48 transcript invoked desired-state-widget-fix again, so it does not validate the follow-up.

## Error ledger — 2026-10-10

| Run/package | Observed error | Correction and current status |
| --- | --- | --- |
| Analyze update | `RelativeOverlayPlot.origin` final field uninitialized | Constructor accepts origin; caller/painter wiring added. Subsequent home analyzer clean. |
| Analyze update | 19 missing if-body braces, three ineffective null assertions, renamed override parameter | Analyzer correction delivered; home analyzer clean. |
| First widget run: 177 pass / nine fail | EEG physical axis maximum was 12, expected >16 | Preview origin includes pre-controller frames. Not reported failing in subsequent home run. |
| First widget run | HistoryPlot tap matched two GestureDetectors | Target InspectableSignalPlot; not reported failing subsequently. |
| First widget run | Gamma setting tap outside viewport; SDNN item absent | Pump completed scroll layout and construct lazy settings row. Not reported failing subsequently. |
| First widget run | Overview menu `pumpAndSettle` timed out | Wait for usable state and bound transition pumps. Not reported failing subsequently. |
| First widget run | AnalysisMode dropdown absent | Scroll within ProcessingEditor before tapping; next run progressed past this interaction. |
| First widget run | Waiting for obsolete `Session notes` tooltip | Updated to Recording notes; not reported failing subsequently. |
| Both subsequent widget-fix runs: 182 pass / four fail | History loading timed out in active-session and user/ID filter tests | Retained recording-type usage future reproduced a cross-zone timeout standalone. Pending-only queue correction passes that regression; home follow-up still pending. |
| Both subsequent widget-fix runs | Processing advanced-tools item absent at ensureVisible line 104 | Follow-up scrolls to construct ListTile before tapping; home verification pending. |
| All reported widget runs | Compact Live RenderFlex overflow by 116 pixels, detected at final takeException | Exact originating widget not present in logs. Follow-up prints original FlutterErrorDetails; Diagnosed in the follow-up: Overview fixed banner above Expanded content exceeds available height during a long connection status. Move banner into its scrolling content; home rerun pending. Earlier secondary-actions layout change did not resolve it. |
| Installer reports | No output before startup/backup; perceived hang | Later traces progressed through backup/analyzer/tests. Root cause of initial pause unconfirmed. Source picker and follow-up installer print progress. |
| Latest 21:48 transcript | Same four failures after selecting previous package | Trace invoked install_widget_fix.ps1, not install_widget_followup.ps1. Print selected ZIP and installer path; follow-up has not been validated by that run. |

Before every build: read this ledger, review applicable prevention checks above, and run analysis/affected tests before APK. After a failure, record exact package, error, source location, diagnosed cause, correction and evidence. Keep unresolved causes explicit. Distribute this file in source ZIPs with the matching AGENTS rule.

## Latest follow-up result

The original widget-followup package ran successfully through analyzer and produced 186 passing tests / one failing compact layout test. Both History tests and processing navigation now pass. The original overflow report points to Overview Column at overview_screen.dart:125 with a 360×540 available body. Banner belongs inside the list in ready/loading/error states, including while Overview is retained offscreen. Processing test warnings came from `.first` selecting the previous route's Scrollable; scope to the hit-testable ProcessingScreen. Keep failures/assertions enabled. Final rerun/APK pending.
