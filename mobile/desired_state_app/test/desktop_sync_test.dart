import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/desktop_sync.dart';

void main() {
  late Directory temporary;
  late Map<String, String> phone;
  var copies = 0;
  var mutate = false;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('phone-sync-test-');
    copies = 0;
    mutate = false;
    phone = {
      'manifest.json': jsonEncode({
        'schema_version': 1,
        'session_id': 'overnight',
        'started_utc': '2026-10-04T04:46:46Z',
      }),
      'events.jsonl': '{"event":"session_started"}\n',
      'rr.jsonl': '{"rr_ms":1000}\n',
    };
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  Future<String> command(List<String> args) async {
    final name = args.last.split('/').last;
    if (args.first == 'ls') {
      return name == 'desired_state_sessions'
          ? 'overnight\n'
          : '${phone.keys.join('\n')}\n';
    }
    if (args.first == 'cat') {
      return phone[name]!;
    }
    if (args.first == 'sha256sum') {
      return '${sha256.convert(utf8.encode(phone[name]!))}  ${args.last}\n';
    }
    throw StateError('Unexpected transport command');
  }

  Future<void> copy(String remote, String local) async {
    copies++;
    final name = remote.split('/').last;
    await File(local).writeAsString(phone[name]!);
    if (mutate && name == 'rr.jsonl') {
      phone[name] = '${phone[name]}{"rr_ms":1100}\n';
    }
  }

  Future<List<String>> sync() => syncDesktopPhone(
    '${temporary.path}/desired_state_sessions',
    phoneCommand: command,
    copyPhoneFile: copy,
    sourceDevice: 'fake-device',
  );
  test('stable unfinished overnight session imports; repeat avoids copying; completion retains revision', () async {
    final first = await sync();
    expect(first.single, contains('incomplete_snapshot'));
    expect(
      await File('${temporary.path}/desired_state_sessions/overnight/rr.jsonl')
          .readAsString(),
      phone['rr.jsonl'],
    );
    final copied = copies;
    expect((await sync()).single, contains('already current'));
    expect(copies, copied);
    phone['events.jsonl'] =
        '${phone['events.jsonl']}{"event":"session_ended"}\n';
    phone['rr.jsonl'] = '${phone['rr.jsonl']}{"rr_ms":900}\n';
    expect((await sync()).single, contains('finalized'));
    final catalog = await readDesktopCatalog(
      File('${temporary.path}/catalog.json'),
    );
    expect((catalog['sessions'] as Map)['overnight']['status'], 'finalized');
    final revisions = await Directory('${temporary.path}/revisions/overnight')
        .list()
        .toList();
    expect(revisions, hasLength(1));
    expect(
      await File('${revisions.single.path}/events.jsonl').readAsString(),
      '{"event":"session_started"}\n',
    );
    expect(await File('${temporary.path}/sync_report.json').exists(), true);
  });
  test('source growing during copy is rejected without publishing or losing prior snapshot', () async {
    await sync();
    final original = await File(
      '${temporary.path}/desired_state_sessions/overnight/rr.jsonl',
    ).readAsString();
    phone['rr.jsonl'] = '${phone['rr.jsonl']}{"rr_ms":950}\n';
    mutate = true;
    expect((await sync()).single, contains('changed during copy'));
    expect(
      await File('${temporary.path}/desired_state_sessions/overnight/rr.jsonl')
          .readAsString(),
      original,
    );
  });
  test('new growing session is rejected and staging is cleaned', () async {
    mutate = true;
    expect((await sync()).single, contains('changed during copy'));
    expect(
      await Directory('${temporary.path}/desired_state_sessions/overnight')
          .exists(),
      false,
    );
    expect(
      (await temporary.list().toList()).any(
        (e) => e.path.contains('.desired-state-sync-'),
      ),
      false,
    );
  });
}
