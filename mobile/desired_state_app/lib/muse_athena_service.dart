import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  bool streaming = false;
  bool busy = false;
  String status = 'Not connected';
  String deviceHint = '';
  int eegRate = 0;
  int motionRate = 0;
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

  Future<void> connect({String serialNumber = ''}) async {
    if (busy || streaming) return;
    busy = true;
    status = 'Connecting and starting Athena stream…';
    _clearSamples();
    notifyListeners();
    try {
      _subscription ??= _events.receiveBroadcastStream().listen(
        _onEvent,
        onError: (Object error) {
          status = 'Athena stream error: $error';
          streaming = false;
          notifyListeners();
        },
      );
      final result = await _methods.invokeMapMethod<String, dynamic>(
        'start',
        <String, Object>{
          'serialNumber': serialNumber.trim(),
          'preset': 'p21',
          'lowLatency': true,
        },
      );
      eegRate = (result?['eegRate'] as num?)?.toInt() ?? 0;
      motionRate = (result?['motionRate'] as num?)?.toInt() ?? 0;
      deviceHint = (result?['deviceHint'] as String?) ?? 'Muse S Athena';
      streaming = true;
      status = 'Connected; waiting for EEG and motion samples';
    } catch (error) {
      streaming = false;
      status = 'Athena start failed: $error';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    if (busy) return;
    busy = true;
    status = 'Stopping Athena stream…';
    notifyListeners();
    try {
      await _methods.invokeMethod<void>('stop');
      streaming = false;
      status = 'Disconnected';
    } catch (error) {
      status = 'Athena stop error: $error';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void reportStatus(String value) {
    status = value;
    notifyListeners();
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final map = Map<Object?, Object?>.from(event);
    if (map['type'] == 'status') {
      status = map['message']?.toString() ?? status;
      if (status.startsWith('Athena stream read failed:')) streaming = false;
      notifyListeners();
      return;
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
    if (eegSamples > 0 || motionSamples > 0) {
      status = 'Receiving live EEG and motion';
    }
    notifyListeners();
  }

  void _appendRows(
    Object? source,
    Map<String, List<double>> history,
    Map<String, double> latest,
    String prefix,
  ) {
    if (source is! Map) return;
    for (final entry in source.entries) {
      if (entry.value is! List) continue;
      final values = (entry.value as List)
          .whereType<num>()
          .map((value) => value.toDouble())
          .where((value) => value.isFinite)
          .toList(growable: false);
      if (values.isEmpty) continue;
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
    eegSamples = motionSamples = 0;
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
    final subscription = _subscription;
    if (subscription != null) {
      unawaited(subscription.cancel());
      unawaited(_methods.invokeMethod<void>('stop').catchError((Object _) {}));
    }
    super.dispose();
  }
}
