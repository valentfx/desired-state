import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const phonePackage = 'com.example.desired_state_app';

Future<String> _adbPath() async {
  final local = Platform.environment['LOCALAPPDATA'];
  if (local != null) {
    final candidate = '$local/Android/Sdk/platform-tools/adb.exe';
    if (await File(candidate).exists()) {
      return candidate;
    }
  }
  return 'adb';
}

Future<ProcessResult> _adb(String adb, List<String> args) async {
  final result = await Process.run(
    adb,
    args,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(const Duration(seconds: 60));
  if (result.exitCode != 0) {
    throw StateError('ADB failed: ${result.stderr}');
  }
  return result;
}

/// One authorized Android debug app. Originals and changed revisions are retained.
/// File hashes also form the manifest for a future content-addressed server upload.
Future<List<String>> syncDesktopPhone(
  String rootPath, {
  Future<String> Function(List<String>)? phoneCommand,
  Future<void> Function(String, String)? copyPhoneFile,
  String? sourceDevice,
}) async {
  if ((phoneCommand == null) != (copyPhoneFile == null)) {
    throw ArgumentError('Supply both phone transport operations');
  }
  final adb = phoneCommand == null ? await _adbPath() : '';
  final devices = phoneCommand == null
      ? (await _adb(adb, ['devices'])).stdout
            .toString()
            .split('\n')
            .where((line) => RegExp(r'^\S+\s+device\s*$').hasMatch(line.trim()))
            .map((line) => line.trim().split(RegExp(r'\s+')).first)
            .toList()
      : [sourceDevice ?? 'test-phone'];
  if (devices.length != 1) {
    throw StateError(
      'Connect one unlocked Android phone by USB and approve USB debugging. Found ${devices.length} authorized devices.',
    );
  }
  final device = devices.single;
  Future<String> command(List<String> args) async => phoneCommand != null
      ? await phoneCommand(args)
      : (await _adb(adb, [
          '-s',
          device,
          'exec-out',
          'run-as',
          phonePackage,
          ...args,
        ])).stdout.toString();
  final base = 'app_flutter/desired_state_sessions';
  List<String> safeNames(String text) => text
      .split(RegExp(r'\s+'))
      .where(
        (name) =>
            RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name) &&
            name != '.' &&
            name != '..',
      )
      .toList();
  List<String> sessions;
  try {
    sessions = safeNames(await command(['ls', '-1', base]));
  } catch (_) {
    throw StateError(
      'Cannot read the phone app storage. USB sync requires the installed debug build of Desired State and authorized USB debugging.',
    );
  }
  final root = Directory(rootPath);
  await root.create(recursive: true);
  final catalogFile = File('${root.parent.path}/catalog.json');
  final catalog = await readDesktopCatalog(catalogFile);
  final results = <String>[];
  for (final id in sessions) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      continue;
    }
    final remote = '$base/$id';
    Directory? stage;
    try {
      final manifestText = await command(['cat', '$remote/manifest.json']);
      final manifest = jsonDecode(manifestText) as Map<String, dynamic>;
      if (manifest['schema_version'] != 1 || manifest['session_id'] != id) {
        results.add('$id: unsupported manifest; skipped');
        continue;
      }
      final names =
          safeNames(await command(['ls', '-1', remote]))
              .where(
                (name) => name.endsWith('.json') || name.endsWith('.jsonl'),
              )
              .toList()
            ..sort();
      final hashes = <String, String>{};
      for (final name in names) {
        final digest = (await command(['sha256sum', '$remote/$name']))
            .trim()
            .split(RegExp(r'\s+'))
            .first;
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
          throw StateError('Phone checksum unavailable');
        }
        hashes[name] = digest;
      }
      final destination = Directory('$rootPath/$id');
      var unchanged = await destination.exists();
      if (unchanged) {
        final localNames = <String>[];
        await for (final entity in destination.list(followLinks: false)) {
          if (entity is File &&
              (entity.path.endsWith('.json') ||
                  entity.path.endsWith('.jsonl'))) {
            localNames.add(entity.uri.pathSegments.last);
          }
        }
        localNames.sort();
        unchanged = jsonEncode(localNames) == jsonEncode(names);
        for (final name in names) {
          final local = File('${destination.path}/$name');
          if (!await local.exists() ||
              (await sha256.bind(local.openRead()).first).toString() !=
                  hashes[name]) {
            unchanged = false;
            break;
          }
        }
      }
      Future<void> verifySource() async {
        // Verify the source is still the snapshot copied, including file membership.
        final afterNames =
            safeNames(await command(['ls', '-1', remote]))
                .where(
                  (name) => name.endsWith('.json') || name.endsWith('.jsonl'),
                )
                .toList()
              ..sort();
        if (jsonEncode(afterNames) != jsonEncode(names)) {
          throw StateError('Session changed during copy; retry');
        }
        for (final name in names) {
          if (!(await command(['sha256sum', '$remote/$name']))
              .startsWith(hashes[name]!)) {
            throw StateError('Session changed during copy; retry');
          }
        }
      }

      if (!unchanged) {
        stage = await root.parent.createTemp('.desired-state-sync-');
        for (final name in names) {
          if (copyPhoneFile != null) {
            await copyPhoneFile('$remote/$name', '${stage.path}/$name');
          } else {
            final process = await Process.start(adb, [
              '-s',
              device,
              'exec-out',
              'run-as',
              phonePackage,
              'cat',
              '$remote/$name',
            ]);
            final errors = process.stderr.transform(utf8.decoder).join();
            final sink = File('${stage.path}/$name').openWrite();
            try {
              await sink.addStream(process.stdout);
            } finally {
              await sink.close();
            }
            final code = await process.exitCode;
            final error = await errors;
            if (code != 0) {
              throw StateError('Copy failed: $error');
            }
          }
          final digest =
              (await sha256.bind(File('${stage.path}/$name').openRead()).first)
                  .toString();
          if (digest != hashes[name]) {
            throw StateError(
              'Session changed during copy; retry after recording/notes finish',
            );
          }
        }
        await verifySource();
        Directory? revision;
        if (await destination.exists()) {
          final revisions = Directory('${root.parent.path}/revisions/$id');
          await revisions.create(recursive: true);
          revision = await destination.rename(
            '${revisions.path}/${DateTime.now().microsecondsSinceEpoch}',
          );
        }
        try {
          await stage.rename(destination.path);
        } catch (_) {
          if (revision != null) {
            await revision.rename(destination.path);
          }
          rethrow;
        }
      }
      if (unchanged) {
        await verifySource();
      }
      final eventsFile = File('${destination.path}/events.jsonl');
      final snapshotEvents = await eventsFile.exists()
          ? await eventsFile.readAsString()
          : '';
      final status = desktopSnapshotStatus(snapshotEvents);
      (catalog['sessions'] as Map)[id] = {
        'source_device': device,
        'source_package': phonePackage,
        'synced_utc': DateTime.now().toUtc().toIso8601String(),
        'relative_directory': 'desired_state_sessions/$id',
        'files_sha256': hashes,
        'status': status,
        'consistency': 'source hashes checked before and after transfer',
      };
      await writeDesktopCatalog(catalogFile, catalog);
      results.add(
        '$id: ${unchanged ? 'already current' : 'copied and verified'} · $status',
      );
    } catch (e) {
      results.add('$id: $e');
    } finally {
      if (stage != null && await stage.exists()) {
        await stage.delete(recursive: true);
      }
    }
  }
  if (results.isEmpty) {
    results.add('No recorded sessions found.');
  }
  await File('${root.parent.path}/sync_report.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
      'source_device': device,
      'finished_utc': DateTime.now().toUtc().toIso8601String(),
      'results': results,
    }),
    flush: true,
  );
  return results;
}

