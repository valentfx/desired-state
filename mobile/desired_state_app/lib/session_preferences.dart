import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

const recordingStreams = <String, String>{
  'heart': 'Heart rate and RR intervals',
  'ecg': 'ECG waveform',
  'acc': 'Acceleration and posture',
  'ring': 'Oxygen and pulse',
  'muse': 'EEG, bands and head motion',
  'pmd': 'H10 raw protocol packets',
};

class SessionPreferences {
  SessionPreferences({
    Set<String>? recording,
    this.showEeg = true,
    this.showOxygen = true,
    this.showPosture = true,
  }) : recording = recording ?? recordingStreams.keys.toSet();
  final Set<String> recording;
  final bool showEeg, showOxygen, showPosture;
  bool records(String stream) => recording.contains(stream);
  Map<String, dynamic> toJson() => {
    'schema_version': 1,
    'recording': recording.toList()..sort(),
    'show_eeg': showEeg,
    'show_oxygen': showOxygen,
    'show_posture': showPosture,
  };
  factory SessionPreferences.fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != 1 ||
        json['recording'] is! List ||
        ![
          'show_eeg',
          'show_oxygen',
          'show_posture',
        ].every((key) => json[key] is bool)) {
      throw const FormatException('Unsupported or damaged session preferences');
    }
    final selected = (json['recording'] as List).cast<String>().toSet();
    if (!selected.every(recordingStreams.containsKey)) {
      throw const FormatException('Unknown recording stream');
    }
    return SessionPreferences(
      recording: selected,
      showEeg: json['show_eeg'] as bool,
      showOxygen: json['show_oxygen'] as bool,
      showPosture: json['show_posture'] as bool,
    );
  }
}

class PreferencesStore {
  PreferencesStore(this.directoryProvider);
  final Future<Directory> Function()? directoryProvider;
  Future<File> get file async {
    final root =
        await (directoryProvider ?? getApplicationDocumentsDirectory)();
    return File('${root.path}/desired_state_settings/session_preferences.json');
  }

  Future<SessionPreferences> load() async {
    final source = await file;
    if (!await source.exists()) {
      return SessionPreferences();
    }
    return SessionPreferences.fromJson(
      jsonDecode(await source.readAsString()) as Map<String, dynamic>,
    );
  }

  Future<void> save(SessionPreferences preferences) async {
    // Preserve unreadable or future-version settings instead of overwriting.
    await load();
    final destination = await file;
    await destination.parent.create(recursive: true);
    await destination.writeAsString(
      '${jsonEncode(preferences.toJson())}\n',
      flush: true,
    );
  }
}
