# Home test update v5

Apply after v4. Changes only compact_live_test.dart.

The compact Live test now pumps a frame after scrolling to the plot and to Back to live, and asserts that each tap target is hit-testable. The v4 output showed the Back to live tap at y=22 hitting the outer app bar; ensureVisible had changed the scroll offset but layout had not been pumped. Retains plot freeze/resume assertions, same-logger reconnect, segment breaks and six raw RR rows.

Analysis and 17 affected tests passed on the home PC with v4. The remaining test failed at the stale tap. Package integrity and normalized baseline hashes checked here; Flutter/Dart unavailable here. Runtime validation pending. Installer backs up the changed test, then requires analysis, affected tests, full suite, build and replacement installation. Does not change production source or Android configuration.
