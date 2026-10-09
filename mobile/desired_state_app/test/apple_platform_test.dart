import 'package:desired_state_app/bluetooth_permissions.dart';
import 'package:desired_state_app/recording_foreground_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'iOS requests its Bluetooth authorization and respects denial',
    () async {
      for (final status in [
        PermissionStatus.granted,
        PermissionStatus.denied,
      ]) {
        final allowed = await requestDeviceBluetoothPermissions(
          platform: TargetPlatform.iOS,
          request: (permissions) async {
            expect(permissions, [Permission.bluetooth]);
            return {Permission.bluetooth: status};
          },
        );
        expect(allowed, status == PermissionStatus.granted);
      }
    },
  );

  test('Android notification denial does not block Bluetooth', () async {
    final allowed = await requestDeviceBluetoothPermissions(
      platform: TargetPlatform.android,
      request: (permissions) async {
        expect(
          permissions,
          containsAll([
            Permission.bluetoothScan,
            Permission.bluetoothConnect,
            Permission.notification,
          ]),
        );
        return {
          Permission.bluetoothScan: PermissionStatus.granted,
          Permission.bluetoothConnect: PermissionStatus.granted,
          Permission.notification: PermissionStatus.denied,
        };
      },
    );
    expect(allowed, isTrue);
  });

  test('Android scan or connect denial blocks acquisition', () async {
    for (final denied in [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ]) {
      expect(
        await requestDeviceBluetoothPermissions(
          platform: TargetPlatform.android,
          request: (_) async => {
            Permission.bluetoothScan: PermissionStatus.granted,
            Permission.bluetoothConnect: PermissionStatus.granted,
            denied: PermissionStatus.denied,
          },
        ),
        isFalse,
      );
    }
  });

  test('macOS leaves native authorization to the Bluetooth plugin', () async {
    expect(
      await requestDeviceBluetoothPermissions(
        platform: TargetPlatform.macOS,
        request: (_) async => throw StateError('No macOS permission handler'),
      ),
      isTrue,
    );
  });

  const channel = MethodChannel('desired_state/recording_service');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    test(
      '$platform recording lifecycle does not call Android service',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          throw MissingPluginException('Android-only channel');
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final service = RecordingForegroundService();
        await service.start('apple-session');
        await service.update(
          state: 'Recording',
          heartRate: 65,
          rmssd: 30,
          artifactCount: 0,
          elapsed: const Duration(seconds: 5),
        );
        await service.stop();
        expect(calls, isEmpty);
      },
    );
  }

  test('Android recording lifecycle retains native calls', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = RecordingForegroundService();
    await service.start('android-session');
    await service.update(
      state: 'Recording',
      heartRate: null,
      rmssd: null,
      artifactCount: 0,
      elapsed: Duration.zero,
    );
    await service.timerAlert(vibrate: false);
    await service.stop();
    expect(calls, ['start', 'update', 'timerAlert', 'stop']);
  });
}
