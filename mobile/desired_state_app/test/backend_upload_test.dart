import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desired_state_app/backend_upload.dart';

class FakeUploadApi implements UploadApi {
  final files = <String, Map<String, dynamic>>{};
  final data = <String, List<int>>{};
  final verified = <String>{};
  bool dropAckOnce = false, badHash = false, badOffset = false;
  int chunkCalls = 0, registrations = 0;

  @override
  Future<Map<String, dynamic>> call(
    String action, {
    String? uploadId,
    Map<String, dynamic>? json,
    List<int>? bytes,
    int? offset,
  }) async {
    if (action == 'health') {
      return {'api_version': 1, 'schema_version': 1, 'database': 'ready'};
    }
    if (action == 'session') {
      return {
        'session_id': json!['manifest']['session_id'],
        'account_id': 'owner',
      };
    }
    if (action == 'file') {
      registrations++;
      final key = '${json!['file_name']}:${json['sha256']}';
      final prior = files.entries.where((e) => e.value['key'] == key).toList();
      final id = prior.isEmpty
          ? (files.length + 1).toRadixString(16).padLeft(32, '0')
          : prior.single.key;
      files.putIfAbsent(id, () => {...json, 'key': key});
      data.putIfAbsent(id, () => []);
      return {
        'upload_id': id,
        'offset': badOffset ? json['bytes'] + 1 : data[id]!.length,
        'chunk_bytes': 17,
        'status': verified.contains(id) ? 'verified' : 'pending',
      };
    }
    final id = uploadId!;
    if (action == 'status') {
      return {
        'offset': data[id]!.length,
        'status': verified.contains(id) ? 'verified' : 'uploading',
      };
    }
    if (action == 'chunk') {
      chunkCalls++;
      if (offset != data[id]!.length) throw UploadApiException(409);
      data[id]!.addAll(bytes!);
      if (dropAckOnce) {
        dropAckOnce = false;
        throw const HttpException('Lost acknowledgment');
      }
      return {'offset': data[id]!.length};
    }
    if (action == 'finish') {
      if (data[id]!.length != files[id]!['bytes'] ||
          sha256.convert(data[id]!).toString() != files[id]!['sha256']) {
        throw UploadApiException(422);
      }
      verified.add(id);
      return {
        'status': 'verified',
        'sha256': badHash ? 'wrong' : files[id]!['sha256'],
      };
    }
    throw StateError('Unexpected test action');
  }
}

