import 'package:flutter/services.dart';

class RecordingForegroundService {
  static const _channel = MethodChannel('desired_state/recording_service');

  Future<void> start(String sessionId) {
    return _channel.invokeMethod<void>('start', {'sessionId': sessionId});
  }

  Future<void> stop() => _channel.invokeMethod<void>('stop');
}
