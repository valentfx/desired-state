# Home test correction — 2026-10-03

Based on desired-state-home-test-source.zip uploaded after Dart automatic lint fixes.

- Move EEG widget-test filesystem creation and teardown to runAsync. In particular, a zero-duration timer awaited under the fake test clock could leave teardown waiting forever.
- Wait for explicit loaded/saved UI conditions with a bounded real-time I/O loop rather than pumpAndSettle while a loading indicator is animating. Compact Live waits for its plot instead of waiting for Overview to settle.
- Update plot-tap fixture coordinates to the current 54-pixel axis margin and the current Analyze/participant-filter labels. Use the session-count label rather than assuming both rows of a lazy ListView are instantiated.
- Fix real participant refresh and post-save callbacks so setState returns synchronously rather than returning the profiles Future.
- Extend the participant widget test to cover refresh, rename persistence, and the unchanged permanent ID used by View sessions.

No tests are skipped and no acquisition, recording, analysis algorithms, Android configuration, signing keys, or stored sessions are replaced. The installer backs up six source files and verifies their baseline hashes before writing. It formats those files, analyzes, runs affected tests, runs the full suite with one worker and a per-test timeout, builds, upgrades, and launches. Failure prevents installation.

Local validation: source diff inspection, patch manifest hashes, original-source matching, plot-coordinate arithmetic, absence of the returning-Future callbacks, and ZIP integrity. Flutter/Dart SDKs are unavailable in the preparation environment; no Flutter analysis/test/build pass is claimed. The Windows checks are required to establish runtime validation.

Apply this patch after the complete-session-analysis update. Do not reapply the original cumulative ZIP afterward: it would restore the older files.
