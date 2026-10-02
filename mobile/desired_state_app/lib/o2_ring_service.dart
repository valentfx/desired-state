import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'device_models.dart';

/// Ring-specific Viatom/Wellue adapter. Vendor packets remain raw until their
/// layout and integrity checks have been verified against physical captures.
class O2RingService {
  static const diagnosticsBuildId = 'O2RING-PROTOCOL-DUAL-20261001';
  static final Guid pulseOximeterService = Guid(
    '00001822-0000-1000-8000-00805f9b34fb',
  );
  static final Guid continuousMeasurement = Guid(
    '00002a5f-0000-1000-8000-00805f9b34fb',
  );
  static final Guid viatomService = Guid(
    '14839ac4-7d7e-415c-9a42-167340cf2339',
  );
  static final Guid viatomWrite = Guid('8b00ace7-eb0b-49b0-bbe9-9aee0a26e1a3');
  static final Guid viatomNotify = Guid('0734594a-a8e7-4b1a-a6b1-cd5243059a57');
  // Newer Wellue O2Ring-S / T8520 devices expose the distinct OxyII service.
  static final Guid oxyIiService = Guid('e8fb0001-a14b-98f9-831b-4e2941d01248');
  static final Guid oxyIiWrite = Guid('e8fb0002-a14b-98f9-831b-4e2941d01248');
  static final Guid oxyIiNotify = Guid('e8fb0003-a14b-98f9-831b-4e2941d01248');
  static const List<int> readSensorsCommand = <int>[
    0xAA,
    0x17,
    0xE8,
    0x00,
    0x00,
    0x00,
    0x00,
    0x1B,
  ];
  static const Duration pollInterval = Duration(seconds: 1);

  BluetoothDevice? _device;
  final List<_O2RingRequestPath> _requestPaths = [];
  final List<StreamSubscription<List<int>>> _notifications = [];
  StreamSubscription<BluetoothConnectionState>? _connection;
  Timer? _pollTimer;
  bool _pollInFlight = false;
  Future<void>? _requestFinished;
  bool _disposed = false;
  final _status = StreamController<DeviceConnectionStatus>.broadcast(
    sync: true,
  );
  final _diagnosticsChanged = StreamController<void>.broadcast(sync: true);
  final _packets = StreamController<RawBlePacket>.broadcast(sync: true);
  final _readings = StreamController<O2RingReading>.broadcast(sync: true);
  final _recentPackets = <RawBlePacket>[];
  final _gattCharacteristics = <O2RingGattCharacteristic>[];
  final _notifyStatuses = <String, String>{};
  String _serviceDiscoveryStatus = 'Not started';
  String _writeCharacteristicStatus = 'Not discovered';
  String _lastTx = 'None';
  String _lastRx = 'None';
  int _generation = 0;
  int _pollTick = 0;
  int _oxyIiSequence = 0;

  Stream<DeviceConnectionStatus> get statusStream => _status.stream;
  Stream<void> get diagnosticsChanged => _diagnosticsChanged.stream;
  Stream<RawBlePacket> get packets => _packets.stream;
  Stream<O2RingReading> get readings => _readings.stream;
  BluetoothDevice? get device => _device;
  List<RawBlePacket> get recentPackets => List.unmodifiable(_recentPackets);
  List<O2RingGattCharacteristic> get gattCharacteristics =>
      List.unmodifiable(_gattCharacteristics);
  Map<String, String> get notifyStatuses => Map.unmodifiable(_notifyStatuses);
  String get serviceDiscoveryStatus => _serviceDiscoveryStatus;
  String get writeCharacteristicStatus => _writeCharacteristicStatus;
  String get lastTx => _lastTx;
  String get lastRx => _lastRx;
  bool get canRequestSensors => _requestPaths.isNotEmpty;

  static List<int> buildOxyIiLiveSamplesRequest(int sequence) {
    final frame = <int>[0xA5, 0x04, 0xFB, 0x00, sequence & 0xFF, 0x00, 0x00];
    frame.add(_oxyIiCrc8(frame));
    return List.unmodifiable(frame);
  }

