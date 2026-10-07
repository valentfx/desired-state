import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

const uploadStatusLabels = {
  'none': 'Not uploaded',
  'checking': 'Checking upload status…',
  'uploading': 'Uploading',
  'paused': 'Upload paused',
  'failed': 'Upload failed — retry',
  'verified': 'Uploaded and verified',
  'changed': 'Changed since upload',
  'unknown': 'Upload status unavailable',
};

Directory receiptFolder(Directory session) =>
    Directory('${session.parent.parent.path}/upload-receipts');

Future<void> writeUploadState(
  Directory session,
  String id,
  String status,
) async {
  final folder = receiptFolder(session);
  await folder.create(recursive: true);
  final file = File('${folder.path}/$id-state.json');
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(
    jsonEncode({
      'session_id': id,
      'state': status,
      'updated_utc': DateTime.now().toUtc().toIso8601String(),
    }),
    flush: true,
  );
  if (await file.exists()) {
    await file.delete();
  }
  await temporary.rename(file.path);
}

Future<String> readUploadStatus(String path, String id) =>
    Isolate.run(() => readUploadStatusWorker(path, id));

// Local receipts record a prior server verification, not a live server audit.
// Hash every current JSON/JSONL file off the UI isolate. Size/mtime alone cannot
// detect edits that retain the same length or timestamps.
Future<String> readUploadStatusWorker(String path, String id) async {
  try {
    final session = Directory(path);
    final folder = receiptFolder(session);
    if (!await folder.exists()) {
      return 'none';
    }
    Map<String, dynamic>? latest;
    DateTime? latestTime;
    await for (final entity in folder.list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (entity is! File ||
          !name.startsWith('$id-') ||
          !name.endsWith('.json')) {
        continue;
      }
      final row = jsonDecode(await entity.readAsString());
      if (row is! Map<String, dynamic> || row['session_id'] != id) {
        continue;
      }
      final time = DateTime.tryParse(
        '${row['updated_utc'] ?? row['verified_utc']}',
      );
      if (time != null && (latestTime == null || time.isAfter(latestTime))) {
        latest = row;
        latestTime = time;
      }
    }
    if (latest == null) {
      return 'none';
    }
    final state = latest['state'];
    if (state == 'uploading') {
      return 'paused';
    } // Previous interrupted run.
    if (state == 'paused' || state == 'failed') {
      return state as String;
    }
    final rows = latest['files'];
    if (rows is! List || rows.isEmpty) {
      return 'unknown';
    }
    final expected = <String, Map>{};
    for (final row in rows) {
      if (row is! Map ||
          row['status'] != 'verified' ||
          row['file_name'] is! String ||
          row['sha256'] is! String) {
        return 'unknown';
      }
      expected[row['file_name'] as String] = row;
    }
    final seen = <String>{};
    await for (final entity in session.list(followLinks: false)) {
      final name = entity.uri.pathSegments.where((p) => p.isNotEmpty).last;
      if (!name.endsWith('.json') && !name.endsWith('.jsonl')) {
        continue;
      }
      final row = expected[name];
      if (entity is! File || row == null) {
        return 'changed';
      }
      final before = await entity.stat();
      if (before.size != row['bytes']) {
        return 'changed';
      }
      final digest = await sha256.bind(entity.openRead()).first;
      final after = await entity.stat();
      if ('$digest' != row['sha256'] ||
          before.size != after.size ||
          before.modified != after.modified) {
        return 'changed';
      }
      seen.add(name);
    }
    return seen.length == expected.length ? 'verified' : 'changed';
  } catch (_) {
    return 'unknown';
  }
}
