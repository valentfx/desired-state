import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

const desiredStateBackend = 'https://valentfx.com/desired-state-api/index.php';

class UploadCancelled implements Exception {
  @override
  String toString() =>
      'Upload paused. Retry to resume verified server offsets.';
}

class UploadControl {
  bool cancelled = false;
  void check() {
    if (cancelled) throw UploadCancelled();
  }
}

class UploadApiException implements Exception {
  UploadApiException(this.status);
  final int status;
  @override
  String toString() => switch (status) {
    401 => 'Upload token rejected. Check the private Windows credential.',
    413 => 'Server storage allowance or file-size limit reached.',
    422 => 'Server integrity check failed. Originals remain on this PC.',
    _ => 'Upload request failed (HTTP $status). Retry to resume.',
  };
}

abstract class UploadApi {
  Future<Map<String, dynamic>> call(
    String action, {
    String? uploadId,
    Map<String, dynamic>? json,
    List<int>? bytes,
    int? offset,
  });
}

class HttpUploadApi implements UploadApi {
  HttpUploadApi(String token) : _token = token.trim() {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(_token)) {
      throw const FormatException('Invalid upload credential');
    }
  }
  final String _token;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 20);
  void close() => _client.close(force: true);

  @override
  Future<Map<String, dynamic>> call(
    String action, {
    String? uploadId,
    Map<String, dynamic>? json,
    List<int>? bytes,
    int? offset,
  }) async {
    final uri = Uri.parse(desiredStateBackend)
        .replace(queryParameters: {'action': action, 'upload_id': ?uploadId});
    // Never follow redirects with a credential, and keep TLS verification on.
    final method = action == 'health' || action == 'status' ? 'GET' : 'POST';
    try {
      return await (() async {
        final request = await _client.openUrl(method, uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
        if (json != null) {
          final data = utf8.encode(jsonEncode(json));
          request.headers.contentType = ContentType.json;
          request.contentLength = data.length;
          request.add(data);
        } else if (bytes != null) {
          request.headers.contentType = ContentType.binary;
          request.contentLength = bytes.length;
          request.headers.set('X-Upload-Offset', '$offset');
          request.headers.set(
            'X-Chunk-Sha256',
            sha256.convert(bytes).toString(),
          );
          request.add(bytes);
        } else if (method == 'POST') {
          request.contentLength = 0;
        }
        final response = await request.close();
        final data = <int>[];
        await for (final chunk in response) {
          data.addAll(chunk);
          if (data.length > 65536) {
            throw const FormatException('Oversized backend response');
          }
        }
        if (response.statusCode != 200) {
          throw UploadApiException(response.statusCode);
        }
        final decoded = jsonDecode(utf8.decode(data));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Invalid backend response');
        }
        return decoded;
      })().timeout(const Duration(seconds: 150));
    } on UploadApiException {
      rethrow;
    } on FormatException {
      rethrow;
    } catch (_) {
      // No raw request/response objects, token or server text in UI errors.
      throw const HttpException(
        'Backend connection interrupted; retry to resume',
      );
    }
  }
}

class UploadFile {
  const UploadFile(this.name, this.path, this.bytes, this.hash);
  final String name, path, hash;
  final int bytes;
}

class UploadSnapshot {
  UploadSnapshot(this.directory, this.manifest, this.files);
  final Directory directory;
  final Map<String, dynamic> manifest;
  final List<UploadFile> files;
  String get sessionId => manifest['session_id'] as String;
  int get totalBytes => files.fold(0, (total, file) => total + file.bytes);
  Future<void> dispose() => directory.delete(recursive: true);
}

Future<UploadSnapshot> snapshotUpload(String sourcePath) =>
    Isolate.run(() => snapshotUploadWorker(sourcePath));

