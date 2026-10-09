"""Validate source Apple configuration before spending time on Xcode compilation."""
from pathlib import Path
import plistlib

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'mobile' / 'desired_state_app'

def read(relative):
    with (APP / relative).open('rb') as handle:
        return plistlib.load(handle)

def main():
    ios = read('ios/Runner/Info.plist')
    assert ios.get('NSBluetoothAlwaysUsageDescription', '').strip(), 'Missing iOS Bluetooth rationale'
    assert 'bluetooth-central' in ios.get('UIBackgroundModes', []), 'Missing BLE central background mode'
    assert len(ios['UISupportedInterfaceOrientations~ipad']) == 4, 'iPad orientation support lost'
    mac = read('macos/Runner/Info.plist')
    assert mac.get('NSBluetoothAlwaysUsageDescription', '').strip(), 'Missing macOS Bluetooth rationale'
    for name in ['DebugProfile.entitlements', 'Release.entitlements']:
        entitlements = read('macos/Runner/' + name)
        for key in ['com.apple.security.app-sandbox', 'com.apple.security.device.bluetooth', 'com.apple.security.network.client', 'com.apple.security.files.user-selected.read-write']:
            assert entitlements.get(key) is True, f'Missing {key} in {name}'
    for platform in ['ios', 'macos']:
        project = (APP / platform / 'Runner.xcodeproj/project.pbxproj').read_text()
        assert 'FlutterGeneratedPluginSwiftPackage' in project, f'{platform} SPM integration missing'
    print('Apple plist, sandbox, iPad and existing SPM configuration checks passed.')

if __name__ == '__main__':
    main()
