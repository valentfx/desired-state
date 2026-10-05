import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

const postureLabels = [
  'On back',
  'Right side',
  'Left side',
  'Upright',
  'Prone',
];

List<double> unitVector(List<double> vector) {
  final norm = math.sqrt(
    vector.fold<double>(0, (sum, value) => sum + value * value),
  );
  if (vector.length != 3 || !norm.isFinite || norm < 1) {
    throw const FormatException('Invalid gravity vector');
  }
  return vector.map((value) => value / norm).toList();
}

double vectorAngle(List<double> a, List<double> b) =>
    math.acos((a[0] * b[0] + a[1] * b[1] + a[2] * b[2]).clamp(-1.0, 1.0)) *
    180 /
    math.pi;

class PostureCalibration {
  PostureCalibration({
    required this.id,
    required this.deviceId,
    required this.name,
    required this.positions,
    this.participantId,
  });
  final String id, deviceId, name;
  final String? participantId;
  final Map<String, List<double>> positions;
  Map<String, dynamic> toJson() => {
    'schema_version': 1,
    'id': id,
    'device_id': deviceId,
    'name': name,
    'participant_id': participantId,
    'gravity_unit_vectors': positions,
    'method': 'gravity_nearest_angle_v1',
    'maximum_angle_degrees': 25,
    'minimum_margin_degrees': 12,
  };
  factory PostureCalibration.fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != 1 ||
        json['id'] is! String ||
        json['device_id'] is! String ||
        json['name'] is! String ||
        json['gravity_unit_vectors'] is! Map) {
      throw const FormatException('Unsupported posture calibration');
    }
    final vectors = <String, List<double>>{};
    for (final entry in (json['gravity_unit_vectors'] as Map).entries) {
      if (!postureLabels.contains(entry.key) || entry.value is! List) {
        throw const FormatException('Invalid posture reference');
      }
      final values = (entry.value as List)
          .map((v) => (v as num).toDouble())
          .toList();
      if (values.length != 3 || values.any((v) => !v.isFinite)) {
        throw const FormatException('Invalid posture reference');
      }
      vectors[entry.key as String] = unitVector(
        values.map((v) => v * 1000).toList(),
      );
    }
    return PostureCalibration(
      id: json['id'] as String,
      deviceId: json['device_id'] as String,
      name: json['name'] as String,
      participantId: json['participant_id'] as String?,
      positions: vectors,
    );
  }
  String classify(List<List<int>> samples) {
    if (positions.length < 3 || samples.isEmpty) {
      return 'Unknown';
    }
    try {
      final gravity = stableGravity(samples, minimumSamples: 1);
      final ranked =
          positions.entries
              .map((entry) => (entry.key, vectorAngle(gravity, entry.value)))
              .toList()
            ..sort((a, b) => a.$2.compareTo(b.$2));
      if (ranked.first.$2 > 25 || ranked[1].$2 - ranked.first.$2 < 12) {
        return 'Unknown';
      }
      return ranked.first.$1;
    } on FormatException {
      return 'Moving';
    }
  }
}

List<double> stableGravity(
  List<List<int>> samples, {
  int minimumSamples = 150,
}) {
  if (samples.length < minimumSamples || samples.any((v) => v.length != 3)) {
    throw const FormatException(
      'Not enough acceleration samples. Check the H10 connection.',
    );
  }
  final mean = List<double>.generate(
    3,
    (axis) =>
        samples.map((v) => v[axis]).reduce((a, b) => a + b) / samples.length,
  );
  final magnitude = math.sqrt(mean.fold<double>(0, (s, v) => s + v * v));
  final rms = math.sqrt(
    samples
            .map(
              (v) => List<double>.generate(
                3,
                (i) => (v[i] - mean[i]) * (v[i] - mean[i]),
              ).reduce((a, b) => a + b),
            )
            .reduce((a, b) => a + b) /
        samples.length,
  );
  if (magnitude < 700 || magnitude > 1300 || rms > 100) {
    throw const FormatException(
      'Movement detected. Settle into the position and try again.',
    );
  }
  return unitVector(mean);
}

class CalibrationStore {
  CalibrationStore(this.directoryProvider);
  final Future<Directory> Function()? directoryProvider;
  Future<File> get file async {
    final root =
        await (directoryProvider ?? getApplicationDocumentsDirectory)();
    return File(
      '${root.path}/desired_state_settings/posture_calibrations.json',
    );
  }

  Future<List<PostureCalibration>> load() async {
    final source = await file;
    if (!await source.exists()) {
      return [];
    }
    final json =
        jsonDecode(await source.readAsString()) as Map<String, dynamic>;
    if (json['schema_version'] != 1 || json['calibrations'] is! List) {
      throw const FormatException('Unsupported calibration collection');
    }
    return (json['calibrations'] as List)
        .map((v) => PostureCalibration.fromJson(v as Map<String, dynamic>))
        .toList();
  }

  Future<void> save(PostureCalibration calibration) async {
    final existing = await load();
    final destination = await file;
    await destination.parent.create(recursive: true);
    await destination.writeAsString(
      '${jsonEncode({
        'schema_version': 1,
        'calibrations': [...existing.where((v) => v.id != calibration.id), calibration].map((v) => v.toJson()).toList(),
      })}\n',
      flush: true,
    );
  }
}
