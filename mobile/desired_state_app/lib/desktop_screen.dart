import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'desktop_store.dart';
import 'desktop_sync.dart';
import 'desktop_inspection.dart';
import 'session_history.dart';
import 'state_feedback_widgets.dart';

class DesktopScreen extends StatefulWidget {
  const DesktopScreen({super.key});
  @override
  State<DesktopScreen> createState() => _DesktopScreenState();
}

class _DesktopScreenState extends State<DesktopScreen> {
  String? _root, _error;
  List<HistoryEntry> _sessions = [];
  HistoryEntry? _entry;
  DesktopIndex? _index;
  Map<String, List<SignalPoint>> _data = {};
  List<String> _warnings = [];
  final Set<String> _hidden = {};
  bool _busy = false, _raw = false;
  double _start = 0, _end = 1;
  double? _cursor;
  RangeValues? _sliderRange;
  String _query = '';
  Timer? _inspectionTimer;
  int _inspectionGeneration = 0;
  bool _inspectionLoading = false;
  String? _inspectionError;
  Map<String, List<SignalPoint>> _inspectionData = {};
  final Map<String, String> _sessionDetails = {};
  @override
  void dispose() {
    _inspectionTimer?.cancel();
    _inspectionGeneration++;
    super.dispose();
  }

  void _clearInspection() {
    _inspectionTimer?.cancel();
    _inspectionGeneration++;
    _inspectionData = {};
    _inspectionLoading = false;
    _inspectionError = null;
    _sliderRange = null;
  }

  void _selectCursor(double cursor) {
    final index = _index;
    if (index == null || _busy) {
      return;
    }
    _inspectionTimer?.cancel();
    final generation = ++_inspectionGeneration;
    setState(() {
      _cursor = cursor;
      _inspectionData = {};
      _inspectionLoading = true;
      _inspectionError = null;
    });
    _inspectionTimer = Timer(const Duration(milliseconds: 150), () async {
      try {
        final result = await readDesktopWindow(
          index,
          math.max(0.0, cursor - 2),
          math.min(index.duration, cursor + 2),
          true,
        );
        if (mounted && generation == _inspectionGeneration) {
          setState(() {
            _inspectionData = result.$1;
            _inspectionLoading = false;
          });
        }
      } catch (e) {
        if (mounted && generation == _inspectionGeneration) {
          setState(() {
            _inspectionError = '$e';
            _inspectionLoading = false;
          });
        }
      }
    });
  }

  String _durationLabel(double seconds) {
    final value = seconds.round();
    return '${value ~/ 3600}h ${(value % 3600) ~/ 60}m ${value % 60}s';
  }

  String _details(HistoryEntry entry) {
    final times =
        entry.events
            .map((e) => DateTime.tryParse('${e['received_utc']}'))
            .whereType<DateTime>()
            .toList()
          ..sort();
    final end = times.isEmpty ? null : times.last;
    final elapsed = entry.started != null && end != null
        ? end.difference(entry.started!).inMilliseconds / 1000
        : null;
    return '${entry.participant}\n${entry.id}\nStart: ${entry.started?.toLocal()}\n${entry.ended ? 'End' : 'Last event'}: ${end?.toLocal() ?? 'Unknown'}\n${elapsed == null ? 'Duration unknown' : '${entry.ended ? 'Duration' : 'Event span'}: ${_durationLabel(elapsed)}'}\n${entry.ended ? 'Complete' : 'Incomplete snapshot'}\nDevices: ${entry.device}\n${_sessionDetails[entry.id] ?? 'Streams: loading file summary…'}\n${entry.metadata.description}';
  }

  Future<void> _loadDetails(List<HistoryEntry> entries) async {
    for (final entry in entries) {
      try {
        final signals = <String>[];
        var bytes = 0;
        await for (final file in entry.directory.list(followLinks: false)) {
          if (file is File) {
            final size = await file.length();
            bytes += size;
            final name = file.uri.pathSegments.last.replaceFirst('.jsonl', '');
            if (desktopStreams.contains(name) && size > 0) {
              signals.add(name);
            }
          }
        }
        if (mounted) {
          setState(
            () => _sessionDetails[entry.id] =
                'Data: ${(bytes / 1048576).toStringAsFixed(1)} MB\nStreams: ${signals.join(', ')}',
          );
        }
      } catch (_) {
        if (mounted) {
          setState(
            () => _sessionDetails[entry.id] = 'File summary unavailable',
          );
        }
      }
    }
  }

