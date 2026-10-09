import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's foreground service is not an Apple background-recording service.
class RecordingForegroundService {
  static const _channel = MethodChannel('desired_state/recording_service');
  bool get _usesAndroidService =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> start(String sessionId) async {
    if (!_usesAndroidService) return;
    await _channel.invokeMethod<void>('start', {
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
  }) async {
    if (!_usesAndroidService) return;
    await _channel.invokeMethod<void>('update', {
      'state': state,
      'heartRate': heartRate,
      'rmssd': rmssd,
      'artifactCount': artifactCount,
      'elapsedSeconds': elapsed.inSeconds,
    });
  }

  Future<void> timerAlert({required bool vibrate}) async {
    if (_usesAndroidService) {
      try {
        await _channel.invokeMethod<void>('timerAlert', {'vibrate': vibrate});
        return;
      } on MissingPluginException {
        // A native service may be absent in an isolated development build.
      }
    }
    await SystemSound.play(SystemSoundType.alert);
    if (vibrate && defaultTargetPlatform == TargetPlatform.iOS) {
      await HapticFeedback.vibrate();
    }
  }

  Future<void> stop() async {
    if (!_usesAndroidService) return;
    await _channel.invokeMethod<void>('stop');
  }
}
