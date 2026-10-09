import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'eeg_bands.dart';

/// App-owned Android bridge to BrainFlow's hardware-tested Muse S Athena path.
/// This first slice exposes EEG and motion diagnostics; session-file recording
/// is deliberately added only after the phone stream is confirmed.
class MuseAthenaService extends ChangeNotifier {
  MuseAthenaService({MethodChannel? methodChannel, EventChannel? eventChannel})
    : _methods = methodChannel ?? const MethodChannel(_methodChannelName),
      _events = eventChannel ?? const EventChannel(_eventChannelName);

  static const _methodChannelName = 'desired_state/muse_athena';
  static const _eventChannelName = 'desired_state/muse_athena/stream';
  final MethodChannel _methods;
  final EventChannel _events;
  StreamSubscription<dynamic>? _subscription;
  final _batches = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  Stream<Map<String, dynamic>> get batches => _batches.stream;
  final List<EegBandFrame> bandHistory = [];
  DateTime? lastSamplesAt;
  DateTime? _lastBandAt;
  int continuity = 0;
  EegBandFrame? baseline;
  int? baselineContinuity;
  void setBaseline(EegBandFrame frame) {
    baseline = frame;
    baselineContinuity = continuity;
    _notify();
  }

  EegBandFrame? get latestBands =>
      bandHistory.isEmpty ? null : bandHistory.last;
  bool get fresh =>
      streaming &&
      lastSamplesAt != null &&
      DateTime.now().difference(lastSamplesAt!) < const Duration(seconds: 3);
  bool _disposed = false;
  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  bool streaming = false;
  bool busy = false;
  String status = 'Not connected';
  String deviceHint = '';
  int eegRate = 0;
  int motionRate = 0;
  int opticalRate = 0;
  int opticalSamples = 0;
  String acquisitionPreset = 'p21';
  DateTime? lastOpticalAt;
  final Map<String, List<double>> opticalHistory = {};
  double? batteryRaw;

  int eegSamples = 0;
  int motionSamples = 0;
  double? latestEegTimestamp;
  double? latestMotionTimestamp;
  final Map<String, List<double>> eegHistory = {};
  final Map<String, List<double>> accelHistory = {};
  final Map<String, List<double>> gyroHistory = {};
  final Map<String, double> latestEeg = {};
  final Map<String, double> latestAccel = {};
  final Map<String, double> latestGyro = {};
  static const int _historyLimit = 1024;

