import 'package:flutter/services.dart';

class RecordingForegroundService {
  static const _channel = MethodChannel('desired_state/recording_service');

  Future<void> start(String sessionId) {
    return _channel.invokeMethod<void>('start', {
      'sessionId': sessionId,
      'state': 'Recording',
    });
  }

  Future<void> update({
    required String state,
    required int? heartRate,
    required double? rmssd,
    required int artifactCount,
    required Duration elapsed,
  }) {
    return _channel.invokeMethod<void>('update', {
      'state': state,
      'heartRate': heartRate,
      'rmssd': rmssd,
      'artifactCount': artifactCount,
      'elapsedSeconds': elapsed.inSeconds,
    });
  }

  Future<void> stop() => _channel.invokeMethod<void>('stop');
}
