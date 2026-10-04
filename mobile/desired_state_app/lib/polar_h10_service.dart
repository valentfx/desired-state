import 'dart:async';

import 'h10_accelerometer.dart';
import 'h10_ecg.dart';
import 'device_models.dart';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/foundation.dart';

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

  static final Guid _pmdControl = Guid('fb005c81-02e7-f387-1cad-8acd2d8df0c8');
  static final Guid _pmdData = Guid('fb005c82-02e7-f387-1cad-8acd2d8df0c8');
  final _accController = StreamController<H10Acceleration>.broadcast(
    sync: true,
  );
  final _pmdPackets = StreamController<RawBlePacket>.broadcast(sync: true);
  final _accStatus = StreamController<String>.broadcast(sync: true);
  Stream<H10Acceleration> get accelerationStream => _accController.stream;
  Stream<RawBlePacket> get pmdPackets => _pmdPackets.stream;
  Stream<String> get accelerationStatusStream => _accStatus.stream;
  String accelerationStatus = 'Not connected';
  StreamSubscription<List<int>>? _controlSubscription, _accSubscription;
  Completer<List<int>>? _response;
  final List<int> _responseBytes = [];
  int? _opcode, _measurementType;
  BluetoothCharacteristic? _control;
  final _ecgController = StreamController<H10EcgFrame>.broadcast(sync: true);
  final _ecgStatuses = StreamController<String>.broadcast(sync: true);
  Stream<H10EcgFrame> get ecgStream => _ecgController.stream;
  Stream<String> get ecgStatusStream => _ecgStatuses.stream;
  String ecgStatus = 'Not connected';
  int _ecgRate = 0;
  bool _ecgStarting = false;
  final List<(List<int>, DateTime)> _earlyEcg = [];
  void _setEcgStatus(String value) {
    if (ecgStatus == value) return;
    ecgStatus = value;
    _ecgStatuses.add(value);
  }

  int _accRate = 0, _accRange = 0;
  double _accFactor = 1;
  bool _accStarting = false;
  final List<(List<int>, DateTime)> _earlyAcc = [];
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
      try {
        await _setupPmd(services, generation);
        try {
          await _startAcceleration(generation);
        } catch (error) {
          _accRate = 0;
          _earlyAcc.clear();
          _setAccStatus('Unavailable: $error');
        }
        try {
          await _startEcg(generation);
        } catch (error) {
          _ecgRate = 0;
          _earlyEcg.clear();
          _setEcgStatus('Unavailable: $error');
        }
      } catch (error) {
        _accRate = 0;
        _earlyAcc.clear();
        debugPrint('[H10 ACC ERROR] stage=$accelerationStatus error=$error');
        _setAccStatus('Unavailable: $error');
        _setEcgStatus('Unavailable: $error');
      }
    } catch (_) {
      await _disconnect();
      rethrow;
    } finally {
      if (generation != _generation) await _disconnect();
    }
  }

  void _setAccStatus(String status) {
    if (accelerationStatus == status) return;
    accelerationStatus = status;
    debugPrint('[H10 ACC] $status');
    _accStatus.add(status);
  }

  void _raw(
    BluetoothCharacteristic characteristic,
    List<int> bytes,
    BlePacketDirection direction,
    DateTime receivedAt,
  ) {
    if (characteristic.uuid == _pmdControl) {
      final hex = bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ')
          .toUpperCase();
      debugPrint(
        '[H10 PMD ${direction.name.toUpperCase()}] ${bytes.length} bytes: $hex',
      );
    }
    _pmdPackets.add(
      RawBlePacket(
        receivedAt: receivedAt,
        characteristic: characteristic.uuid.str,
        bytes: List<int>.of(bytes),
        direction: direction,
      ),
    );
  }

  Future<List<int>> _command(
    BluetoothCharacteristic control,
    List<int> bytes,
    int generation,
  ) async {
    if (generation != _generation) throw StateError('Connection cancelled');
    final pending = Completer<List<int>>();
    _response = pending;
    _opcode = bytes.first;
    _measurementType = bytes[1];
    _responseBytes.clear();
    // Install the timeout listener before writing: a response can be immediate.
    final result = pending.future.timeout(const Duration(seconds: 8));
    unawaited(result.then<void>((_) {}, onError: (Object _) {}));
    try {
      _raw(control, bytes, BlePacketDirection.tx, DateTime.now());
      await control.write(bytes, withoutResponse: !control.properties.write);
      return await result;
    } finally {
      if (identical(_response, pending)) {
        _response = null;
        _opcode = null;
      }
    }
  }

  Future<void> _setupPmd(
    List<BluetoothService> services,
    int generation,
  ) async {
    BluetoothCharacteristic? control, data;
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == _pmdControl) control = characteristic;
        if (characteristic.uuid == _pmdData) data = characteristic;
      }
    }
    if (control == null || data == null) {
      throw StateError('H10 PMD characteristics not found');
    }
    final cp = control, stream = data;
    _control = cp;
    _setAccStatus('Subscribing to Polar PMD');
    _controlSubscription = cp.onValueReceived.listen((bytes) {
      if (generation != _generation) return;
      _raw(cp, bytes, BlePacketDirection.rx, DateTime.now());
      final pending = _response;
      if (pending == null ||
          pending.isCompleted ||
          bytes.length < 4 ||
          bytes[0] != 0xf0 ||
          bytes[1] != _opcode ||
          bytes[2] != _measurementType) {
        return;
      }
      if (bytes[3] != 0) {
        pending.completeError(
          StateError('PMD command rejected: status ${bytes[3]}'),
        );
      } else {
        if (_responseBytes.length + bytes.length > 4096) {
          pending.completeError(
            const FormatException('Oversized PMD response'),
          );
          return;
        }
        if (bytes.length > 5) _responseBytes.addAll(bytes.sublist(5));
        if (bytes.length <= 4 || bytes[4] == 0) {
          pending.complete(List<int>.of(_responseBytes));
        }
      }
    });
    _accSubscription = stream.onValueReceived.listen((bytes) {
      if (generation != _generation) return;
      final now = DateTime.now();
      _raw(stream, bytes, BlePacketDirection.rx, now);
      if (bytes.isNotEmpty && bytes.first == 0) {
        if (_ecgStarting) {
          if (_earlyEcg.length < 16) _earlyEcg.add((List<int>.of(bytes), now));
        } else {
          _decodeEcg(bytes, now);
        }
        return;
      }
      if (bytes.isEmpty || bytes.first != 2) return;
      if (_accStarting) {
        if (_earlyAcc.length < 16) _earlyAcc.add((List<int>.of(bytes), now));
        return;
      }
      _decodeAcc(bytes, now);
    });
    await cp.setNotifyValue(true);
    await stream.setNotifyValue(true);
  }

  Future<void> _startAcceleration(int generation) async {
    final cp = _control!;
    _setAccStatus('Querying ACC settings');
    final queryResponse = await _command(cp, [1, 2], generation);
    debugPrint('[H10 ACC QUERY] payload=$queryResponse');
    final offered = H10AccProtocol.settings(queryResponse);
    _accRate = H10AccProtocol.choose(offered[0], [50, 25, 100, 200]);
    H10AccProtocol.choose(offered[1], [16]);
    _accRange = H10AccProtocol.choose(offered[2], [8, 4, 2]);
    _setAccStatus('Starting $_accRate Hz, ±$_accRange g');
    _accStarting = true;
    try {
      final response = await _command(
        cp,
        H10AccProtocol.start(_accRate, _accRange),
        generation,
      );
      debugPrint('[H10 ACC START] payload=$response');
      _accFactor = H10AccProtocol.factor(
        H10AccProtocol.settings(response, startAcknowledgment: true),
      );
    } finally {
      _accStarting = false;
    }
    if (generation != _generation) return;
    _setAccStatus('Started $_accRate Hz, ±$_accRange g; waiting for data');
    for (final (bytes, now) in _earlyAcc) {
      _decodeAcc(bytes, now);
    }
    _earlyAcc.clear();
  }

  Future<void> _startEcg(int generation) async {
    final cp = _control!;
    _setEcgStatus('Querying ECG settings');
    final offered = H10AccProtocol.settings(
      await _command(cp, [1, 0], generation),
    );
    if (!(offered[0]?.contains(130) ?? false) ||
        !(offered[1]?.contains(14) ?? false)) {
      throw const FormatException(
        'H10 ECG 130 Hz / 14-bit setting not offered',
      );
    }
    _ecgStarting = true;
    try {
      await _command(cp, H10EcgProtocol.start(130, 14), generation);
      if (generation != _generation) return;
      _ecgRate = 130;
      _setEcgStatus('Started 130 Hz; waiting for data');
      for (final (bytes, now) in _earlyEcg) {
        _decodeEcg(bytes, now);
      }
    } finally {
      _ecgStarting = false;
      _earlyEcg.clear();
    }
  }

  void _decodeEcg(List<int> bytes, DateTime now) {
    if (_ecgRate == 0) return;
    try {
      _ecgController.add(H10EcgProtocol.decode(bytes, now, _ecgRate));
      _setEcgStatus('Streaming 130 Hz');
    } catch (error) {
      _setEcgStatus('Decode failed; raw preserved: $error');
    }
  }

  void _decodeAcc(List<int> bytes, DateTime now) {
    if (_accRate == 0) return;
    try {
      final frame = H10AccProtocol.decode(
        bytes,
        now,
        _accRate,
        _accRange,
        factor: _accFactor,
      );
      _accController.add(frame);
      _setAccStatus('Streaming $_accRate Hz, ±$_accRange g');
    } catch (error) {
      _setAccStatus('Decode failed; raw preserved: $error');
    }
  }

  void _connectionLost(int generation) {
    if (generation != _generation) return;
    _generation++;
    final pending = _response;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('H10 disconnected'));
    }
    _setAccStatus('Disconnected');
    _ecgRate = 0;
    _setEcgStatus('Disconnected');
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
    await _controlSubscription?.cancel();
    await _accSubscription?.cancel();
    _controlSubscription = null;
    _accSubscription = null;
    final pending = _response;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('H10 disconnected'));
    }
    _response = null;
    _opcode = null;
    _control = null;
    _ecgRate = 0;
    _ecgStarting = false;
    _earlyEcg.clear();
    _setEcgStatus('Not connected');
    _accRate = 0;
    _accFactor = 1;
    _earlyAcc.clear();
    _setAccStatus('Not connected');
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
    await _accController.close();
    await _pmdPackets.close();
    await _accStatus.close();
    await _ecgController.close();
    await _ecgStatuses.close();
  }
}
