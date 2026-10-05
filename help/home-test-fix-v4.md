# Home widget test update v4

Apply after the v3 patch. Changes only three widget test files.

- History waits for the current Processing & plots toolbar action. Its return-to-Live tap targets the recording banner.
- Home Live scrolls the lazy connect list to build Start before tapping it, checks that Start is hit-testable, and uses the current toolbar tooltip.
- Compact Live checks numeric RMSSD text and visibility using its FittedBox layout bounds. Text inside FittedBox retains unscaled paragraph bounds, which makes the old Text-centre hit test unsuitable.

Recording continuity, raw RR row counts, active History write guards, saved annotations, frozen plots, and reconnect segment checks remain. No production source, Android identity, signing configuration, or session files are changed.

Validation: reviewed changes against the uploaded source and v3 patch; verified baseline/payload hashes and ZIP contents. Flutter and Dart are unavailable in the patch workspace. Runtime checks remain pending on the home PC. The installer runs formatting, analysis, affected tests, complete suite, build, replacement install, and launch in order, stopping on failure. Source mismatches stop before copying files; changed files are backed up before applying.
