# Home test update v6

Apply after v5. Only compact_live_test.dart changes. Replaces global pumpAndSettle waits on device navigation, reconnect and returning to Live with bounded settleIo predicates. These wait for the visible Devices route, connected/nonbusy controller, and the returned Live plot plus hit-testable Stop control. The wait pumps frames and yields real time for disk I/O. Existing plot freeze/resume, same logger, reconnect segment and six saved RR row checks remain.

Home v5 evidence: analysis clean and 17 affected tests pass; compact Live progresses through plot resume and reconnect, then pumpAndSettle times out after pageBack (line 278). No build or installation ran. Package checks here pass; Flutter/Dart runtime unavailable here. Installer backs up the file and requires affected tests, full suite and build before installation. Production source, app identity and signing remain unchanged.