Future<UploadSnapshot> snapshotUploadWorker(String sourcePath) async {
  final source = Directory(sourcePath);
  if (await FileSystemEntity.type(sourcePath, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FormatException('Select a regular session directory');
  }
  final originals = <File>[];
  await for (final entity in source.list(followLinks: false)) {
    final name = entity.uri.pathSegments.where((p) => p.isNotEmpty).last;
    if (name.endsWith('.json') || name.endsWith('.jsonl')) {
      if (entity is! File ||
          !RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,116}\.jsonl?$')
              .hasMatch(name)) {
        throw const FormatException('Unsafe session file');
      }
      originals.add(entity);
    }
  }
  originals.sort((a, b) => a.path.compareTo(b.path));
  final manifestFile = File('$sourcePath/manifest.json');
  if (await manifestFile.length() > 2097152) {
    throw const FormatException('Manifest is too large');
  }
  final manifest = jsonDecode(await manifestFile.readAsString());
  if (manifest is! Map<String, dynamic> ||
      manifest['schema_version'] != 1 ||
      manifest['session_id'] is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(manifest['session_id'])) {
    throw const FormatException('Unsupported session manifest');
  }
  var ended = false;
  final events = File('$sourcePath/events.jsonl');
  await for (final line
      in events
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final row = jsonDecode(line);
    if (row is! Map) throw const FormatException('Unreadable session events');
    if (row['event'] == 'session_ended') ended = true;
  }
  if (!ended) {
    throw StateError(
      'Only completed sessions can be uploaded. Stop recording first.',
    );
  }
  final stage = await Directory.systemTemp.createTemp('desired-state-upload-');
  final before = <String, FileStat>{};
  final files = <UploadFile>[];
  try {
    for (final original in originals) {
      final stat = await original.stat();
      before[original.path] = stat;
      if (stat.size > 4294967296) {
        throw const FormatException(
          'A session file exceeds the server 4 GiB limit',
        );
      }
      final name = original.uri.pathSegments.last;
      final copy = File('${stage.path}/$name');
      await original.copy(copy.path);
      final digest = await sha256.bind(copy.openRead()).first;
      files.add(UploadFile(name, copy.path, await copy.length(), '$digest'));
    }
    final currentNames = <String>{};
    await for (final entity in source.list(followLinks: false)) {
      if (entity.path.endsWith('.json') || entity.path.endsWith('.jsonl')) {
        currentNames.add(entity.path);
      }
    }
    if (currentNames.length != originals.length ||
        originals.any((f) => !currentNames.contains(f.path))) {
      throw StateError(
        'Session changed while preparing upload. Retry after edits finish.',
      );
    }
    for (final original in originals) {
      final after = await original.stat();
      final old = before[original.path]!;
      if (after.type != FileSystemEntityType.file ||
          after.size != old.size ||
          after.modified != old.modified ||
          await FileSystemEntity.type(original.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw StateError(
          'Session changed while preparing upload. Retry after edits finish.',
        );
      }
    }
    final captured = jsonDecode(
      await File('${stage.path}/manifest.json').readAsString(),
    );
    if (jsonEncode(captured) != jsonEncode(manifest)) {
      throw StateError('Manifest changed while preparing upload');
    }
    return UploadSnapshot(stage, manifest, files);
  } catch (_) {
    await stage.delete(recursive: true);
    rethrow;
  }
}

class UploadProgress {
  const UploadProgress(
    this.file,
    this.completed,
    this.total,
    this.verified,
    this.fileCount,
  );
  final String file;
  final int completed, total, verified, fileCount;
}

class BackendUploader {
  BackendUploader(this.api, {this.maxChunkBytes = 2 * 1024 * 1024});
  final UploadApi api;
  final int maxChunkBytes;

  int _offset(Map<String, dynamic> row, int length) {
    final value = row['offset'];
    if (value is! int || value < 0 || value > length) {
      throw const FormatException('Invalid backend offset');
    }
    return value;
  }

  Future<Map<String, dynamic>> upload(
    UploadSnapshot snapshot, {
    required UploadControl control,
    required void Function(UploadProgress) onProgress,
  }) async {
    control.check();
    final health = await api.call('health');
    if (health['api_version'] != 1 ||
        health['schema_version'] != 1 ||
        health['database'] != 'ready') {
      throw const FormatException('Unsupported backend version');
    }
    final session = await api.call(
      'session',
      json: {'manifest': snapshot.manifest},
    );
    if (session['session_id'] != snapshot.sessionId) {
      throw const FormatException('Backend session identity mismatch');
    }
    var completed = 0, verified = 0;
    final receipts = <Map<String, dynamic>>[];
    for (final file in snapshot.files) {
      control.check();
      final init = await api.call(
        'file',
        json: {
          'session_id': snapshot.sessionId,
          'file_name': file.name,
          'bytes': file.bytes,
          'sha256': file.hash,
        },
      );
      final id = init['upload_id'];
      final serverLimit = init['chunk_bytes'];
      if (id is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
          serverLimit is! int ||
          serverLimit < 1 ||
          maxChunkBytes < 1) {
        throw const FormatException('Invalid backend upload metadata');
      }
      var offset = _offset(init, file.bytes), attempts = 0;
      final reader = await File(file.path).open();
      try {
        while (offset < file.bytes) {
          control.check();
          onProgress(
            UploadProgress(
              file.name,
              completed + offset,
              snapshot.totalBytes,
              verified,
              snapshot.files.length,
            ),
          );
          await reader.setPosition(offset);
          final bytes = await reader.read(
            math.min(math.min(serverLimit, maxChunkBytes), file.bytes - offset),
          );
          if (bytes.isEmpty) {
            throw const FileSystemException('Upload snapshot is incomplete');
          }
          try {
            final response = await api.call(
              'chunk',
              uploadId: id,
              bytes: bytes,
              offset: offset,
            );
            final next = _offset(response, file.bytes);
            if (next != offset + bytes.length) {
              throw const FormatException('Unexpected backend acknowledgment');
            }
            offset = next;
            attempts = 0;
          } catch (e) {
            if (e is UploadApiException && e.status != 409 && e.status < 500) {
              rethrow;
            }
            if (e is FormatException || ++attempts > 3) rethrow;
            control.check();
            final status = await api.call('status', uploadId: id);
            final next = _offset(status, file.bytes);
            if (next > offset) attempts = 0;
            offset = next;
          }
        }
      } finally {
        await reader.close();
      }
      control.check();
      final finish = await api.call('finish', uploadId: id);
      final status = await api.call('status', uploadId: id);
      if (finish['status'] != 'verified' ||
          finish['sha256'] != file.hash ||
          status['status'] != 'verified' ||
          _offset(status, file.bytes) != file.bytes) {
        throw const FormatException('Backend file verification mismatch');
      }
      verified++;
      completed += file.bytes;
      receipts.add({
        'file_name': file.name,
        'bytes': file.bytes,
        'sha256': file.hash,
        'upload_id': id,
        'status': 'verified',
      });
      onProgress(
        UploadProgress(
          file.name,
          completed,
          snapshot.totalBytes,
          verified,
          snapshot.files.length,
        ),
      );
    }
    return {
      'schema_version': 1,
      'session_id': snapshot.sessionId,
      'account_id': session['account_id'],
      'endpoint': desiredStateBackend,
      'verified_utc': DateTime.now().toUtc().toIso8601String(),
      'files': receipts,
      'total_bytes': completed,
      'verification_scope': 'each_original_file; not_atomic_session_revision',
    };
  }
}

Future<String> readWindowsUploadToken() async {
  if (!Platform.isWindows) {
    throw UnsupportedError('Windows upload credential required');
  }
  // DPAPI: bound to the current Windows user. The script never prints secrets to
  // a terminal; this captured stdout stays inside the app process.
  const script = r'''
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Security
$p=Join-Path $env:LOCALAPPDATA 'DesiredState\backend-token.dpapi'
$b=[IO.File]::ReadAllBytes($p)
$t=[Security.Cryptography.ProtectedData]::Unprotect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
[Console]::Out.Write([Text.Encoding]::UTF8.GetString($t))
''';
  final system = Platform.environment['SystemRoot'];
  if (system == null) throw StateError('Windows system directory unavailable');
  final result = await Process.run(
    '$system/System32/WindowsPowerShell/v1.0/powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', script],
  );
  final token = '${result.stdout}'.trim();
  if (result.exitCode != 0 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
    throw StateError(
      'Upload credential missing. Run configure_backend_upload.ps1 first.',
    );
  }
  return token;
}
