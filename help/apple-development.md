# Desired State on Apple — first build and TestFlight

Status: Apple bootstrap source prepared on 2026-10-09 against GitHub main `05d61b1`. Native plist/sandbox checks, workflow parsing and shell syntax are verified here. Dart formatting, Flutter analysis/tests, Xcode compilation, signing/upload and sensor hardware checks are **pending**, not passed. No Mac purchase is required to try the prepared GitHub-hosted macOS workflow.

## What this update changes

- iPhone/iPad use `Permission.bluetooth` instead of Android scan/connect permissions. The existing iOS 15+ target supports both device families.
- iOS declares a Bluetooth rationale and `bluetooth-central` background capability. The project already uses Swift Package Manager; its permission plugin reads Info.plist. No unrelated Podfile, dependency upgrade or generated plugin edits are added.
- Mac declares Bluetooth authorization plus sandbox Bluetooth, outbound network and user-selected-file access.
- Start/update/stop call the Android foreground service only on Android. On Apple, the existing app-owned logger can start without a missing-channel exception; timer alerts use Flutter system sound and optional iOS vibration while the app is executing.
- Seven regression tests cover permission denial, optional Android notification permission and Android/Apple service routing. They must run in CI before builds.

The first hardware scope is H10 HR/RR/ACC/ECG and O2Ring using the shared BLE services. Those protocols are not yet hardware-validated on Apple. Muse Athena remains Android-only; its BrainFlow bridge must be ported separately. Apple background declaration does not guarantee continuous Dart timers, O2Ring polling, overnight reliability, lock-screen alerts or survival after force quit. Test those explicitly before overnight use. Mac sleep also interrupts acquisition.

## 1. Compile using GitHub's Mac, from a Windows PC

Apply the supplied Git patch to your current checkout using `git apply --check` before `git apply`. This merges scoped hunks rather than overwriting complete Dart files; it stops if your current source conflicts. Keep your local EEG updates. If a check fails, send the error/current source for reconciliation instead of forcing application.

The work-PC example is:

```powershell
cd F:\1dev\desired-state
cls
git apply --check "$env:USERPROFILE\Downloads\desired-state-apple-bootstrap.patch"
git apply "$env:USERPROFILE\Downloads\desired-state-apple-bootstrap.patch"
git diff --check
git status --short
```

At home, use `cd C:\1dev\desired-state` instead. Review the diff before committing. `help/git-updates.md` provides the commit title/body. Stage only this patch's files plus any separately reviewed local work; do not use a blanket `git add .` that includes recordings or credentials.

After the reviewed branch is pushed, open repository **Actions → Apple build check → Run workflow**, select the pushed branch and **ios** first. Choose **both** later to compile the Mac target too. Workflow code must be present on the repository's default branch for the manual action to first appear in GitHub's UI.

The workflow pins Flutter 3.47.5, enforces the existing dependency lock, formats touched sources, checks native configuration, runs analysis/full tests, then compiles. It uses standard `macos-15` runners. Standard public-repository runners are free; private-repository use consumes plan allowance and can incur charges. This repository was readable without credentials, but verify your repository visibility/billing before running.

The iOS artifact is unsigned and **cannot be installed on an iPhone/iPad or sent to TestFlight**. The Mac artifact is a development build, not a notarized distribution. These workflows do not claim hardware validation. A failed check/build must be repaired before the next stage.

## 2. Prepare Apple signing from Windows

Your membership must show active. Record the **Team ID** from Apple Developer → Membership details. Choose a permanent, unique bundle ID, such as `com.yourcompany.desiredstate` (replace the placeholder). Do not register `com.example.desiredStateApp` as your production identity. The signing workflow uses your chosen ID at archive time, without changing Android identity.

1. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/), register an explicit App ID for that bundle ID.
2. Create an **Apple Distribution** certificate. The Windows helper generates the private key and CSR locally using OpenSSL (normally bundled with Git for Windows):

```powershell
cd F:\1dev\desired-state
cls
.\tools\apple_signing_windows.ps1 -Action CreateCsr
```

Upload only the generated CSR to Apple's certificate form. Download Apple's `.cer`, then export its matching private key and certificate as a password-protected P12:

```powershell
cd F:\1dev\desired-state
cls
.\tools\apple_signing_windows.ps1 -Action ExportP12 -CertificatePath "$env:USERPROFILE\Downloads\distribution.cer"
```

The helper prompts for the P12 password. It preserves existing keys/P12 files. Signing files stay outside the repository in `%LOCALAPPDATA%\DesiredStateAppleSigning`. Retain the private key securely; do not send it in chat or commit it.

3. In Apple's Profiles section, create an **App Store Connect distribution** profile for the registered App ID and that distribution certificate. Download its `.mobileprovision` file. Do not use development, ad hoc or enterprise profiles for this workflow.
4. In [App Store Connect](https://appstoreconnect.apple.com/), create the Desired State app record using the exact bundle ID. Create a **team API key** under Users and Access → Integrations → App Store Connect API, with sufficient upload rights (App Manager is suitable). Download its `.p8` once and retain its Key ID and Issuer ID. Request API access there if the section is not available yet.

## 3. Add GitHub secrets, then upload to TestFlight

Repository **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 of the matching distribution P12 |
| `APPLE_CERTIFICATE_PASSWORD` | P12 export password |
| `APPLE_PROVISIONING_PROFILE_BASE64` | Base64 of the App Store distribution profile |
| `ASC_PRIVATE_KEY_BASE64` | Base64 of the App Store Connect API `.p8` |
| `ASC_KEY_ID` | API key's Key ID |
| `ASC_ISSUER_ID` | Team API key's Issuer ID |

To copy a file's Base64 into the clipboard without printing it in the terminal, use this pattern; substitute the profile/P8 path for those secrets:

```powershell
cd F:\1dev\desired-state
cls
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:LOCALAPPDATA\DesiredStateAppleSigning\distribution.p12")) | Set-Clipboard
```

After **Apple build check** passes, run **Apple TestFlight upload** manually with the Team ID and registered bundle ID. It reruns analysis/tests, installs credentials in a temporary keychain, checks the profile's team/bundle/expiration/distribution type, archives and exports using manual signing, validates the IPA, then uploads to App Store Connect. It cleans up signing files and does not publish an App Store release. Build numbers use workflow run number plus attempt; keep them above any build number already uploaded for that marketing version.

After Apple processes the upload, complete any export-compliance questions truthfully, configure the TestFlight group, supply beta details and submit external testing for beta review. Testers install TestFlight and accept your invitation. They do not need paid membership, Xcode or Developer Mode. Builds expire after 90 days. TestFlight upload alone does not enroll testers or bypass review.

Mac distribution is a later gate: verify the Mac app locally, choose Mac App Store or Developer ID/notarization distribution, and provision/sign that target separately. The initial signed workflow covers iPhone/iPad, not Mac distribution.

## Acceptance checklist

On a physical iPhone and iPad: allow/deny Bluetooth; connect H10/ring individually and together; verify live values and saved raw counts; test recording start/pause/resume/stop and navigation; reconnect after range loss; export/share a stopped session; verify participant/settings persistence; then lock-screen/background timing and longer recording continuity. Saved-session analysis can be tested before sensors. Simulators compile/UI-test but do not replace physical BLE tests. No existing Android/Windows recordings are rewritten by this port.

References: [Flutter iOS release](https://docs.flutter.dev/deployment/ios), [Flutter macOS release](https://docs.flutter.dev/deployment/macos), [permission_handler 12.0.3](https://pub.dev/packages/permission_handler/versions/12.0.3), [Apple Bluetooth background behavior](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html), [GitHub hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
