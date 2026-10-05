# Participant queue lifetime / active History setup — 2026-10-03

Apply after home-test-fix v1 and v2. The EEG overflow patch remains in place.

A static participant write Future was retained even while idle. Profiles reads in one widget-test fake clock can cause the next test's real asynchronous recording setup to wait on a Future associated with the previous clock. The store now represents idle as null, waits only for pending writes, and releases only the current tail after success or failure. Concurrent saves still serialize across store instances; caller errors are preserved and failed writes do not block later saves.

Added regression coverage for ordered writes from two stores, IDs/data retention, validation failure, and subsequent successful save. The existing participant refresh and rename tests remain. Active-History setup now reports each operation and bounds filesystem/marker/connect/start waits. Existing readonly/continuity/raw-row checks remain.

Only participant_tools.dart and two test files change. No Android, signing, recordings, sensor drivers, or analysis code changes. Installer checks source hashes, backs up originals, formats/analyzes, runs affected tests with History first, runs the full suite, builds, updates and launches. Every test remains enabled.

Local checks: source/diff review, queue-tail race and failure-path review, preserved regression assertions, source hashes and ZIP integrity. Flutter SDK is unavailable here, so no runtime pass is claimed. Windows analysis/tests/build remain mandatory. Prior v2 runtime output confirmed EEG and the first two History widget tests passed.