/// Preserve a recoverable prior catalog if replacement is interrupted.
Future<void> writeDesktopCatalog(File file, Map<String, dynamic> value) async {
  final temporary = File('${file.path}.tmp');
  final backup = File('${file.path}.previous');
  await temporary.writeAsString(
    const JsonEncoder.withIndent('  ').convert(value),
    flush: true,
  );
  if (await backup.exists()) {
    await backup.delete();
  }
  if (await file.exists()) {
    await file.rename(backup.path);
  }
  try {
    await temporary.rename(file.path);
  } catch (_) {
    if (await backup.exists()) {
      await backup.rename(file.path);
    }
    rethrow;
  }
}

Future<Map<String, dynamic>> readDesktopCatalog(File file) async {
  final previous = File('${file.path}.previous');
  if (!await file.exists() && await previous.exists()) {
    await previous.copy(file.path);
  }
  if (!await file.exists()) {
    return {'schema_version': 1, 'sessions': <String, dynamic>{}};
  }
  final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  if (value['schema_version'] != 1 || value['sessions'] is! Map) {
    throw const FormatException(
      'Unsupported local catalog; existing catalog retained',
    );
  }
  return value;
}

Future<void> catalogDesktopImport(String path) async {
  final directory = Directory(path);
  final root = directory.parent.parent;
  final manifest = jsonDecode(
    await File('$path/manifest.json').readAsString(),
  ) as Map<String, dynamic>;
  final hashes = <String, String>{};
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is File) {
      hashes[entity.uri.pathSegments.last] =
          (await sha256.bind(entity.openRead()).first).toString();
    }
  }
  final file = File('${root.path}/catalog.json');
  final catalog = await readDesktopCatalog(file);
  (catalog['sessions'] as Map)[manifest['session_id']] = {
    'source': 'phone_zip_export',
    'imported_utc': DateTime.now().toUtc().toIso8601String(),
    'relative_directory': 'desired_state_sessions/${manifest['session_id']}',
    'files_sha256': hashes,
  };
  await writeDesktopCatalog(file, catalog);
}

String desktopSnapshotStatus(String events) {
  final ended = const LineSplitter().convert(events).any((line) {
    try {
      return (jsonDecode(line) as Map)['event'] == 'session_ended';
    } catch (_) {
      return false;
    }
  });
  return ended ? 'finalized' : 'incomplete_snapshot';
}
