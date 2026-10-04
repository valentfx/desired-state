import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App-owned output lifecycle. Screens never own timers or stop outputs on exit.
class PracticeController extends ChangeNotifier {
  PracticeController({required this.onEvent});
  final void Function(String event, Map<String, Object> values) onEvent;
  Timer? _timer;
  bool running = false, paused = false;
  bool vibration = false, sound = false;
  int inhaleSeconds = 5, exhaleSeconds = 5, elapsed = 0;
  String get phase => elapsed % (inhaleSeconds + exhaleSeconds) < inhaleSeconds
      ? 'Inhale'
      : 'Exhale';
  double get progress {
    final position = elapsed % (inhaleSeconds + exhaleSeconds);
    return position < inhaleSeconds
        ? position / inhaleSeconds
        : 1 - (position - inhaleSeconds) / exhaleSeconds;
  }

  Map<String, Object> get settings => {
    'version': 1,
    'type': 'phone_breathing_pacer',
    'inhale_seconds': inhaleSeconds,
    'exhale_seconds': exhaleSeconds,
    'vibration': vibration,
    'system_click': sound,
    'running': running,
    'paused': paused,
  };
  void configure({
    required int inhale,
    required int exhale,
    required bool haptic,
    required bool audio,
  }) {
    if (running) throw StateError('Stop practice before changing settings');
    if (inhale < 2 || inhale > 10 || exhale < 2 || exhale > 10) {
      throw ArgumentError('Choose 2–10 seconds per phase');
    }
    inhaleSeconds = inhale;
    exhaleSeconds = exhale;
    vibration = haptic;
    sound = audio;
    onEvent('practice_configured', settings);
    notifyListeners();
  }

  void start() {
    if (running) return;
    running = true;
    paused = false;
    elapsed = 0;
    onEvent('practice_started', settings);
    _cue();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (paused) return;
      final previous = phase;
      elapsed++;
      if (phase != previous) _cue();
      notifyListeners();
    });
    notifyListeners();
  }

  void _cue() {
    if (vibration) {
      unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
    }
    if (sound) {
      unawaited(
        SystemSound.play(SystemSoundType.click).catchError((Object _) {}),
      );
    }
  }

  void pause() {
    if (!running || paused) return;
    paused = true;
    onEvent('practice_paused', settings);
    notifyListeners();
  }

  void resume() {
    if (!running || !paused) return;
    paused = false;
    onEvent('practice_resumed', settings);
    notifyListeners();
  }

  void stop() {
    if (!running) return;
    _timer?.cancel();
    running = false;
    paused = false;
    onEvent('practice_stopped', settings);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
