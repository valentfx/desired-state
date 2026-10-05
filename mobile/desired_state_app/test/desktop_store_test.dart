import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desired_state_app/desktop_store.dart';
import 'package:desired_state_app/desktop_sync.dart';

void main() {
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('desktop-review-test-');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  Future<File> zip(List<ArchiveFile> files) async {
    final archive = Archive();
    for (final file in files) {
      archive.addFile(file);
    }
    return File('${temporary.path}/input.zip')
        .writeAsBytes(ZipEncoder().encodeBytes(archive));
  }

  ArchiveFile manifest() => ArchiveFile.string(
    'session/manifest.json',
    jsonEncode({
      'schema_version': 1,
      'session_id': 'session',
      'started_utc': '2026-10-04T04:00:00Z',
    }),
  );
  test('import preserves bytes, rejects traversal and does not overwrite duplicates', () async {
    final input = await zip([
      manifest(),
      ArchiveFile.string('session/rr.jsonl', '{"rr_ms":900}\n'),
    ]);
    final root = '${temporary.path}/sessions';
    final path = await importDesktopZipWorker(input.path, root);
    expect(await File('$path/rr.jsonl').readAsString(), '{"rr_ms":900}\n');
    await expectLater(
      importDesktopZipWorker(input.path, root),
      throwsStateError,
    );
    final unsafe = await zip([
      manifest(),
      ArchiveFile.string('../outside.json', 'bad'),
    ]);
    await expectLater(
      importDesktopZipWorker(unsafe.path, root),
      throwsFormatException,
    );
    expect(await File('${temporary.path}/outside.json').exists(), false);
  });
  test('UTF-8 byte offsets resume on complete lines and include final unterminated row', () async {
    final file = await File('${temporary.path}/lines')
        .writeAsString('α\n{"x":1}\nlast');
    final lines = await desktopLines(file).toList();
    expect(lines.map((v) => v.$1), [0, 3, 11]);
    expect((await desktopLines(file, 3).toList()).first.$2, '{"x":1}');
    expect(lines.last.$2, 'last');
  });
  test('recorded RMSSD excludes rejected adjacency and restarts on continuity gaps', () {
    final decoder = DesktopDecoder();
    final data = <String, List<SignalPoint>>{};
    var time = 0.0;
    void rr(double value, bool accepted, [int segment = 1]) {
      decoder.decode(
        'rr',
        {
          'rr_ms': value,
          'artifact_accepted': accepted,
          'continuity_segment': segment,
        },
        time++,
        data,
        0,
        100,
      );
    }

    rr(1000, true);
    rr(1010, true);
    rr(1400, false);
    rr(1020, true);
    expect(data['RMSSD (ms, recorded screening)']!.last.$2, 10);
    rr(900, true, 2);
    expect(data['RMSSD (ms, recorded screening)']!.last.$2.isNaN, true);
    rr(910, true, 2);
    rr(920, true, 2);
    expect(data['RMSSD (ms, recorded screening)']!.last.$2, 10);
    time = 30;
    rr(930, true, 2);
    expect(data['RMSSD (ms, recorded screening)']!.last.$2.isNaN, true);
  });
  test('EEG missing channels and oxygen gaps remain unavailable', () {
    final data = <String, List<SignalPoint>>{};
    final decoder = DesktopDecoder();
    decoder.decode(
      'muse_bands',
      {
        'channels': {
          '1': {'Delta': 100, 'Theta': 20, 'Alpha': 10, 'Beta': 5},
        },
        'total_channels': 4,
      },
      1,
      data,
      0,
      30,
    );
    expect(data['EEG Delta (µV²)']!.single.$2.isNaN, true);
    decoder.decode('o2ring_measurements', {'spo2_percent': 95}, 1, data, 0, 30);
    decoder.decode(
      'o2ring_measurements',
      {'spo2_percent': 96},
      20,
      data,
      0,
      30,
    );
    expect(data['SpO2 (%)']![1].$2.isNaN, true);
  });
  test(
    'indexed waveform window retains original amplitudes in range',
    () async {
      final origin = DateTime.utc(2026, 10, 4);
      final file = File('${temporary.path}/h10_ecg.jsonl');
      await file.writeAsString(
        [
          for (var t = 1; t <= 180; t++)
            jsonEncode({
              'received_utc': origin
                  .add(Duration(seconds: t))
                  .toIso8601String(),
              'samples_uv': [t, -t],
              'sample_rate_hz': 2,
              'continuity_segment': 1,
            }),
        ].join('\n'),
      );
      final index = await indexDesktopSession(temporary.path, origin);
      expect(index.duration, 180);
      expect(index.overview, isEmpty);
      final result = await readDesktopWindow(index, 130, 132, true);
      final points = result.$1['ECG (µV)']!
          .where((p) => p.$2.isFinite)
          .toList();
      expect(points.map((p) => p.$2), [-130, 131, -131, 132, -132]);
      expect(points.every((p) => p.$1 >= 130 && p.$1 <= 132), true);
    },
  );
  test(
    'catalog recovers prior committed file after interrupted rename',
    () async {
      final file = File('${temporary.path}/catalog.json');
      await File('${file.path}.previous')
          .writeAsString('{"schema_version":1,"sessions":{"retained":{}}}');
      final value = await readDesktopCatalog(file);
      expect(value['sessions'], contains('retained'));
      expect(await file.exists(), true);
    },
  );
  test('catalog replacement retains previous completed revision', () async {
    final file = File('${temporary.path}/catalog.json');
    await writeDesktopCatalog(file, {
      'schema_version': 1,
      'sessions': {'first': {}},
    });
    await writeDesktopCatalog(file, {
      'schema_version': 1,
      'sessions': {'second': {}},
    });
    expect(
      (jsonDecode(await file.readAsString()) as Map)['sessions'],
      contains('second'),
    );
    expect(
      (jsonDecode(await File('${file.path}.previous').readAsString())
          as Map)['sessions'],
      contains('first'),
    );
  });
}
