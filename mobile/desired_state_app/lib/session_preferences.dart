import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

const recordingStreams = <String, String>{
  'heart': 'Heart rate and RR intervals',
  'ecg': 'ECG waveform',
  'acc': 'Acceleration samples',
  'posture': 'Posture estimates',
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
    this.eegArtifactScreening = false,
    this.museOpticalCapture = false,
    this.hiddenInspection = const {'ECG'},
  }) : recording = recording ?? (recordingStreams.keys.toSet()..remove('ecg'));
  final Set<String> recording;
  final Set<String> hiddenInspection;
  final bool showEeg,
      showOxygen,
      showPosture,
      eegArtifactScreening,
      museOpticalCapture;
  SessionPreferences copyWith({
    Set<String>? recording,
    Set<String>? hiddenInspection,
    bool? showEeg,
    bool? showOxygen,
    bool? showPosture,
    bool? eegArtifactScreening,
    bool? museOpticalCapture,
  }) => SessionPreferences(
    recording: recording ?? {...this.recording},
    hiddenInspection: hiddenInspection ?? {...this.hiddenInspection},
    showEeg: showEeg ?? this.showEeg,
    showOxygen: showOxygen ?? this.showOxygen,
    showPosture: showPosture ?? this.showPosture,
    eegArtifactScreening: eegArtifactScreening ?? this.eegArtifactScreening,
    museOpticalCapture: museOpticalCapture ?? this.museOpticalCapture,
  );
  bool records(String stream) => recording.contains(stream);
  Map<String, dynamic> toJson() => {
    'schema_version': 3,
    'recording': recording.toList()..sort(),
    'eeg_artifact_screening': eegArtifactScreening,
    'muse_optical_capture': museOpticalCapture,
    'show_eeg': showEeg,
    'show_oxygen': showOxygen,
    'show_posture': showPosture,
    'hidden_inspection': hiddenInspection.toList()..sort(),
  };
  factory SessionPreferences.fromJson(Map<String, dynamic> json) {
    if (![1, 2, 3].contains(json['schema_version']) ||
        json['recording'] is! List ||
        ![
          'show_eeg',
          'show_oxygen',
          'show_posture',
        ].every((key) => json[key] is bool)) {
      throw const FormatException('Unsupported or damaged session preferences');
    }
    if (json['schema_version'] == 3 &&
        (json['eeg_artifact_screening'] is! bool ||
            (json.containsKey('muse_optical_capture') &&
                json['muse_optical_capture'] is! bool))) {
      throw const FormatException('Invalid EEG screening choice');
    }
    if (json.containsKey('hidden_inspection') &&
        (json['hidden_inspection'] is! List ||
            !(json['hidden_inspection'] as List).every((v) => v is String))) {
      throw const FormatException('Invalid touch readout choices');
    }
    final selected = (json['recording'] as List).cast<String>().toSet();
    // Version 1 coupled posture logging to acceleration; preserve that choice.
    if (json['schema_version'] == 1 && selected.contains('acc')) {
      selected.add('posture');
    }
    if (!selected.every(recordingStreams.containsKey)) {
      throw const FormatException('Unknown recording stream');
    }
    return SessionPreferences(
      recording: selected,
      hiddenInspection: json.containsKey('hidden_inspection')
          ? (json['hidden_inspection'] as List).cast<String>().toSet()
          : const {'ECG'},
      eegArtifactScreening: json['eeg_artifact_screening'] as bool? ?? false,
      museOpticalCapture: json['muse_optical_capture'] as bool? ?? false,
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
