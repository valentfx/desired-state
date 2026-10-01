import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'processing.dart';

/// Portable schema: a name plus the complete, validated processing snapshot.
/// No device paths or participant data belong in a preset.
class ProcessingPreset {
  ProcessingPreset(this.name, this.config) {
    if (name.trim().isEmpty || name.length > 64) {
      throw const FormatException(
        'Preset names must contain 1 to 64 characters',
      );
    }
    config.validate();
  }
  final String name;
  final ProcessingConfig config;
  String encode() => const JsonEncoder.withIndent('  ').convert({
    'preset_schema_version': 1,
    'name': name,
    'configuration': config.toJson(),
  });
  factory ProcessingPreset.decode(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (json['preset_schema_version'] != 1) {
      throw const FormatException('Unsupported preset version');
    }
    return ProcessingPreset(
      json['name'] as String,
      ProcessingConfig.fromJson(json['configuration'] as Map<String, dynamic>),
    );
  }
}

Future<ProcessingConfig> loadDefaultProcessing() async =>
    ProcessingConfig.fromJson(
      jsonDecode(await rootBundle.loadString('assets/processing_default.json'))
          as Map<String, dynamic>,
    );

class ProcessingPresets {
  ProcessingPresets({this.directoryProvider});
  final Future<Directory> Function()? directoryProvider;
  Future<File> _file() async {
    final root =
        await (directoryProvider ?? getApplicationDocumentsDirectory)();
    return File('${root.path}/desired_state_settings/presets.json');
  }

  Future<List<ProcessingPreset>> load() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['schema_version'] != 1) {
      throw const FormatException('Unsupported preset library');
    }
    return [
      for (final item in json['presets'] as List)
        ProcessingPreset.decode(jsonEncode(item)),
    ];
  }

  Future<void> _writes = Future.value();
  Future<void> save(ProcessingPreset preset) {
    final operation = _writes.then((_) async {
      if (['default', 'unfiltered'].contains(preset.name.toLowerCase())) {
        throw const FormatException(
          'Choose a custom name; built-ins are read-only',
        );
      }
      final items = await load(); // Preserve corrupt/future files by refusing to overwrite.
      if (items.any((p) => p.name.toLowerCase() == preset.name.toLowerCase())) {
        throw const FormatException(
          'Name already exists; save with a new name',
        );
      }
      items.add(preset);
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'schema_version': 1,
          'presets': [for (final item in items) jsonDecode(item.encode())],
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    });
    _writes = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }
}
