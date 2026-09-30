import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class PolarHeartRateData {
  final int heartRate;
  final List<double> rrIntervalsMs;
  final DateTime timestamp;

  const PolarHeartRateData({
    required this.heartRate,
    required this.rrIntervalsMs,
    required this.timestamp,
  });
}

class PolarH10Service {
  static final Guid _heartRateService = Guid(
    '0000180d-0000-1000-8000-00805f9b34fb',
  );

  static final Guid _heartRateMeasurement = Guid(
    '00002a37-0000-1000-8000-00805f9b34fb',
  );

  BluetoothDevice? _device;
  StreamSubscription<List<int>>? _measurementSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  final _connectionController = StreamController<bool>.broadcast(sync: true);
  Future<void> _operations = Future.value();
  int _generation = 0;

  final _dataController = StreamController<PolarHeartRateData>.broadcast(
    sync: true,
  );

  Stream<PolarHeartRateData> get dataStream => _dataController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;

  BluetoothDevice? get device => _device;

  Future<List<ScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final results = <ScanResult>[];

    await FlutterBluePlus.stopScan();

    final subscription = FlutterBluePlus.scanResults.listen((scanResults) {
      results
        ..clear()
        ..addAll(
          scanResults.where((result) {
            final name = result.device.platformName.toUpperCase();

            return name.contains('POLAR') ||
                result.advertisementData.serviceUuids.contains(
                  _heartRateService,
                );
          }),
        );
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: timeout,
        withServices: [_heartRateService],
      );
      await FlutterBluePlus.isScanning
          .where((scanning) => scanning == false)
          .first;
    } finally {
      await subscription.cancel();
    }

    return results;
  }

  Future<void> connect(BluetoothDevice device) {
    final generation = ++_generation;
    return _serialize(() => _connect(device, generation));
  }

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _operations.then((_) => action());
    _operations = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _connect(BluetoothDevice device, int generation) async {
    await _disconnect();
    if (generation != _generation) throw StateError('Connection cancelled');
    _device = device;
    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );

      if (generation != _generation) throw StateError('Connection cancelled');
      _connectionSubscription = device.connectionState.listen((state) {
        if (generation != _generation) return;
        if (state == BluetoothConnectionState.disconnected) {
          // Invalidate packet callbacks immediately, before asynchronous cleanup.
          _connectionLost(generation);
        }
      });

      final services = await device.discoverServices();
      if (generation != _generation) throw StateError('Connection cancelled');

      BluetoothCharacteristic? measurement;

      for (final service in services) {
        if (service.uuid == _heartRateService) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid == _heartRateMeasurement) {
              measurement = characteristic;
              break;
            }
          }
        }
      }

      if (measurement == null) {
        throw StateError('Heart Rate Measurement characteristic not found.');
      }

      _measurementSubscription = measurement.onValueReceived.listen(
        (value) {
          if (generation == _generation) _parseMeasurement(value);
        },
        onError: (Object _) => _connectionLost(generation),
        onDone: () => _connectionLost(generation),
      );
      await measurement.setNotifyValue(true);
      if (generation != _generation) throw StateError('Connection cancelled');
    } catch (_) {
      await _disconnect();
      rethrow;
    } finally {
      if (generation != _generation) await _disconnect();
    }
  }

  void _connectionLost(int generation) {
    if (generation != _generation) return;
    _generation++;
    _connectionController.add(false);
  }

  void _parseMeasurement(List<int> value) {
    if (value.length < 2) {
      return;
    }

    final flags = value[0];

    final heartRateIs16Bit = (flags & 0x01) != 0;
    final rrPresent = (flags & 0x10) != 0;

    var index = 1;

    late final int heartRate;

    if (heartRateIs16Bit) {
      if (value.length < index + 2) {
        return;
      }

      heartRate = value[index] | (value[index + 1] << 8);

      index += 2;
    } else {
      heartRate = value[index];
      index += 1;
    }

    // Energy Expended field is present when flag bit 3 is set.
    final energyPresent = (flags & 0x08) != 0;

    if (energyPresent) {
      index += 2;
    }

    final rrIntervals = <double>[];

    if (rrPresent) {
      while (index + 1 < value.length) {
        final rr1024 = value[index] | (value[index + 1] << 8);

        final rrMs = rr1024 * 1000.0 / 1024.0;

        rrIntervals.add(rrMs);

        index += 2;
      }
    }

    _dataController.add(
      PolarHeartRateData(
        heartRate: heartRate,
        rrIntervalsMs: rrIntervals,
        timestamp: DateTime.now(),
      ),
    );
  }

  Future<void> disconnect() {
    _generation++;
    return _serialize(_disconnect);
  }

  Future<void> _disconnect() async {
    await _measurementSubscription?.cancel();
    _measurementSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;

    if (_device != null) {
      try {
        await _device!.disconnect();
      } catch (_) {
        // Ignore disconnect errors during cleanup.
      }
    }

    _device = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _dataController.close();
    await _connectionController.close();
  }
}
