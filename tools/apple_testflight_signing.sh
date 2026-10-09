#!/usr/bin/env bash
# Run only on an ephemeral macOS runner; credentials arrive through environment.
set -euo pipefail
: "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}" "${APPLE_TEAM_ID:?}" "${APPLE_BUNDLE_ID:?}"
: "${APPLE_CERTIFICATE_P12_BASE64:?}" "${APPLE_CERTIFICATE_PASSWORD:?}"
: "${APPLE_PROVISIONING_PROFILE_BASE64:?}" "${ASC_PRIVATE_KEY_BASE64:?}"
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"
umask 077
export KEYCHAIN_PATH="$RUNNER_TEMP/desired-state-signing.keychain-db"
export SIGNING_DIR="$RUNNER_TEMP/desired-state-signing"
mkdir -p "$SIGNING_DIR/private_keys"
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['SIGNING_DIR'])
for variable, filename in [('APPLE_CERTIFICATE_P12_BASE64', 'distribution.p12'), ('APPLE_PROVISIONING_PROFILE_BASE64', 'app.mobileprovision'), ('ASC_PRIVATE_KEY_BASE64', f"private_keys/AuthKey_{os.environ['ASC_KEY_ID']}.p8")]:
    (root / filename).write_bytes(base64.b64decode(os.environ[variable], validate=True))
PY
KEYCHAIN_PASSWORD=$(openssl rand -hex 32)
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$SIGNING_DIR/distribution.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH" >/dev/null
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db"
security cms -D -i "$SIGNING_DIR/app.mobileprovision" > "$SIGNING_DIR/profile.plist"
python3 - <<'PY'
import datetime, os, plistlib, re, shutil
from pathlib import Path
root = Path(os.environ['SIGNING_DIR'])
profile = plistlib.loads((root / 'profile.plist').read_bytes())
team = os.environ['APPLE_TEAM_ID']; bundle = os.environ['APPLE_BUNDLE_ID']
assert re.fullmatch(r'[A-Z0-9]{10}', team), 'Invalid Apple Team ID'
assert re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle), 'Invalid bundle ID'
assert team in profile['TeamIdentifier'], 'Profile belongs to another Apple team'
identifier = profile['Entitlements']['application-identifier']
assert identifier.partition('.')[2] == bundle, 'Profile does not match the bundle ID'
assert profile['Entitlements'].get('get-task-allow') is False, 'Use an App Store distribution profile'
assert not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'), 'Use an App Store profile, not ad hoc/enterprise'
assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Profile expired'
uuid = profile['UUID']; name = profile['Name']
assert re.fullmatch(r'[A-Za-z0-9-]+', uuid) and '\n' not in name and '\r' not in name
for relative in ['Library/MobileDevice/Provisioning Profiles', 'Library/Developer/Xcode/UserData/Provisioning Profiles']:
    folder = Path.home() / relative; folder.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / 'app.mobileprovision', folder / (uuid + '.mobileprovision'))
options = {'method': 'app-store-connect', 'signingStyle': 'manual', 'teamID': team, 'provisioningProfiles': {bundle: uuid}, 'uploadSymbols': True, 'manageAppVersionAndBuildNumber': False}
(root / 'ExportOptions.plist').write_bytes(plistlib.dumps(options))
with open(os.environ['GITHUB_ENV'], 'a') as handle:
    handle.write(f'PROFILE_NAME={name}\nPROFILE_UUID={uuid}\nKEYCHAIN_PATH={os.environ["KEYCHAIN_PATH"]}\nSIGNING_DIR={root}\nAPI_PRIVATE_KEYS_DIR={root / "private_keys"}\n')
print('App Store provisioning profile validated; signing material installed on ephemeral runner.')
PY
