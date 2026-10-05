# H10 and O2Ring alongside Athena

## Behavior

Devices retains scan controls for the first H10 and O2Ring during an existing session, including an Athena-only recording. Adding either registers its identity and original participant assignment in the manifest and appends a device_attached event. The original primary device/session ID and existing raw rows are preserved. H10 measurements carry the H10 ID; O2Ring measurements carry the ring ID. Existing sensors cannot be replaced during recording; reconnect the assigned sensor or stop first.

H10 displays connection/scan/error state and last heart-rate receipt. Reconnect H10 is available only for an actual selected strap. O2Ring retains its diagnostics and gains a reconnect action, oxygen and pulse feedback. Scan/select H10; scan/select O2Ring to open its connection diagnostics. Streams remain controller-owned across screen navigation.

## Validation

Adds tests for both sensors joining an Athena session, primary identity preservation, saved RR/ring rows, replacement guards, failed H10 retry, visible active-session scan controls and absent no-op reconnect. Package hashes, archive integrity and source ordering checks passed in the patch workspace. Flutter/Dart/Android are unavailable there, so runtime verification is pending on the home PC. The installer requires analysis, targeted tests, full suite and APK build before replacing the app. Hardware verification requires actual H10/Ring measurements and an exported combined recording.

## Apply

Apply after test fix v7. Installer checks unchanged baseline/payload hashes and the home application ID, backs up changed files, and retains Android signing configuration. Does not change permissions, BLE protocols or dependencies. This fixes access/identity/feedback; a hardware or BLE protocol failure will still appear as connection status and must be diagnosed from the device diagnostics.
