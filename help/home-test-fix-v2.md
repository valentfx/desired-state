# Narrow EEG layout and active History test — 2026-10-03

Apply after desired-state-home-test-fix.zip. This patch contains two files only.

The EEG channel dropdown expands within the available width and ellipsizes its selected/menu labels. This addresses the 71-pixel horizontal RenderFlex overflow exposed by the existing 360-pixel phone widget test, without removing channel choices or signal controls.

The active History widget regression waits for loaded Live, Advanced tools, the session list, the active snapshot, and return to Live. It retains the disabled edit/export assertions, logger identity/recording continuity checks, and four saved RR rows. Stage messages identify further stalls. It avoids global animation settling during loading/live updates. No test is skipped.

Installer: format, analyze, affected widget tests (EEG/History first), full suite, build, upgrade-install, launch. Per-test timeout is 60 seconds and I/O waits remain bounded. Original application ID, signing, native files, acquisition algorithms, and recordings are not changed. Source backups are made before replacing the two files. Baseline hashes tolerate formatter whitespace/trailing-comma changes after v1.

Validated here: source changes and retained regression assertions, baseline/patch hashes, ZIP integrity. Flutter/Dart are not installed in this environment; runtime test/build results must come from the Windows run. The first patch's runtime report showed clean analysis, all six participant tests, and the first two History tests passing. This patch still requires validation.
