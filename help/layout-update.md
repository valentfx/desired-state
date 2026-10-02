# Layout stage 1 — install and review

Apply desired-state-layout-stage1.zip from Downloads with its tools/install_and_run_layout_update.ps1, passing PackageRoot and RepositoryRoot. Work checkout: F:\1dev\desired-state; home: C:\1dev\desired-state. No dependency or Android identity/signing change. The installer backs up overwritten source outside the checkout. It requires the existing H10 ACC baseline and copies only paths in layout-update-files.txt.

The runner resolves Flutter from PATH or the existing F:/C:/1dev/flutter SDK, applies the source update, resolves dependencies, checks formatting without rewriting, analyzes, tests, builds debug APK, upgrade-installs to R5CX152HPPN, then starts Flutter. Every native exit code is checked. If installation reports signatures do not match, stop; do not uninstall or clear app storage. The original app and work-test app retain separate recording stores.

Phone review:
1. Overview opens. Select your recorded participant name. Selection survives restart. Only that participant's single-owner sessions appear; counts are recording activity, not physiological improvement.
2. Analyze contains every recording, including unassigned/mixed-user entries. Open older H10/O2 sessions and verify raw/filtered plots, notes and export.
3. Connect devices in Live, start explicitly, then navigate to Overview and Analyze. Return via the recording banner; same session, increasing sample counts, same participant and markers.
4. Advanced tools exposes XYZ/sample totals, ring pulse/battery/totals, processing and diagnostics. Check fresh/no-fresh-data states independently of connection state.
5. Long-press Mark Event: the optional note dialog sits near the top. Save/Cancel remains accessible with the keyboard and Android navigation bars.
6. Test normal and larger text sizes. The Screens menu remains visible above Devices/diagnostics/detail routes. Verify Overview participant selection and a Live participant draft survive menu navigation and resize; test Android Back.
7. Swipe the plot horizontally to browse earlier/later data. Try zoom buttons, full-session range slider and All. Scroll Live vertically to see every selected metric summary; XYZ remains directly on Live. Windows device recording support remains pending independent validation.

Scope: Overview / Live / Analyze only. Stable profiles, audited reassignment, actual personal trend metrics, Practice/goals and deeper Windows analysis are next work, not implemented placeholders.
