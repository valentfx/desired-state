import 'dart:async';

import 'package:desired_state_app/polar_h10_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

class TestCharacteristic extends BluetoothCharacteristic {
  TestCharacteristic()
    : super(
        remoteId: const DeviceIdentifier('test'),
        serviceUuid: Guid('180d'),
        characteristicUuid: Guid('2a37'),
      );
  final values = StreamController<List<int>>.broadcast(sync: true);
  @override
  Stream<List<int>> get onValueReceived => values.stream;
  @override
  Future<bool> setNotifyValue(
    bool notify, {
    int timeout = 15,
    bool forceIndications = false,
  }) async => true;
}

class TestService implements BluetoothService {
  TestService(this.characteristic);
  final TestCharacteristic characteristic;
  @override
  Guid get uuid => Guid('180d');
  @override
  List<BluetoothCharacteristic> get characteristics => [characteristic];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestDevice extends BluetoothDevice {
  TestDevice() : super(remoteId: const DeviceIdentifier('test'));
  final states = StreamController<BluetoothConnectionState>.broadcast(
    sync: true,
  );
  final characteristic = TestCharacteristic();
  Completer<void>? pending;
  int disconnectCount = 0;
  bool enteredConnect = false;
  @override
  Stream<BluetoothConnectionState> get connectionState => states.stream;
  @override
  Future<void> connect({
    required License license,
    Duration timeout = const Duration(seconds: 35),
    int? mtu = 512,
    bool autoConnect = false,
  }) async {
    enteredConnect = true;
    await pending?.future;
  }

  @override
  Future<void> disconnect({
    int timeout = 35,
    bool queue = true,
    int androidDelay = 2000,
  }) async {
    disconnectCount++;
  }

  @override
  Future<List<BluetoothService>> discoverServices({
    bool subscribeToServicesChanged = true,
    int timeout = 15,
  }) async => [TestService(characteristic)];
  Future<void> close() async {
    await states.close();
    await characteristic.values.close();
  }
}

void main() {
  test(
    'reconnect cancels old listeners without deduplicating valid equal packets',
    () async {
      final polar = PolarH10Service();
      final old = TestDevice();
      final fresh = TestDevice();
      final received = <PolarHeartRateData>[];
      final subscription = polar.dataStream.listen(received.add);
      await polar.connect(old);
      old.characteristic.values.add([0x10, 60, 0, 4]);
      await polar.connect(fresh);
      expect(old.characteristic.values.hasListener, isFalse);
      expect(old.states.hasListener, isFalse);
      old.characteristic.values.add([0x10, 60, 0, 4]);
      fresh.characteristic.values.add([0x10, 60, 0, 4]);
      fresh.characteristic.values.add([0x10, 60, 0, 4]);
      expect(received.length, 3);
      expect(received.every((p) => p.rrIntervalsMs.single == 1000), isTrue);
      fresh.states.add(BluetoothConnectionState.disconnected);
      fresh.characteristic.values.add([0x10, 60, 0, 4]);
      expect(received.length, 3);
      await polar.dispose();
      await subscription.cancel();
      await old.close();
      await fresh.close();
    },
  );

  test(
    'disconnect invalidates pending connect before notification subscription',
    () async {
      final polar = PolarH10Service();
      final device = TestDevice()..pending = Completer<void>();
      final connecting = polar.connect(device);
      final assertion = expectLater(connecting, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(device.enteredConnect, isTrue);
      final disconnecting = polar.disconnect();
      device.pending!.complete();
      await assertion;
      await disconnecting;
      expect(device.characteristic.values.hasListener, isFalse);
      expect(device.states.hasListener, isFalse);
      expect(polar.device, isNull);
      expect(device.disconnectCount, greaterThan(0));
      await polar.dispose();
      await device.close();
    },
  );
}
