import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Active-time countdown. A monotonic clock keeps wall-clock changes irrelevant.
class SessionCountdown {
  SessionCountdown({Duration Function()? clock}) {
    final watch = Stopwatch()..start();
    _clock = clock ?? (() => watch.elapsed);
  }
  late final Duration Function() _clock;
  Duration? duration;
  Duration _accumulated = Duration.zero;
  Duration? _runningSince;
  bool completed = false;
  Duration get elapsed =>
      _accumulated +
      (_runningSince == null ? Duration.zero : _clock() - _runningSince!);
  Duration get remaining {
    final left = (duration ?? Duration.zero) - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  void start(Duration value) {
    if (value <= Duration.zero || value > const Duration(days: 1)) {
      throw ArgumentError('Timer must be between 1 second and 24 hours');
    }
    duration = value;
    _accumulated = Duration.zero;
    _runningSince = _clock();
    completed = false;
  }

  bool checkCompletion() {
    if (duration == null || completed || remaining > Duration.zero) {
      return false;
    }
    completed = true;
    pause();
    return true;
  }

  void pause() {
    if (_runningSince != null) {
      _accumulated = elapsed;
      _runningSince = null;
    }
  }

  void resume() {
    if (duration != null && !completed && _runningSince == null) {
      _runningSince = _clock();
    }
  }

  void clear() {
    duration = null;
    _accumulated = Duration.zero;
    _runningSince = null;
    completed = false;
  }
}

class SessionTimerPreference {
  const SessionTimerPreference({this.minutes = 20, this.vibrate = true});
  final int minutes;
  final bool vibrate;
  Map<String, dynamic> toJson() => {
    'schema_version': 1,
    'minutes': minutes,
    'vibrate': vibrate,
  };
  static SessionTimerPreference parse(dynamic row) {
    if (row is! Map ||
        row['schema_version'] != 1 ||
        row['minutes'] is! int ||
        row['minutes'] < 1 ||
        row['minutes'] > 1440 ||
        row['vibrate'] is! bool) {
      throw const FormatException(
        'Invalid timer preference; original preserved',
      );
    }
    return SessionTimerPreference(
      minutes: row['minutes'] as int,
      vibrate: row['vibrate'] as bool,
    );
  }
}

class SessionTimerPreferenceStore {
  SessionTimerPreferenceStore({this.directoryProvider});
  final Future<Directory> Function()? directoryProvider;
  Future<File> _file() async => File(
    '${(await (directoryProvider ?? getApplicationDocumentsDirectory)()).path}/session_timer_preference.json',
  );
  Future<SessionTimerPreference> load() async {
    final file = await _file();
    return await file.exists()
        ? SessionTimerPreference.parse(jsonDecode(await file.readAsString()))
        : const SessionTimerPreference();
  }

  Future<void> save(SessionTimerPreference value) async {
    SessionTimerPreference.parse(value.toJson());
    final file = await _file();
    // Do not overwrite a corrupt existing preference.
    if (await file.exists()) {
      SessionTimerPreference.parse(jsonDecode(await file.readAsString()));
    }
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.pending');
    await pending.writeAsString('${jsonEncode(value.toJson())}\n', flush: true);
    if (await file.exists()) {
      await file.copy('${file.path}.previous');
    }
    await pending.rename(file.path);
  }
}
