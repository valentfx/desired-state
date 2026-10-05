# H10 calibration persistence

Saved calibrations were on disk but participant-owned references were hidden when the participant identity was unset after a restart. The capture fields also reopened empty, even with an active saved calibration.

After reconnecting the same H10, the last-used calibration for that strap now restores for preview before Record. Once Record resolves a named participant, that participant’s calibration is preferred, then a local calibration; a different participant’s reference is not automatically applied. Reopening Posture calibration shows the active name and saved captures. Selecting Use refreshes the capture fields. Loading no longer rewrites calibration storage or reorders saved selections.

This package includes the previous Live plot update. Existing calibration files and session data remain in place. Recalibrate only if the strap placement changes or the reference was incorrect.

Verification on phone: connect the H10, select a saved calibration, close the app, reopen and reconnect the same H10, inspect the restored name/captures, then start a session with the intended participant. Unknown while moving or before fresh acceleration is expected; it does not indicate a missing reference.

Source structure/import/payload and ZIP checks completed here. Flutter analysis, new restart/UI regression tests, the full suite and APK build are executed by the installer before installation. Hardware verification remains pending.

Revision 2: home analysis passed; 44 affected tests passed, including calibration restart and saved-capture UI checks. One EEG widget fixture retained its controller timer until after Flutter invariant checking. Dispose now runs in a finally block before the widget test returns. Application source unchanged.
