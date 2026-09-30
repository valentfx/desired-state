import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

String newMarkerId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

class QuickMarkerDefinition {
  const QuickMarkerDefinition(this.id, this.label);
  final String id;
  final String label;
  Map<String, String> toJson() => {'id': id, 'label': label};
}

/// App-wide definitions, separate from immutable event label snapshots.
class QuickMarkerStore extends ChangeNotifier {
  QuickMarkerStore({this.directoryProvider});
  final Future<Directory> Function()? directoryProvider;
  List<QuickMarkerDefinition> _items = [];
  List<QuickMarkerDefinition> get items => List.unmodifiable(_items);
  bool ready = false;
  bool saving = false;
  String? error;
  bool _disposed = false;
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  File? _file;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() => _loading ??= _load();

  Future<void> retryLoad() {
    if (ready) return Future.value();
    _loading = null;
    return load();
  }

  Future<void> _load() async {
    error = null;
    try {
      final root =
          await (directoryProvider ?? getApplicationDocumentsDirectory)();
      _file = File('${root.path}/desired_state_settings/quick_markers.json');
      if (await _file!.exists()) {
        final json = jsonDecode(await _file!.readAsString());
        if (json is! Map ||
            json['schema_version'] != 1 ||
            json['markers'] is! List) {
          throw const FormatException('Unsupported marker settings');
        }
        final items = <QuickMarkerDefinition>[];
        for (final row in json['markers']) {
          if (row is! Map ||
              row['id'] is! String ||
              row['label'] is! String ||
              (row['id'] as String).isEmpty) {
            throw const FormatException('Invalid marker definition');
          }
          final label = _label(row['label'] as String);
          if (items.any(
            (item) =>
                item.id == row['id'] ||
                item.label.toLowerCase() == label.toLowerCase(),
          )) {
            throw const FormatException('Duplicate marker definition');
          }
          items.add(QuickMarkerDefinition(row['id'] as String, label));
        }
        _items = items;
      } else {
        _items = const [
          QuickMarkerDefinition('starter-anxious', 'Anxious'),
          QuickMarkerDefinition('starter-palpitations', 'Palpitations'),
          QuickMarkerDefinition('starter-dizzy', 'Dizzy'),
          QuickMarkerDefinition('starter-breath-hold', 'Breath hold'),
        ];
        await _persist(_items);
      }
      ready = true;
    } catch (failure) {
      // Never replace unreadable/unknown-version settings with defaults.
      error = 'Could not load quick markers: $failure';
    }
    _changed();
  }

  String _label(String input) {
    final label = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (label.isEmpty || label.runes.length > 48) {
      throw const FormatException('Use a label of 1–48 characters.');
    }
    return label;
  }

  Future<void> _persist(List<QuickMarkerDefinition> items) async {
    final file = _file!;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schema_version': 1,
        'markers': items.map((item) => item.toJson()).toList(),
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<void> _mutate(
    List<QuickMarkerDefinition> Function(List<QuickMarkerDefinition>) edit,
  ) {
    final operation = _writes.then((_) async {
      await load();
      if (!ready) throw StateError(error ?? 'Markers are not loaded');
      saving = true;
      _changed();
      try {
        final next = edit(List.of(_items));
        await _persist(next);
        _items = next;
      } finally {
        saving = false;
        _changed();
      }
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> add(String label) => _mutate((items) {
    final name = _uniqueLabel(items, label);
    return [...items, QuickMarkerDefinition(newMarkerId(), name)];
  });

  String _uniqueLabel(
    List<QuickMarkerDefinition> items,
    String input, {
    String? exceptId,
  }) {
    final label = _label(input);
    if (items.any(
      (item) =>
          item.id != exceptId &&
          item.label.toLowerCase() == label.toLowerCase(),
    )) {
      throw const FormatException('A button with that label already exists.');
    }
    return label;
  }

  Future<void> rename(String id, String label) => _mutate((items) {
    final name = _uniqueLabel(items, label, exceptId: id);
    final index = items.indexWhere((item) => item.id == id);
    if (index < 0) throw StateError('Marker no longer exists');
    items[index] = QuickMarkerDefinition(id, name);
    return items;
  });

  Future<void> remove(String id) =>
      _mutate((items) => items.where((item) => item.id != id).toList());

  Future<void> move(String id, int offset) => _mutate((items) {
    final index = items.indexWhere((item) => item.id == id);
    if (index < 0) throw StateError('Marker no longer exists');
    final destination = (index + offset).clamp(0, items.length - 1);
    items.insert(destination, items.removeAt(index));
    return items;
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class RecordedMarker {
  const RecordedMarker({
    required this.id,
    required this.sessionId,
    required this.label,
    required this.timestamp,
  });
  final String id;
  final String sessionId;
  final String label;
  final DateTime timestamp;
}
