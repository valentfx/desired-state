import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// CoreBluetooth uses one authorization on iOS, not Android's scan/connect pair.
List<Permission> bluetoothPermissionsFor(TargetPlatform platform) {
  if (platform == TargetPlatform.iOS) {
    return [Permission.bluetooth];
  }
  if (platform == TargetPlatform.android) {
    return [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
    ];
  }
  // Desktop authorization is handled by the Bluetooth plugin and native OS.
  return [];
}

Future<bool> requestDeviceBluetoothPermissions({
  TargetPlatform? platform,
  Future<Map<Permission, PermissionStatus>> Function(List<Permission>)? request,
}) async {
  final target = platform ?? defaultTargetPlatform;
  final permissions = bluetoothPermissionsFor(target);
  if (permissions.isEmpty) {
    return true;
  }
  final results = request == null
      ? await permissions.request()
      : await request(permissions);
  if (target == TargetPlatform.iOS) {
    return results[Permission.bluetooth]?.isGranted ?? false;
  }
  // Notification denial must not prevent sensor acquisition on Android.
  return (results[Permission.bluetoothScan]?.isGranted ?? false) &&
      (results[Permission.bluetoothConnect]?.isGranted ?? false);
}