  Widget _cursorInspector() {
    final index = _index;
    if (index == null) {
      return const SizedBox.shrink();
    }
    final names = {
      ...desktopSignalNames(index),
      ..._data.keys,
      ..._inspectionData.keys,
    }.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Cursor values', style: Theme.of(context).textTheme.titleMedium),
        if (_cursor == null)
          const Text('Click or drag any plot to inspect every signal.'),
        if (_cursor != null) ...[
          Text(
            '${index.origin.add(Duration(milliseconds: (_cursor! * 1000).round())).toLocal()}',
          ),
          if (_inspectionLoading) const LinearProgressIndicator(),
          if (_inspectionError != null) Text(_inspectionError!),
          for (final name in names) _cursorRow(name),
          for (final event in _entry!.events.where(
            (e) =>
                e['event'] == 'marked_event' &&
                _eventTime(e) != null &&
                (_eventTime(e)! - _cursor!).abs() <= 10,
          ))
            Text(
              'Nearby marker: ${event['marker_label'] ?? event['description'] ?? 'Event'} · ${_time(_eventTime(event)!)}',
            ),
          const Text(
            'Nearest original samples; each row shows its sample time and offset. No interpolation. RR timestamps refer to received packets.',
          ),
        ],
        const Divider(),
      ],
    );
  }

  Widget _cursorRow(String name) {
    final value = inspectDesktopSignal(
      name,
      _inspectionData[name] ?? [],
      _cursor!,
    );
    final offset = value.sampleTime == null
        ? ''
        : ' · Δ ${(value.sampleTime! - _cursor!).toStringAsFixed(3)}s';
    final label = name
        .replaceAll('(ms, recorded screening)', '(ms)')
        .replaceAll('(ms, raw)', '(ms)');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 115,
                child: Text(
                  _inspectionLoading
                      ? 'Loading…'
                      : value.value == null
                      ? value.status
                      : value.value!.toStringAsFixed(3),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          if (!_inspectionLoading && value.sampleTime != null)
            Text(
              '${_time(value.sampleTime!)}$offset',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final documents = await getApplicationDocumentsDirectory();
      _root = '${documents.path}/desired_state_desktop/desired_state_sessions';
      await _reload();
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    }
  }

  Future<void> _reload() async {
    final repository = SessionHistoryRepository(
      directoryProvider: () async => Directory(_root!).parent,
    );
    final entries = await repository.list();
    if (mounted) {
      setState(() => _sessions = entries);
      unawaited(_loadDetails(entries));
    }
  }

  Future<void> _import() async {
    if (_busy || _root == null) {
      return;
    }
    final picked = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Session ZIP', extensions: ['zip']),
      ],
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? path;
    try {
      path = await importDesktopZip(picked.path, _root!);
      await catalogDesktopImport(path);
      await _reload();
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (path != null && mounted) {
      await _open(await readDesktopEntry(path));
    }
  }

  Future<void> _open(HistoryEntry entry) async {
    if (_busy || entry.started == null || !entry.readable) {
      return;
    }
    _clearInspection();
    setState(() {
      _busy = true;
      _error = null;
      _entry = entry;
      _index = null;
      _data = {};
      _cursor = null;
    });
    try {
      final index = await indexDesktopSession(
        entry.directory.path,
        entry.started!,
      );
      for (final event in entry.events) {
        final timestamp = DateTime.tryParse('${event['received_utc']}');
        if (timestamp != null) {
          index.duration = math.max(
            index.duration,
            timestamp.difference(entry.started!).inMicroseconds / 1000000,
          );
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _index = index;
        _raw = false;
        _start = 0;
        _end = index.duration;
        _data = index.overview;
        _warnings = [...entry.warnings, ...index.warnings];
        _hidden.clear();
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _range(double start, double end, {bool? raw}) async {
    final index = _index;
    if (_busy || index == null) {
      return;
    }
    _clearInspection();
    final showRaw = raw ?? _raw;
    final boundedEnd = end.clamp(0.001, index.duration).toDouble();
    final limitedStart = showRaw ? math.max(start, boundedEnd - 60) : start;
    final boundedStart = limitedStart
        .clamp(0.0, math.max(0.0, boundedEnd - .001))
        .toDouble();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await readDesktopWindow(
        index,
        boundedStart,
        boundedEnd,
        showRaw,
      );
      if (mounted) {
        setState(() {
          _start = boundedStart;
          _end = boundedEnd;
          _raw = showRaw;
          _data = result.$1;
          _cursor = null;
          _warnings = [..._entry!.warnings, ...index.warnings, ...result.$2];
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _overview() {
    if (_index == null || _busy) {
      return;
    }
    _clearInspection();
    setState(() {
      _raw = false;
      _start = 0;
      _end = _index!.duration;
      _data = _index!.overview;
      _cursor = null;
    });
  }

  void _zoom(double seconds) {
    final center = _cursor ?? (_start + _end) / 2;
    final duration = _index!.duration;
    final width = math.min(seconds, duration);
    final left = (center - width / 2)
        .clamp(0.0, math.max(0.0, duration - width))
        .toDouble();
    _range(left, left + width);
  }

  String _time(double seconds) {
    final origin = _entry?.started;
    if (origin == null) {
      return '';
    }
    final t = origin
        .add(Duration(milliseconds: (seconds * 1000).round()))
        .toLocal();
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  }

  double? _eventTime(Map<String, dynamic> event) {
    final time = DateTime.tryParse('${event['received_utc']}');
    return time == null || _entry?.started == null
        ? null
        : time.difference(_entry!.started!).inMicroseconds / 1000000;
  }

  Future<void> _saveReview() async {
    final entry = _entry;
    if (entry == null || _index == null) {
      return;
    }
    final location = await getSaveLocation(
      suggestedName: '${entry.id}-review.json',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Review JSON', extensions: ['json']),
      ],
    );
    if (location == null) {
      return;
    }
    try {
      final report = {
        'schema_version': 1,
        'session_id': entry.id,
        'created_utc': DateTime.now().toUtc().toIso8601String(),
        'selected_start_seconds': _start,
        'selected_end_seconds': _end,
        'streams': _index!.rows,
        'warnings': _warnings,
        'visible_signals': _data.keys
            .where((k) => !_hidden.contains(k))
            .toList(),
        'rr_method': 'latest 60 acquired RR; recorded acceptance; adjacent accepted pairs; continuity/receipt gaps reset',
        'timing': 'Host receipt UTC; batch waveform timing approximate',
        'purpose': 'Review metadata; raw samples not included or modified',
      };
      await File(location.path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Review saved')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    }
  }

  Future<void> _syncPhone() async {
    if (_busy || _root == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final selectedId = _entry?.id;
      final result = await syncDesktopPhone(_root!);
      await _reload();
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Phone sync results'),
            content: SingleChildScrollView(
              child: SelectableText(result.join('\n')),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ],
          ),
        );
      }
      if (selectedId != null && mounted) {
        final refreshed = _sessions.where((e) => e.id == selectedId).toList();
        setState(() => _busy = false);
        if (refreshed.isNotEmpty) {
          await _open(refreshed.first);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _showSyncReport() async {
    if (_root == null) {
      return;
    }
    try {
      final file = File('${Directory(_root!).parent.path}/sync_report.json');
      final report = await file.exists()
          ? await file.readAsString()
          : 'No sync report saved yet. Click Sync phone.';
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Last phone sync report'),
            content: SizedBox(
              width: 650,
              child: SingleChildScrollView(child: SelectableText(report)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    }
  }

  String _listDuration(HistoryEntry entry) {
    final times =
        entry.events
            .map((e) => DateTime.tryParse('${e['received_utc']}'))
            .whereType<DateTime>()
            .toList()
          ..sort();
    return entry.started == null || times.isEmpty
        ? 'duration unknown'
        : '${entry.ended ? '' : '≥ '}${_durationLabel(math.max(0.0, times.last.difference(entry.started!).inMilliseconds / 1000))}';
  }

  Widget _sessionList() => SizedBox(
    width: 245,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search sessions',
            ),
            onChanged: (v) => setState(() => _query = v.toLowerCase()),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final entry in _sessions)
                if ('${entry.id} ${entry.participant} ${entry.metadata.description}'
                    .toLowerCase()
                    .contains(_query))
                  Tooltip(
                    message: _details(entry),
                    waitDuration: const Duration(milliseconds: 400),
                    child: ListTile(
                      selected: entry.directory.path == _entry?.directory.path,
                      title: Text(entry.participant),
                      subtitle: Text(
                        '${entry.started?.toLocal().toString().split('.').first ?? entry.id}\n${entry.ended ? 'Complete' : 'Incomplete snapshot'} · ${_listDuration(entry)}\n${entry.metadata.description}',
                        maxLines: 4,
                      ),
                      trailing: entry.readable
                          ? null
                          : const Icon(Icons.warning_amber),
                      onTap: _busy ? null : () => _open(entry),
                    ),
                  ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _eventsPanel() => SizedBox(
    width: 300,
    child: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _cursorInspector(),
        Text('Session', style: Theme.of(context).textTheme.titleMedium),
        SelectableText(_details(_entry!)),
        if (_index != null)
          Text('Recorded span: ${_durationLabel(_index!.duration)}'),
        Text(_entry?.device ?? ''),
        Text(
          _entry!.ended
              ? 'Complete recording'
              : 'Incomplete snapshot · completion not recorded',
        ),
        if (_entry!.metadata.description.isNotEmpty)
          Text(_entry!.metadata.description),
        if (_entry!.metadata.notes.isNotEmpty) Text(_entry!.metadata.notes),
        const SizedBox(height: 16),
        Text(
          'Streams · readable rows',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        for (final count in _index?.rows.entries ?? <MapEntry<String, int>>[])
          Text('${count.key}: ${count.value}'),
        const SizedBox(height: 16),
        Text('Events', style: Theme.of(context).textTheme.titleMedium),
        for (final event in _entry!.events.where(
          (e) => e['event'] == 'marked_event',
        ))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${event['marker_label'] ?? event['event']}'),
            subtitle: Text(
              '${_eventTime(event) == null ? '' : _time(_eventTime(event)!)} ${event['description'] ?? ''}\n${_entry!.metadata.eventNotes[_entry!.eventId(event)] ?? ''}',
            ),
            onTap: _busy || _eventTime(event) == null
                ? null
                : () {
                    final t = _eventTime(event)!;
                    _range(
                      math.max(0, t - 15),
                      math.min(_index!.duration, t + 15),
                    );
                  },
          ),
        ExpansionTile(
          title: const Text('Technical events'),
          children: [
            for (final event in _entry!.events.where(
              (e) => e['event'] != 'marked_event',
            ))
              ListTile(
                title: Text('${event['event']}'),
                subtitle: Text('${event['received_utc']}'),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('${event['event']}'),
                    content: SingleChildScrollView(
                      child: SelectableText(
                        const JsonEncoder.withIndent('  ').convert(event),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        for (final warning in _warnings)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              warning,
              style: const TextStyle(color: Colors.deepOrange),
            ),
          ),
      ],
    ),
  );
  Widget _workspace() {
    final index = _index;
    if (index == null) {
      return Center(
        child: Text(
          _busy
              ? 'Indexing session streams…'
              : 'Import a phone session ZIP, then select a session.',
        ),
      );
    }
    final markers = _entry!.events
        .where((e) => e['event'] == 'marked_event')
        .map(_eventTime)
        .whereType<double>()
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: _busy ? null : _overview,
                child: const Text('Whole session'),
              ),
              for (final width in [10, 60, 300, 1800])
                OutlinedButton(
                  onPressed: _busy ? null : () => _zoom(width.toDouble()),
                  child: Text(width < 60 ? '${width}s' : '${width ~/ 60}m'),
                ),
              IconButton(
                tooltip: 'Earlier',
                onPressed: _busy
                    ? null
                    : () {
                        final width = _end - _start;
                        final left = math.max(0.0, _start - width * .8);
                        _range(left, left + width);
                      },
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: 'Later',
                onPressed: _busy
                    ? null
                    : () {
                        final width = _end - _start;
                        final right = math.min(
                          index.duration,
                          _end + width * .8,
                        );
                        _range(math.max(0, right - width), right);
                      },
                icon: const Icon(Icons.chevron_right),
              ),
              FilterChip(
                label: const Text('Raw ECG / EEG / motion'),
                selected: _raw,
                onSelected: _busy
                    ? null
                    : (v) {
                        if (v && _end - _start > 60) {
                          final center = _cursor ?? (_start + _end) / 2;
                          final left = math.max(0.0, center - 30);
                          _range(
                            left,
                            math.min(index.duration, left + 60),
                            raw: true,
                          );
                        } else {
                          _range(_start, _end, raw: v);
                        }
                      },
              ),
              Text('${_time(_start)} — ${_time(_end)}'),
            ],
          ),
        ),
        if (_raw)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Waveform detail · use 10s to inspect beats. Values use phone receipt timing, not synchronized device clocks.',
            ),
          ),
        RangeSlider(
          values: _sliderRange ?? RangeValues(_start, _end),
          min: 0,
          max: index.duration,
          onChanged: _busy ? null : (v) => setState(() => _sliderRange = v),
          onChangeEnd: (v) =>
              _range(v.start, _raw ? math.min(v.end, v.start + 60) : v.end),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 6,
            children: [
              for (final name in _data.keys)
                FilterChip(
                  label: Text(name),
                  selected: !_hidden.contains(name),
                  onSelected: (v) => setState(() {
                    if (v) {
                      _hidden.remove(name);
                    } else {
                      _hidden.add(name);
                    }
                  }),
                ),
            ],
          ),
        ),
        Expanded(
          child: Listener(
            onPointerSignal: (event) {
              if (event is PointerScrollEvent && !_busy) {
                _zoom((_end - _start) * (event.scrollDelta.dy > 0 ? 1.5 : .67));
              }
            },
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (_data.isEmpty) const Text('No samples in this range.'),
                for (final series in _data.entries)
                  if (!_hidden.contains(series.key))
                    DesktopSignalPlot(
                      title: series.key,
                      points: series.value,
                      start: _start,
                      end: _end,
                      cursor: _cursor,
                      markers: markers,
                      timeLabel: _time,
                      onCursor: _selectCursor,
                    ),
                const Text(
                  'Gaps remain gaps. EEG bands require every channel to pass the recorded screen. RMSSD uses recorded acceptance flags and is not ECG-validated. Overview plots preserve extrema through display reduction.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Desired State · Analyze'),
      actions: [
        IconButton(
          tooltip: 'State feedback',
          icon: const Icon(Icons.sentiment_satisfied_alt),
          onPressed: _busy || _entry == null
              ? null
              : () {
                  final entry = _entry!;
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SessionFeedbackScreen(
                        directory: entry.directory,
                        sessionId: entry.id,
                        allowWrite: false,
                      ),
                    ),
                  );
                },
        ),
        TextButton.icon(
          onPressed: _busy || _root == null ? null : _syncPhone,
          icon: const Icon(Icons.sync),
          label: const Text('Sync phone'),
        ),
        IconButton(
          tooltip: 'Last sync report',
          onPressed: _busy ? null : _showSyncReport,
          icon: const Icon(Icons.receipt_long),
        ),
        FilledButton.icon(
          onPressed: _busy || _root == null ? null : _import,
          icon: const Icon(Icons.file_open),
          label: const Text('Import session ZIP'),
        ),
        const SizedBox(width: 8),
        Builder(
          builder: (context) => IconButton(
            tooltip: 'Session events',
            onPressed: _index == null
                ? null
                : () => Scaffold.of(context).openEndDrawer(),
            icon: const Icon(Icons.list_alt),
          ),
        ),
        IconButton(
          tooltip: 'Save review',
          onPressed: _busy || _index == null ? null : _saveReview,
          icon: const Icon(Icons.save_alt),
        ),
      ],
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          MaterialBanner(
            content: SelectableText(_error!),
            actions: [
              TextButton(
                onPressed: () => setState(() => _error = null),
                child: const Text('Dismiss'),
              ),
            ],
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Row(
              children: [
                _sessionList(),
                const VerticalDivider(width: 1),
                Expanded(child: _workspace()),
                if (_entry != null &&
                    _index != null &&
                    constraints.maxWidth >= 1100) ...[
                  const VerticalDivider(width: 1),
                  _eventsPanel(),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
    endDrawer: _entry == null || _index == null
        ? null
        : Drawer(child: SafeArea(child: _eventsPanel())),
  );
}

class DesktopSignalPlot extends StatelessWidget {
  const DesktopSignalPlot({
    super.key,
    required this.title,
    required this.points,
    required this.start,
    required this.end,
    required this.cursor,
    required this.markers,
    required this.timeLabel,
    required this.onCursor,
  });
  final String title;
  final List<SignalPoint> points;
  final double start, end;
  final double? cursor;
  final List<double> markers;
  final String Function(double) timeLabel;
  final ValueChanged<double> onCursor;
  @override
  Widget build(BuildContext context) {
    final finite = points.where((p) => p.$2.isFinite).toList();
    double low = 0, high = 1;
    if (finite.isNotEmpty) {
      low = finite.map((v) => v.$2).reduce(math.min);
      high = finite.map((v) => v.$2).reduce(math.max);
    }
    final inspected = cursor == null
        ? null
        : inspectDesktopSignal(title, points, cursor!);
    final inspectedValue = inspected?.value;
    final inspectedTime = inspected?.sampleTime;
    final nearest = inspectedValue != null && inspectedTime != null
        ? (inspectedTime, inspectedValue)
        : null;
    final color = title.startsWith('SpO2')
        ? Colors.teal
        : title.contains('RMSSD')
        ? Colors.orange
        : title.contains('EEG')
        ? Colors.purple
        : Colors.blue;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$title${nearest == null ? (cursor == null ? '' : ' · No usable sample at cursor') : ' · ${timeLabel(nearest.$1)}: ${nearest.$2.toStringAsFixed(2)}'}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (finite.isEmpty)
              const Text('No usable samples; signal withheld or absent.'),
            SizedBox(
              height: 170,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  void select(Offset position) => onCursor(
                    start +
                        ((position.dx - 65) /
                                    math.max(1, constraints.maxWidth - 130))
                                .clamp(0.0, 1.0) *
                            (end - start),
                  );
                  return GestureDetector(
                    onTapDown: (e) => select(e.localPosition),
                    onPanUpdate: (e) => select(e.localPosition),
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, 170),
                      painter: DesktopLinePainter(
                        points,
                        start,
                        end,
                        low,
                        high,
                        cursor,
                        markers,
                        color,
                        timeLabel,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DesktopLinePainter extends CustomPainter {
  DesktopLinePainter(
    this.points,
    this.start,
    this.end,
    this.low,
    this.high,
    this.cursor,
    this.markers,
    this.color,
    this.timeLabel,
  );
  final List<SignalPoint> points;
  final double start, end, low, high;
  final double? cursor;
  final List<double> markers;
  final Color color;
  final String Function(double) timeLabel;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      65,
      14,
      math.max(66, size.width - 65),
      size.height - 28,
    );
    final pad = math.max(.01, (high - low) * .08);
    final minimum = low - pad, maximum = high + pad;
    double x(double t) =>
        rect.left + (t - start) / math.max(.001, end - start) * rect.width;
    double y(double v) =>
        rect.bottom - (v - minimum) / (maximum - minimum) * rect.height;
    void text(String value, double dx, double dy) {
      final p = TextPainter(
        text: TextSpan(
          text: value,
          style: const TextStyle(color: Colors.black54, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(canvas, Offset(dx, dy));
    }

    final grid = Paint()
      ..color = Colors.black12
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final v = minimum + (maximum - minimum) * i / 4;
      canvas.drawLine(Offset(rect.left, y(v)), Offset(rect.right, y(v)), grid);
    }
    // Both sides always show the native-unit axis limits.
    for (final v in [minimum, maximum]) {
      text(v.toStringAsFixed(1), 2, y(v) - 7);
      text(v.toStringAsFixed(1), rect.right + 5, y(v) - 7);
    }
    text(timeLabel(start), rect.left, rect.bottom + 7);
    text(timeLabel(end), math.max(rect.left, rect.right - 55), rect.bottom + 7);
    canvas.save();
    canvas.clipRect(rect);
    final eventPaint = Paint()
      ..color = Colors.purple.withValues(alpha: .3)
      ..strokeWidth = 1;
    for (final t in markers) {
      if (t >= start && t <= end) {
        canvas.drawLine(
          Offset(x(t), rect.top),
          Offset(x(t), rect.bottom),
          eventPaint,
        );
      }
    }
    final path = Path();
    var open = false;
    for (final point in points) {
      if (!point.$2.isFinite) {
        open = false;
        continue;
      }
      if (open) {
        path.lineTo(x(point.$1), y(point.$2));
      } else {
        path.moveTo(x(point.$1), y(point.$2));
        open = true;
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25,
    );
    if (cursor != null) {
      canvas.drawLine(
        Offset(x(cursor!), rect.top),
        Offset(x(cursor!), rect.bottom),
        Paint()
          ..color = Colors.black54
          ..strokeWidth = 1,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DesktopLinePainter oldDelegate) => true;
}
