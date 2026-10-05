# Home test update v7

Apply after v6. Only compact_live_test.dart changes.

Fixes a test circular wait introduced in v6: SessionController recovery waits for its first measurement before marking connected. The test had waited for connected before emitting the measurement. It now waits for the fake service connect count to increase during recovery, asserts not yet connected and the same logger, emits the existing [1040, 1050] packet, then waits for connected and recovery completion. Maintains the segment-break and six saved RR row checks. Keeps the bounded route waits and post-scroll frame fixes.

Production controller behavior was inspected: _recover creates _firstData before polar.connect and waits for it; _onData marks connected and completes _firstData. No production changes.

Validation: package hash/ZIP integrity and packet-order assertions checked here. Flutter/Dart unavailable here; runtime checks pending on home PC. Installer backs up the test, runs analysis, affected tests, full suite and build before replacement installation. Android identity/signing and recordings are not modified by this patch.
