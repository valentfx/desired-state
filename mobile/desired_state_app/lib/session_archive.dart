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
    'o2ring_measurements.jsonl',
    'o2ring_raw.jsonl',
    'h10_accelerometer.jsonl',
    'h10_ecg.jsonl',
    'h10_pmd_raw.jsonl',
    'muse_eeg.jsonl',
    'muse_bands.jsonl',
    'marker_notes.jsonl',
    'history_edits.jsonl',
    'processing_views.jsonl',
    'analysis_reviews.jsonl',
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
