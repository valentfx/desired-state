import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/upload_status.dart';

void main() {
  test('receipts detect same-length edits, missing and added files', () async {
    final root = await Directory.systemTemp.createTemp('upload-status-test-');
    final session = Directory('${root.path}/desired_state_sessions/example');
    await session.create(recursive: true);
    final data = File('${session.path}/rr.jsonl');
    await data.writeAsString('abc');
    try {
      expect(await readUploadStatus(session.path, 'example'), 'none');
      final folder = receiptFolder(session);
      await folder.create(recursive: true);
      await File('${folder.path}/example-1.json').writeAsString(
        jsonEncode({
          'session_id': 'example',
          'verified_utc': DateTime.now().toUtc().toIso8601String(),
          'files': [
            {
              'file_name': 'rr.jsonl',
              'bytes': 3,
              'sha256': sha256.convert(utf8.encode('abc')).toString(),
              'status': 'verified',
            },
          ],
        }),
      );
      expect(await readUploadStatus(session.path, 'example'), 'verified');
      await data.writeAsString('xyz');
      expect(await readUploadStatus(session.path, 'example'), 'changed');
      await data.writeAsString('abc');
      final extra = File('${session.path}/feedback.jsonl');
      await extra.writeAsString('{}');
      expect(await readUploadStatus(session.path, 'example'), 'changed');
      await extra.delete();
      await data.delete();
      expect(await readUploadStatus(session.path, 'example'), 'changed');
      await writeUploadState(session, 'example', 'paused');
      expect(await readUploadStatus(session.path, 'example'), 'paused');
      await writeUploadState(session, 'example', 'failed');
      expect(await readUploadStatus(session.path, 'example'), 'failed');
      await writeUploadState(session, 'example', 'uploading');
      expect(await readUploadStatus(session.path, 'example'), 'paused');
    } finally {
      await root.delete(recursive: true);
    }
  });
}