  static int _oxyIiCrc8(List<int> bytes) {
    var crc = 0;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 0x80) != 0
            ? ((crc << 1) ^ 0x07) & 0xFF
            : (crc << 1) & 0xFF;
      }
    }
    return crc;
  }

  static bool isCandidate(ScanResult result) {
    final name = result.device.platformName.trim().toUpperCase();
    return name.contains('O2RING') ||
        name.contains('T8520') ||
        name.contains('S8-AW') ||
        name.contains('OXYLINK') ||
        name.contains('VIATOM') ||
        name.contains('WELLUE') ||
        result.advertisementData.serviceUuids.contains(pulseOximeterService) ||
        result.advertisementData.serviceUuids.contains(oxyIiService);
  }

  Future<List<ScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final found = <ScanResult>[];
    await FlutterBluePlus.stopScan();
    final subscription = FlutterBluePlus.scanResults.listen((results) {
      found
        ..clear()
        ..addAll(results.where(isCandidate));
    });
    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      await FlutterBluePlus.isScanning.where((value) => !value).first;
    } finally {
      await subscription.cancel();
    }
    return found;
  }

  Future<void> connect(BluetoothDevice device) async {
    debugPrint('[O2Ring] Driver revision $diagnosticsBuildId');
    await disconnect();
    final generation = ++_generation;
    _device = device;
    _requestPaths.clear();
    _pollTick = 0;
    _oxyIiSequence = 0;
    _gattCharacteristics.clear();
    _notifyStatuses.clear();
    _serviceDiscoveryStatus = 'Connecting';
    _writeCharacteristicStatus = 'Not discovered';
    _lastTx = 'None';
    _lastRx = 'None';
    _emitDiagnosticsChanged();
    _status.add(DeviceConnectionStatus.connecting);

    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      if (!_isCurrent(generation)) throw StateError('Connection cancelled');
      _connection = device.connectionState.listen((state) {
        if (!_isCurrent(generation)) return;
        if (state == BluetoothConnectionState.disconnected) {
          _stopPolling();
          _status.add(DeviceConnectionStatus.disconnected);
        }
      });

      _serviceDiscoveryStatus = 'Discovering services';
      _emitDiagnosticsChanged();
      final services = await device.discoverServices();
      if (!_isCurrent(generation)) throw StateError('Connection cancelled');
      _serviceDiscoveryStatus = 'Complete (${services.length} services)';
      debugPrint(
        '[O2Ring] Service discovery complete: ${services.length} services',
      );

      for (final service in services) {
        for (final characteristic in service.characteristics) {
          final path = '${service.uuid}/${characteristic.uuid}';
          final properties = characteristic.properties;
          final propertyNames = <String>[
            if (properties.read) 'read',
            if (properties.write) 'write',
            if (properties.writeWithoutResponse) 'write without response',
            if (properties.notify) 'notify',
            if (properties.indicate) 'indicate',
            if (properties.broadcast) 'broadcast',
            if (properties.authenticatedSignedWrites) 'signed writes',
            if (properties.extendedProperties) 'extended',
          ];
          _gattCharacteristics.add(
            O2RingGattCharacteristic(
              serviceUuid: service.uuid.toString(),
              characteristicUuid: characteristic.uuid.toString(),
              properties: propertyNames,
            ),
          );
          debugPrint(
            '[O2Ring] GATT $path properties=${propertyNames.join(',')}',
          );
          // Listen first so an immediate response cannot race past the app.
          if (properties.notify || properties.indicate) {
            _notifyStatuses[path] = 'Subscribing';
            debugPrint('[O2Ring] Enabling notifications: $path');
            _notifications.add(
              characteristic.onValueReceived.listen((bytes) {
                if (_isCurrent(generation)) {
                  _onPacket(path, characteristic.uuid, bytes);
                }
              }),
            );
            _emitDiagnosticsChanged();
            try {
              await characteristic.setNotifyValue(true);
              _notifyStatuses[path] = 'Subscribed';
              debugPrint('[O2Ring] Notify subscription succeeded: $path');
            } catch (error) {
              _notifyStatuses[path] = 'Failed: $error';
              debugPrint(
                '[O2Ring] Notify subscription failed: $path error=$error',
              );
            }
            _emitDiagnosticsChanged();
          }
        }
      }

      if (!_isCurrent(generation)) throw StateError('Connection cancelled');
      _configureRequestPaths(services);
      _writeCharacteristicStatus = _requestPaths.isEmpty
          ? 'No supported O2Ring protocol write/notify pair found'
          : _requestPaths
                .map((path) => '${path.protocol}: ${path.write.uuid}')
                .join(' | ');
      _emitDiagnosticsChanged();
      _status.add(DeviceConnectionStatus.connected);

      // These are read-only measurement requests. If a device exposes both
      // protocol generations, try both so its actual response identifies which
      // implementation is active. Both notify subscriptions are completed first.
      if (_requestPaths.isNotEmpty) {
        debugPrint(
          '[O2Ring] Active protocol paths: ${_requestPaths.map((e) => e.protocol).join(', ')}',
        );
        try {
          await requestSensors();
        } catch (_) {
          // The first write can fail due to ATT write-mode differences. Keep
          // the connection and periodic retry alive for visible diagnostics.
        }
        _startPolling(generation);
      } else {
        _lastTx = 'Not sent: no supported protocol has a writable characteristic and subscribed notify path';
        _emitDiagnosticsChanged();
        debugPrint('[O2Ring] No request sent: $_lastTx');
      }
    } catch (_) {
      if (_isCurrent(generation)) _status.add(DeviceConnectionStatus.error);
      await disconnect();
      rethrow;
    }
  }

  void _configureRequestPaths(List<BluetoothService> services) {
    _requestPaths.clear();
    for (final service in services) {
      final isLegacy = service.uuid == viatomService;
      final isOxyIi = service.uuid == oxyIiService;
      if (!isLegacy && !isOxyIi) continue;

      final characteristics = service.characteristics;
      final expectedWrite = isLegacy ? viatomWrite : oxyIiWrite;
      final expectedNotify = isLegacy ? viatomNotify : oxyIiNotify;
      BluetoothCharacteristic? write = _firstCharacteristic(
        characteristics,
        (item) => item.uuid == expectedWrite,
      );
      BluetoothCharacteristic? notify = _firstCharacteristic(
        characteristics,
        (item) => item.uuid == expectedNotify,
      );

      // The known legacy Viatom client falls back to any writable/notifying
      // characteristic on this service when a model advertises variant UUIDs.
      if (isLegacy && write == null) {
        write = _firstCharacteristic(characteristics, (item) {
          final properties = item.properties;
          return properties.write || properties.writeWithoutResponse;
        });
      }
      if (isLegacy && notify == null) {
        notify = _firstCharacteristic(characteristics, (item) {
          final properties = item.properties;
          return properties.notify || properties.indicate;
        });
      }

      if (write == null || notify == null) {
        debugPrint(
          '[O2Ring] ${isLegacy ? 'Legacy' : 'OxyII'} path unavailable: '
          'write=${write?.uuid} notify=${notify?.uuid}',
        );
        continue;
      }
      final notifyPath = '${service.uuid}/${notify.uuid}';
      if (_notifyStatuses[notifyPath] != 'Subscribed') {
        debugPrint(
          '[O2Ring] ${isLegacy ? 'Legacy' : 'OxyII'} path blocked: '
          'notify status=${_notifyStatuses[notifyPath] ?? 'not notifiable'}',
        );
        continue;
      }
      final writeProperties = write.properties;
      if (!writeProperties.write && !writeProperties.writeWithoutResponse) {
        debugPrint(
          '[O2Ring] ${isLegacy ? 'Legacy' : 'OxyII'} path blocked: '
          'write characteristic ${write.uuid} is not writable',
        );
        continue;
      }
      final path = _O2RingRequestPath(
        protocol: isLegacy ? 'Viatom legacy' : 'Viatom OxyII / O2Ring-S',
        service: service.uuid,
        write: write,
        pollEverySeconds: isOxyIi ? 1 : 2,
      );
      _requestPaths.add(path);
      debugPrint(
        '[O2Ring] Selected ${path.protocol}: write=${write.uuid} '
        'notify=${notify.uuid} writeProps='
        '${writeProperties.write ? 'write ' : ''}'
        '${writeProperties.writeWithoutResponse ? 'writeWithoutResponse' : ''}',
      );
    }
  }

  BluetoothCharacteristic? _firstCharacteristic(
    List<BluetoothCharacteristic> characteristics,
    bool Function(BluetoothCharacteristic) test,
  ) {
    for (final characteristic in characteristics) {
      if (test(characteristic)) return characteristic;
    }
    return null;
  }

  Future<void> requestSensors() => _sendRequests(_requestPaths);

  Future<void> _sendRequests(List<_O2RingRequestPath> paths) async {
    final device = _device;
    if (paths.isEmpty || device == null || _disposed || _pollInFlight) return;
    _pollInFlight = true;
    final requestFinished = Completer<void>();
    _requestFinished = requestFinished.future;
    final generation = _generation;
    Object? firstError;
    try {
      for (final path in paths) {
        if (!_isCurrent(generation)) break;
        final bytes = path.service == viatomService
            ? readSensorsCommand
            : buildOxyIiLiveSamplesRequest(_oxyIiSequence++);
        final packet = RawBlePacket(
          receivedAt: DateTime.now().toUtc(),
          characteristic: '${path.service}/${path.write.uuid}',
          bytes: List.unmodifiable(bytes),
          direction: BlePacketDirection.tx,
          interpretation: '${path.protocol} measurement request attempt',
        );
        _recordPacket(packet);
        debugPrint(
          '[O2Ring] TX attempt protocol=${path.protocol} '
          '${packet.characteristic} length=${bytes.length} hex=${packet.hex}',
        );
        var withoutResponse = path.write.properties.writeWithoutResponse;
        try {
          try {
            await path.write.write(bytes, withoutResponse: withoutResponse);
          } catch (firstWriteError) {
            // The known cross-platform Viatom client retries the other ATT
            // write mode because peripheral property reporting can vary.
            final fallbackMode = !withoutResponse;
            debugPrint(
              '[O2Ring] ${path.protocol} write mode '
              'withoutResponse=$withoutResponse failed: $firstWriteError; '
              'retrying withoutResponse=$fallbackMode',
            );
            withoutResponse = fallbackMode;
            await path.write.write(bytes, withoutResponse: withoutResponse);
          }
          if (!_isCurrent(generation)) break;
          _lastTx =
              '${path.protocol} ${packet.receivedAt.toLocal().toIso8601String()}  '
              '${bytes.length} bytes ${packet.hex} '
              '(${withoutResponse ? 'without response' : 'with response'})';
          debugPrint(
            '[O2Ring] TX succeeded protocol=${path.protocol} '
            'withoutResponse=$withoutResponse',
          );
        } catch (error) {
          firstError ??= error;
          _lastTx = '${path.protocol} write failed: $error';
          debugPrint('[O2Ring] TX failed protocol=${path.protocol}: $error');
        }
        _emitDiagnosticsChanged();
      }
    } finally {
      _pollInFlight = false;
      if (!requestFinished.isCompleted) requestFinished.complete();
      _requestFinished = null;
      _emitDiagnosticsChanged();
    }
    if (firstError != null) throw StateError('$firstError');
  }

  void _startPolling(int generation) {
    _stopPolling();
    _pollTimer = Timer.periodic(pollInterval, (_) async {
      if (!_isCurrent(generation)) return;
      _pollTick++;
      final duePaths = _requestPaths
          .where((path) => _pollTick % path.pollEverySeconds == 0)
          .toList(growable: false);
      try {
        await _sendRequests(duePaths);
      } catch (_) {
        // Keep diagnostics connected; each failed attempt is retained in TX.
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _onPacket(String characteristic, Guid uuid, List<int> bytes) {
    final now = DateTime.now().toUtc();
    final reading = decodeNotification(uuid, bytes, now);
    final packet = RawBlePacket(
      receivedAt: now,
      characteristic: characteristic,
      bytes: List.unmodifiable(bytes),
      interpretation: reading == null
          ? 'Unparsed vendor packet (raw bytes preserved)'
          : 'Standard BLE pulse-oximeter measurement',
    );
    _recordPacket(packet);
    _lastRx =
        '${now.toLocal().toIso8601String()}  ${bytes.length} bytes  ${packet.hex}';
    debugPrint(
      '[O2Ring] RX $characteristic length=${bytes.length} hex=${packet.hex}',
    );
    if (reading != null) _readings.add(reading);
    _emitDiagnosticsChanged();
  }

  void _recordPacket(RawBlePacket packet) {
    _recentPackets.add(packet);
    if (_recentPackets.length > 250) _recentPackets.removeAt(0);
    _packets.add(packet);
  }

  void _emitDiagnosticsChanged() {
    if (!_disposed && !_diagnosticsChanged.isClosed) {
      _diagnosticsChanged.add(null);
    }
  }

  /// Vendor notifications stay raw until their protocol has been validated.
  static O2RingReading? decodeNotification(
    Guid characteristic,
    List<int> bytes,
    DateTime receivedAt,
  ) {
    if (characteristic != continuousMeasurement) return null;
    return decodeStandardPulseOximeter(bytes, receivedAt);
  }

  /// Bluetooth SIG Pulse Oximeter Continuous Measurement (0x2A5F).
  static O2RingReading? decodeStandardPulseOximeter(
    List<int> bytes,
    DateTime receivedAt,
  ) {
    if (bytes.length < 5) return null;
    final spo2 = _sfloatToInt(bytes[1] | (bytes[2] << 8));
    final pulse = _sfloatToInt(bytes[3] | (bytes[4] << 8));
    if (spo2 == null && pulse == null) return null;
    return O2RingReading(
      receivedAt: receivedAt,
      spo2: spo2,
      pulse: pulse,
      quality: null,
    );
  }

  static int? _sfloatToInt(int raw) {
    if (raw == 0x07ff || raw == 0x07fe || raw == 0x0800) return null;
    var mantissa = raw & 0x0fff;
    if ((mantissa & 0x0800) != 0) mantissa -= 0x1000;
    var exponent = (raw >> 12) & 0x0f;
    if ((exponent & 0x08) != 0) exponent -= 0x10;
    final value = mantissa * _pow10(exponent);
    if (!value.isFinite || value < 0 || value > 1000) return null;
    return value.round();
  }

  static double _pow10(int exponent) {
    var value = 1.0;
    for (var index = 0; index < exponent.abs(); index++) {
      value = exponent >= 0 ? value * 10 : value / 10;
    }
    return value;
  }

  Future<void> disconnect() async {
    _generation++;
    _stopPolling();
    for (final subscription in _notifications) {
      await subscription.cancel();
    }
    _notifications.clear();
    await _connection?.cancel();
    _connection = null;
    await _requestFinished;
    final device = _device;
    _device = null;
    _requestPaths.clear();
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }
    if (!_disposed) _status.add(DeviceConnectionStatus.disconnected);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    await _status.close();
    await _diagnosticsChanged.close();
    await _packets.close();
    await _readings.close();
  }
}

class O2RingGattCharacteristic {
  const O2RingGattCharacteristic({
    required this.serviceUuid,
    required this.characteristicUuid,
    required this.properties,
  });

  final String serviceUuid;
  final String characteristicUuid;
  final List<String> properties;
}

class _O2RingRequestPath {
  const _O2RingRequestPath({
    required this.protocol,
    required this.service,
    required this.write,
    required this.pollEverySeconds,
  });

  final String protocol;
  final Guid service;
  final BluetoothCharacteristic write;
  final int pollEverySeconds;
}