void main() {
  late Directory root;
  late Directory session;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('backend-upload-test-');
    session = await Directory('${root.path}/test_session').create();
    await File('${session.path}/manifest.json').writeAsString(
      jsonEncode({
        'schema_version': 1,
        'session_id': 'test_session',
        'participant_id': 'person_1',
      }),
    );
    await File('${session.path}/events.jsonl')
        .writeAsString('{"event":"session_ended"}\n');
    await File('${session.path}/state_feedback.jsonl')
        .writeAsString('{"note":"feel better ☀","value":0}\n');
    await File('${session.path}/rr.jsonl').writeAsString(
      List.generate(40, (i) => '{"rr_ms":${800 + i}}').join('\n'),
    );
    await File('${session.path}/empty.jsonl').writeAsString('');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('snapshot and lost-ack resume preserve every original byte, including zero-length files', () async {
    final original = await File('${session.path}/rr.jsonl').readAsBytes();
    final snapshot = await snapshotUpload(session.path);
    try {
      final api = FakeUploadApi()..dropAckOnce = true;
      final progress = <UploadProgress>[];
      final receipt = await BackendUploader(api)
          .upload(snapshot, control: UploadControl(), onProgress: progress.add);
      expect(receipt['files'], hasLength(5));
      expect(api.verified, hasLength(5));
      for (final file in snapshot.files) {
        final entry = api.files.entries.singleWhere(
          (e) => e.value['file_name'] == file.name,
        );
        expect(api.data[entry.key], await File(file.path).readAsBytes());
        expect(sha256.convert(api.data[entry.key]!).toString(), file.hash);
      }
      expect(await File('${session.path}/rr.jsonl').readAsBytes(), original);
      expect(progress.last.completed, snapshot.totalBytes);
      expect(progress.last.verified, snapshot.files.length);
      final calls = api.chunkCalls;
      await BackendUploader(api)
          .upload(snapshot, control: UploadControl(), onProgress: (_) {});
      expect(api.chunkCalls, calls); // Same revision does not transfer twice.
      expect(jsonEncode(receipt), isNot(contains('Bearer')));
    } finally {
      await snapshot.dispose();
    }
  });

  test(
    'source edits after snapshot do not alter bytes selected for transfer',
    () async {
      final snapshot = await snapshotUpload(session.path);
      try {
        final captured = await File('${snapshot.directory.path}/rr.jsonl')
            .readAsBytes();
        await File('${session.path}/rr.jsonl')
            .writeAsString('later annotation');
        final api = FakeUploadApi();
        await BackendUploader(api)
            .upload(snapshot, control: UploadControl(), onProgress: (_) {});
        final entry = api.files.entries.singleWhere(
          (e) => e.value['file_name'] == 'rr.jsonl',
        );
        expect(api.data[entry.key], captured);
      } finally {
        await snapshot.dispose();
      }
    },
  );

  test('incomplete sessions and unreadable event journals are refused before registration', () async {
    await File('${session.path}/events.jsonl')
        .writeAsString('{"event":"session_started"}\n');
    await expectLater(snapshotUpload(session.path), throwsStateError);
    await File('${session.path}/events.jsonl').writeAsString('not json');
    await expectLater(snapshotUpload(session.path), throwsFormatException);
  });

  test('unsupported manifest is refused', () async {
    await File('${session.path}/manifest.json')
        .writeAsString('{"schema_version":2,"session_id":"test_session"}');
    await expectLater(snapshotUpload(session.path), throwsFormatException);
  });

  test('symlink session files are refused', () async {
    final link = Link('${session.path}/alias.jsonl');
    try {
      await link.create('${session.path}/rr.jsonl');
    } on FileSystemException {
      // Windows may require Developer Mode; skip only where the OS disallows links.
      return;
    }
    await expectLater(snapshotUpload(session.path), throwsFormatException);
  });

  test('invalid server offsets and wrong final hashes never produce a success receipt', () async {
    final snapshot = await snapshotUpload(session.path);
    try {
      await expectLater(
        BackendUploader(FakeUploadApi()..badOffset = true)
            .upload(snapshot, control: UploadControl(), onProgress: (_) {}),
        throwsFormatException,
      );
      await expectLater(
        BackendUploader(FakeUploadApi()..badHash = true)
            .upload(snapshot, control: UploadControl(), onProgress: (_) {}),
        throwsFormatException,
      );
    } finally {
      await snapshot.dispose();
    }
  });

  test('pause stops subsequent chunks and retry resumes', () async {
    final snapshot = await snapshotUpload(session.path);
    try {
      final api = FakeUploadApi();
      final control = UploadControl();
      await expectLater(
        BackendUploader(api).upload(
          snapshot,
          control: control,
          onProgress: (p) {
            control.cancelled = true;
          },
        ),
        throwsA(isA<UploadCancelled>()),
      );
      final receipt = await BackendUploader(api)
          .upload(snapshot, control: UploadControl(), onProgress: (_) {});
      expect(receipt['files'], hasLength(5));
    } finally {
      await snapshot.dispose();
    }
  });

  test('credentials reject invalid tokens without including their contents in errors', () {
    const secret = 'private-test-secret';
    try {
      HttpUploadApi(secret);
      fail('must reject');
    } catch (e) {
      expect('$e', isNot(contains(secret)));
    }
  });
}