  Future<void> connect({String serialNumber = '', bool optical = false}) async {
    if (busy || streaming) {
      return;
    }
    busy = true;
    status = 'Connecting and starting Athena stream…';
    _clearSamples();
    _notify();
    try {
      _subscription ??= _events.receiveBroadcastStream().listen(
        _onEvent,
        onError: (Object error) {
          status = 'Athena stream error: $error';
          streaming = false;
          _notify();
        },
      );
      final result = await _methods.invokeMapMethod<String, dynamic>(
        'start',
        <String, Object>{
          'serialNumber': serialNumber.trim(),
          'preset': optical ? 'p1035' : 'p21',
          'lowLatency': true,
        },
      );
      eegRate = (result?['eegRate'] as num?)?.toInt() ?? 0;
      motionRate = (result?['motionRate'] as num?)?.toInt() ?? 0;
      opticalRate = (result?['opticalRate'] as num?)?.toInt() ?? 0;
      acquisitionPreset = optical ? 'p1035' : 'p21';
      deviceHint = (result?['deviceHint'] as String?) ?? 'Muse S Athena';
      streaming = true;
      status = 'Connected; waiting for EEG and motion samples';
    } catch (error) {
      streaming = false;
      status = 'Athena start failed: $error';
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> disconnect() async {
    if (busy) {
      return;
    }
    busy = true;
    status = 'Stopping Athena stream…';
    _notify();
    try {
      await _methods.invokeMethod<void>('stop');
      streaming = false;
      status = 'Disconnected';
    } catch (error) {
      status = 'Athena stop error: $error';
    } finally {
      busy = false;
      _notify();
    }
  }

  void reportStatus(String value) {
    status = value;
    _notify();
  }

  void _onEvent(dynamic event) {
    if (_disposed || event is! Map) {
      return;
    }
    final map = Map<Object?, Object?>.from(event);
    if (map['type'] == 'status') {
      status = map['message']?.toString() ?? status;
      if (status.startsWith('Athena stream read failed:')) {
        streaming = false;
      }
      _notify();
      return;
    }
    final now = DateTime.now().toUtc();
    final previous = lastSamplesAt;
    if (((map['eegCount'] as num?)?.toInt() ?? 0) > 0 &&
        previous != null &&
        now.difference(previous) > const Duration(seconds: 2)) {
      continuity++;
      eegHistory.clear();
      accelHistory.clear();
      gyroHistory.clear();
    }
    if (((map['eegCount'] as num?)?.toInt() ?? 0) > 0) {
      lastSamplesAt = now;
    }
    _batches.add({
      ...Map<String, dynamic>.from(event),
      'received_utc': now.toIso8601String(),
      'continuity_segment': continuity,
    });
    if (lastOpticalAt != null &&
        now.difference(lastOpticalAt!) > const Duration(seconds: 2)) {
      opticalHistory.clear();
    }
    if (((map['opticalCount'] as num?)?.toInt() ?? 0) > 0) {
      lastOpticalAt = now;
      opticalSamples += (map['opticalCount'] as num).toInt();
      _appendRows(map['optical'], opticalHistory, <String, double>{}, 'OPT');
    }
    if (map['batteryRaw'] is num) {
      batteryRaw = (map['batteryRaw'] as num).toDouble();
    }
    _appendRows(map['eeg'], eegHistory, latestEeg, 'EEG');
    _appendRows(map['accel'], accelHistory, latestAccel, 'ACC');
    _appendRows(map['gyro'], gyroHistory, latestGyro, 'GYRO');
    eegSamples += (map['eegCount'] as num?)?.toInt() ?? 0;
    motionSamples += (map['motionCount'] as num?)?.toInt() ?? 0;
    final eegTimes = map['eegTimestamps'];
    final motionTimes = map['motionTimestamps'];
    if (eegTimes is List && eegTimes.isNotEmpty && eegTimes.last is num) {
      latestEegTimestamp = (eegTimes.last as num).toDouble();
    }
    if (motionTimes is List &&
        motionTimes.isNotEmpty &&
        motionTimes.last is num) {
      latestMotionTimestamp = (motionTimes.last as num).toDouble();
    }
    if (((map['eegCount'] as num?)?.toInt() ?? 0) > 0 &&
        (_lastBandAt == null ||
            now.difference(_lastBandAt!) >= const Duration(seconds: 1))) {
      _lastBandAt = now;
      bandHistory.add(
        buildEegFrame(now, eegHistory, eegRate, segment: continuity),
      );
      if (bandHistory.length > 900) {
        bandHistory.removeAt(0);
      }
    }
    if (eegSamples > 0 || motionSamples > 0) {
      status = 'Receiving live EEG and motion';
    }
    _notify();
  }

  void _appendRows(
    Object? source,
    Map<String, List<double>> history,
    Map<String, double> latest,
    String prefix,
  ) {
    if (source is! Map) {
      return;
    }
    for (final entry in source.entries) {
      if (entry.value is! List) {
        continue;
      }
      final values = (entry.value as List)
          .whereType<num>()
          .map((value) => value.toDouble())
          .toList(growable: false);
      if (values.isEmpty) {
        continue;
      }
      final name = entry.key.toString();
      final points = history.putIfAbsent(name, () => <double>[]);
      points.addAll(values);
      if (points.length > _historyLimit) {
        points.removeRange(0, points.length - _historyLimit);
      }
      latest['$prefix $name'] = values.last;
    }
  }

  void _clearSamples() {
    continuity++;
    baseline = null;
    baselineContinuity = null;
    _lastBandAt = null;
    lastSamplesAt = null;
    bandHistory.clear();
    eegSamples = motionSamples = opticalSamples = 0;
    opticalHistory.clear();
    lastOpticalAt = null;
    batteryRaw = null;
    latestEegTimestamp = latestMotionTimestamp = null;
    eegHistory.clear();
    accelHistory.clear();
    gyroHistory.clear();
    latestEeg.clear();
    latestAccel.clear();
    latestGyro.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    final subscription = _subscription;
    if (subscription != null) {
      unawaited(subscription.cancel());
      unawaited(_methods.invokeMethod<void>('stop').catchError((Object _) {}));
    }
    unawaited(_batches.close());
    super.dispose();
  }
}
