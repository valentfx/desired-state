import 'dart:io';

import 'package:archive/archive.dart';

/// A portable snapshot; includes originals plus optional append-only edits.
Future<File> exportSessionDirectory(Directory directory) async {
  final name = directory.uri.pathSegments.where((part) => part.isNotEmpty).last;
  final archive = Archive();
  for (final fileName in const [
    'manifest.json',
    'events.jsonl',
    'measurements.jsonl',
    'rr.jsonl',
    'marker_notes.jsonl',
    'history_edits.jsonl',
    'processing_views.jsonl',
  ]) {
    final file = File('${directory.path}/$fileName');
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    final bytes = await file.readAsBytes();
    archive.addFile(ArchiveFile('$name/$fileName', bytes.length, bytes));
  }
  final exports = Directory(
    '${directory.parent.parent.path}/desired_state_exports',
  );
  await exports.create(recursive: true);
  return File('${exports.path}/$name.zip')
      .writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
}
