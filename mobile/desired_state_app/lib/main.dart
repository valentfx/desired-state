import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import 'polar_h10_service.dart';
import 'rr_history.dart';
import 'recording_foreground_service.dart';
import 'session_logger.dart';

void main() {
  runApp(const DesiredStateApp());
}

class DesiredStateApp extends StatelessWidget {
  const DesiredStateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Desired State',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const CollectorScreen(),
    );
  }
}

class CollectorScreen extends StatefulWidget {
  const CollectorScreen({super.key, this.service});

  final PolarH10Service? service;

  @override
  State<CollectorScreen> createState() => _CollectorScreenState();
}

class _CollectorScreenState extends State<CollectorScreen> {
  late final PolarH10Service _polar;

  StreamSubscription<PolarHeartRateData>? _dataSubscription;

  List<ScanResult> _scanResults = [];

  bool _scanning = false;
  bool _connecting = false;
  bool _connected = false;

  String _status = 'Ready';
  String _deviceName = 'No H10 connected';

  int? _heartRate;
  double? _latestRr;
  double? _rmssd;
  String? _polarId;
  RecordingState _recordingState = RecordingState.stopped;
  bool _exporting = false;
  DateTime? _sessionStartedAt;
  DateTime _lastForegroundUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  _TimelineRange _timelineRange = _TimelineRange.minutes10;

  final RrHistory _rrHistory = RrHistory();
  final List<_TimelinePoint> _timeline = [];
  final List<DateTime> _eventTimes = [];
  final TextEditingController _participantNameController =
      TextEditingController();
  final TextEditingController _eventDescriptionController =
      TextEditingController();
  final TextEditingController _sessionDescriptionController =
      TextEditingController();
  final TextEditingController _outcomeController = TextEditingController();
  SessionLogger? _sessionLogger;
  SessionLogger? _lastSessionLogger;
  final RecordingForegroundService _foregroundService =
      RecordingForegroundService();

  @override
  void initState() {
    super.initState();
    _polar = widget.service ?? PolarH10Service();

    _dataSubscription = _polar.dataStream.listen((data) {
      final logger = _sessionLogger;
      final polarId = _polarId;
      if (_recordingState == RecordingState.recording &&
          logger != null &&
          polarId != null) {
        final intervals = _rrHistory.addAll(data.rrIntervalsMs);
        unawaited(
          logger.logMeasurement(
            polarId: polarId,
            participantName: _participantName(),
            heartRate: data.heartRate,
            intervals: [
              for (final interval in intervals)
                LoggedRr(
                  rrMs: interval.rrMs,
                  accepted: interval.accepted,
                  artifactReason: interval.artifactReason,
                ),
            ],
            receivedAt: data.timestamp,
          ),
        );
      }

      final rmssd = _recordingState == RecordingState.recording
          ? _rrHistory.rmssd
          : _rmssd;
      if (_recordingState == RecordingState.recording) {
        _timeline.add(
          _TimelinePoint(
            timestamp: data.timestamp,
            heartRate: data.heartRate,
            rmssd: rmssd,
          ),
        );
        unawaited(
          _updateForegroundNotification(
            heartRate: data.heartRate,
            rmssd: rmssd,
            force: false,
          ),
        );
      }

      setState(() {
        _heartRate = data.heartRate;

        if (data.rrIntervalsMs.isNotEmpty) {
          _latestRr = data.rrIntervalsMs.last;
        }

        if (_recordingState == RecordingState.recording) {
          _rmssd = rmssd;
        }
      });
    });
  }

  Future<bool> _requestPermissions() async {
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
    ].request();

    final scanOk = results[Permission.bluetoothScan]?.isGranted ?? false;
    final connectOk = results[Permission.bluetoothConnect]?.isGranted ?? false;

    return scanOk && connectOk;
  }

  Future<void> _scan() async {
    final permissionOk = await _requestPermissions();

    if (!permissionOk) {
      setState(() {
        _status = 'Bluetooth permission denied';
      });
      return;
    }

    setState(() {
      _scanning = true;
      _scanResults = [];
      _status = 'Scanning for Polar H10...';
    });

    try {
      final results = await _polar.scan();

      if (!mounted) return;

      setState(() {
        _scanResults = results;
        _status = results.isEmpty
            ? 'No Polar H10 found'
            : 'Found ${results.length} device(s)';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _status = 'Scan error: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
        });
      }
    }
  }

  Future<void> _connect(ScanResult result) async {
    setState(() {
      _connecting = true;
      _status = 'Connecting...';
    });

    try {
      await _polar.connect(result.device);

      final name = result.device.platformName.trim();
      final deviceName = name.isEmpty ? result.device.remoteId.str : name;
      final polarId = _polarIdFrom(deviceName, result.device.remoteId.str);
      if (!mounted) {
        return;
      }

      setState(() {
        _connected = true;
        _deviceName = deviceName;
        _polarId = polarId;
        _status = 'Connected — ready to record';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _connected = false;
        _status = 'Connection error: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
        });
      }
    }
  }

  Future<void> _disconnect() async {
    await _polar.disconnect();
    await _stopSession();

    if (!mounted) return;

    setState(() {
      _connected = false;
      _heartRate = null;
      _latestRr = null;
      _rmssd = null;
      _rrHistory.clear();
      _polarId = null;
      _deviceName = 'No H10 connected';
      _status = 'Disconnected';
    });
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    _polar.dispose();
    _participantNameController.dispose();
    _eventDescriptionController.dispose();
    _sessionDescriptionController.dispose();
    _outcomeController.dispose();
    super.dispose();
  }

  String _participantName() {
    final name = _participantNameController.text.trim();
    return name.isEmpty ? 'unassigned' : name;
  }

  String _polarIdFrom(String deviceName, String fallback) {
    final match = RegExp(r'([A-Za-z0-9]{8})$').firstMatch(deviceName.trim());
    return (match?.group(1) ?? fallback).toUpperCase();
  }

  Future<void> _markEvent() async {
    final logger = _sessionLogger;
    if (logger == null) return;
    await logger.writeEvent(
      'marked_event',
      description: _eventDescriptionController.text,
    );
    if (!mounted) return;
    setState(() {
      _eventTimes.add(DateTime.now());
      _eventDescriptionController.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Event saved to this session log.')),
    );
  }

  Future<void> _startSession() async {
    final polarId = _polarId;
    if (polarId == null || !_connected) return;
    try {
      final logger = await SessionLogger.start(
        polarId: polarId,
        deviceName: _deviceName,
        participantName: _participantName(),
        description: _sessionDescriptionController.text,
      );
      await _foregroundService.start(logger.sessionId);
      if (!mounted) {
        await _foregroundService.stop();
        await logger.close();
        return;
      }
      setState(() {
        _rrHistory.clear();
        _timeline.clear();
        _eventTimes.clear();
        _rmssd = null;
        _sessionStartedAt = DateTime.now();
        _lastForegroundUpdate = DateTime.fromMillisecondsSinceEpoch(0);
        _sessionLogger = logger;
        _recordingState = RecordingState.recording;
        _status = 'Recording';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Could not start session log: $error');
    }
  }

  Future<void> _pauseSession() async {
    final logger = _sessionLogger;
    if (logger == null || _recordingState != RecordingState.recording) return;
    await logger.writeEvent('session_paused');
    _rrHistory.breakSequence();
    await _updateForegroundNotification(force: true, state: 'Paused');
    if (!mounted) return;
    setState(() {
      _recordingState = RecordingState.paused;
      _status = 'Recording paused';
    });
  }

  Future<void> _resumeSession() async {
    final logger = _sessionLogger;
    if (logger == null || _recordingState != RecordingState.paused) return;
    _rrHistory.breakSequence();
    await logger.writeEvent('session_resumed');
    await _updateForegroundNotification(force: true, state: 'Recording');
    if (!mounted) return;
    setState(() {
      _recordingState = RecordingState.recording;
      _status = 'Recording';
    });
  }

  Future<void> _stopSession() async {
    final logger = _sessionLogger;
    if (logger == null) return;
    await logger.close();
    await _foregroundService.stop();
    if (!mounted) return;
    setState(() {
      _sessionLogger = null;
      _lastSessionLogger = logger;
      _recordingState = RecordingState.stopped;
      _status = _connected ? 'Session saved' : _status;
    });
  }

  Future<void> _showSessionSetup() async {
    if (!_connected) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Start session',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _participantNameController,
              decoration: const InputDecoration(labelText: 'Participant name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sessionDescriptionController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Session description',
                hintText: 'Optional context or intention',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await _startSession();
              },
              child: const Text('START RECORDING'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEventNote() async {
    _eventDescriptionController.clear();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Mark event', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _eventDescriptionController,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Note',
                hintText: 'Optional event description',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await _markEvent();
              },
              child: const Text('SAVE EVENT'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showFinishSession() async {
    final logger = _sessionLogger;
    if (logger == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Finish session',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _outcomeController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Outcome / after-state',
                hintText: 'Optional notes',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () async {
                final outcome = _outcomeController.text;
                if (outcome.trim().isNotEmpty) {
                  await logger.writeEvent(
                    'session_outcome',
                    description: outcome,
                  );
                }
                _outcomeController.clear();
                if (context.mounted) Navigator.pop(context);
                await _stopSession();
              },
              child: const Text('SAVE SESSION'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportLastSession() async {
    final logger = _lastSessionLogger;
    if (logger == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final zip = await logger.createExportZip();
      await SharePlus.instance.share(
        ShareParams(
          subject: 'Desired State session ${logger.sessionId}',
          text: 'Desired State H10 session ${logger.sessionId}',
          files: [XFile(zip.path)],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export session: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Duration get _sessionElapsed {
    final startedAt = _sessionStartedAt;
    if (startedAt == null) return Duration.zero;
    return DateTime.now().difference(startedAt);
  }

  Future<void> _updateForegroundNotification({
    int? heartRate,
    double? rmssd,
    String? state,
    required bool force,
  }) async {
    if (_sessionLogger == null) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastForegroundUpdate) < const Duration(seconds: 5)) {
      return;
    }
    _lastForegroundUpdate = now;
    await _foregroundService.update(
      state:
          state ??
          (_recordingState == RecordingState.paused ? 'Paused' : 'Recording'),
      heartRate: heartRate ?? _heartRate,
      rmssd: rmssd ?? _rmssd,
      artifactCount: _rrHistory.artifactCount,
      elapsed: _sessionElapsed,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: SafeArea(child: _buildScreen(context)));
  }

  Widget _buildScreen(BuildContext context) {
    if (_recordingState == RecordingState.recording ||
        _recordingState == RecordingState.paused) {
      return _buildDashboard(context);
    }
    if (_lastSessionLogger != null) return _buildCompleted(context);
    return _buildConnect(context);
  }

  Widget _buildConnect(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('Desired State', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 4),
      Text(_status),
      const SizedBox(height: 24),
      if (_connected) ...[
        _deviceLine(),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _showSessionSetup,
          icon: const Icon(Icons.play_arrow),
          label: const Text('START RECORDING'),
        ),
        TextButton(onPressed: _disconnect, child: const Text('Disconnect')),
      ] else ...[
        FilledButton.icon(
          onPressed: _scanning ? null : _scan,
          icon: const Icon(Icons.bluetooth_searching),
          label: Text(_scanning ? 'Scanning…' : 'Scan for Polar H10'),
        ),
        for (final result in _scanResults)
          Card(
            child: ListTile(
              leading: const Icon(Icons.monitor_heart),
              title: Text(
                result.device.platformName.isEmpty
                    ? 'Polar / BLE device'
                    : result.device.platformName,
              ),
              subtitle: Text(result.device.remoteId.str),
              onTap: _connecting ? null : () => _connect(result),
            ),
          ),
      ],
    ],
  );

  Widget _buildDashboard(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${_participantName()} · $_deviceName',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            Icon(
              Icons.circle,
              size: 10,
              color: _recordingState == RecordingState.recording
                  ? Colors.red
                  : Colors.amber,
            ),
            const SizedBox(width: 4),
            Text(
              _recordingState == RecordingState.recording ? 'REC' : 'PAUSED',
            ),
            const SizedBox(width: 8),
            Text(_formatDuration(_sessionElapsed)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _Metric(
              label: 'HR',
              value: _heartRate?.toString() ?? '--',
              unit: 'bpm',
            ),
            _Metric(
              label: 'RMSSD',
              value: _rmssd?.toStringAsFixed(1) ?? '--',
              unit: 'ms',
            ),
            _Metric(
              label: 'RR',
              value: _latestRr?.toStringAsFixed(0) ?? '--',
              unit: 'ms',
            ),
          ],
        ),
        Text(
          'Good signal · ${_rrHistory.artifactCount} artifacts · Connected',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _TimelineCard(
            points: _timeline,
            eventTimes: _eventTimes,
            sessionStartedAt: _sessionStartedAt,
            range: _timelineRange,
            onRangeChanged: (value) => setState(() => _timelineRange = value),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onLongPress: _showEventNote,
                child: FilledButton.icon(
                  onPressed: _markEvent,
                  icon: const Icon(Icons.flag),
                  label: const Text('MARK EVENT'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (_recordingState == RecordingState.recording)
              FilledButton.tonal(
                onPressed: _pauseSession,
                child: const Text('Pause'),
              )
            else
              FilledButton(
                onPressed: _resumeSession,
                child: const Text('Continue'),
              ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: _showFinishSession,
              icon: const Icon(Icons.stop),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _buildCompleted(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Session saved', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          '${_timeline.length} updates · ${_eventTimes.length} events · ${_rrHistory.artifactCount} artifacts',
        ),
        const Spacer(),
        FilledButton.tonalIcon(
          onPressed: _exporting ? null : _exportLastSession,
          icon: const Icon(Icons.ios_share),
          label: Text(_exporting ? 'PREPARING…' : 'SHARE SESSION'),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _connected ? _showSessionSetup : null,
          child: const Text('NEW SESSION'),
        ),
        TextButton(onPressed: _disconnect, child: const Text('Disconnect')),
      ],
    ),
  );

  Widget _deviceLine() => Row(
    children: [
      const Icon(Icons.monitor_heart),
      const SizedBox(width: 8),
      Expanded(child: Text(_deviceName)),
      const Icon(Icons.check_circle, color: Colors.green),
    ],
  );

  String _formatDuration(Duration value) =>
      '${value.inHours.toString().padLeft(2, '0')}:${(value.inMinutes % 60).toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
}

enum RecordingState { stopped, recording, paused }

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.unit});

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label),
        const SizedBox(height: 8),
        Text(value, style: Theme.of(context).textTheme.headlineMedium),
        Text(unit),
      ],
    );
  }
}

enum _TimelineRange { minutes2, minutes10, minutes30, hour, all }

class _TimelinePoint {
  const _TimelinePoint({
    required this.timestamp,
    required this.heartRate,
    required this.rmssd,
  });

  final DateTime timestamp;
  final int heartRate;
  final double? rmssd;
}

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({
    required this.points,
    required this.eventTimes,
    required this.sessionStartedAt,
    required this.range,
    required this.onRangeChanged,
  });

  final List<_TimelinePoint> points;
  final List<DateTime> eventTimes;
  final DateTime? sessionStartedAt;
  final _TimelineRange range;
  final ValueChanged<_TimelineRange> onRangeChanged;

  Duration? get _duration => switch (range) {
    _TimelineRange.minutes2 => const Duration(minutes: 2),
    _TimelineRange.minutes10 => const Duration(minutes: 10),
    _TimelineRange.minutes30 => const Duration(minutes: 30),
    _TimelineRange.hour => const Duration(hours: 1),
    _TimelineRange.all => null,
  };

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final sessionStart = sessionStartedAt ?? now;
    final duration = _duration;
    final requestedStart = duration == null
        ? sessionStart
        : now.subtract(duration);
    final chartStart = requestedStart.isAfter(sessionStart)
        ? requestedStart
        : sessionStart;
    final visiblePoints = points
        .where((point) => !point.timestamp.isBefore(chartStart))
        .toList(growable: false);
    final chartEnd = visiblePoints.isEmpty ? now : visiblePoints.last.timestamp;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Session timeline',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                const Icon(Icons.show_chart, size: 20),
              ],
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<_TimelineRange>(
                segments: const [
                  ButtonSegment(
                    value: _TimelineRange.minutes2,
                    label: Text('2 min'),
                  ),
                  ButtonSegment(
                    value: _TimelineRange.minutes10,
                    label: Text('10 min'),
                  ),
                  ButtonSegment(
                    value: _TimelineRange.minutes30,
                    label: Text('30 min'),
                  ),
                  ButtonSegment(
                    value: _TimelineRange.hour,
                    label: Text('1 hr'),
                  ),
                  ButtonSegment(value: _TimelineRange.all, label: Text('All')),
                ],
                selected: {range},
                onSelectionChanged: (selection) =>
                    onRangeChanged(selection.first),
                showSelectedIcon: false,
              ),
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) => SizedBox(
                height: 190,
                width: double.infinity,
                child: InteractiveViewer(
                  constrained: false,
                  minScale: 1,
                  maxScale: 12,
                  boundaryMargin: const EdgeInsets.all(100),
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: 190,
                    child: CustomPaint(
                      painter: _SessionTimelinePainter(
                        points: visiblePoints,
                        eventTimes: eventTimes,
                        start: chartStart,
                        end: chartEnd.isAfter(chartStart) ? chartEnd : now,
                        colorScheme: Theme.of(context).colorScheme,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            const Text('Pinch to zoom · drag to pan · blue HR / green RMSSD'),
          ],
        ),
      ),
    );
  }
}

class _SessionTimelinePainter extends CustomPainter {
  const _SessionTimelinePainter({
    required this.points,
    required this.eventTimes,
    required this.start,
    required this.end,
    required this.colorScheme,
  });

  final List<_TimelinePoint> points;
  final List<DateTime> eventTimes;
  final DateTime start;
  final DateTime end;
  final ColorScheme colorScheme;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTWH(34, 8, size.width - 68, size.height - 24);
    final gridPaint = Paint()
      ..color = colorScheme.outlineVariant
      ..strokeWidth = 1;
    for (var fraction = 0.0; fraction <= 1.0; fraction += .25) {
      final y = plot.top + plot.height * fraction;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
    }
    final milliseconds = math.max(1, end.difference(start).inMilliseconds);
    double x(DateTime timestamp) =>
        plot.left +
        (timestamp.difference(start).inMilliseconds / milliseconds).clamp(
              0.0,
              1.0,
            ) *
            plot.width;
    final eventPaint = Paint()
      ..color = colorScheme.tertiary.withValues(alpha: .75)
      ..strokeWidth = 1.5;
    for (final timestamp in eventTimes) {
      if (timestamp.isBefore(start) || timestamp.isAfter(end)) continue;
      canvas.drawLine(
        Offset(x(timestamp), plot.top),
        Offset(x(timestamp), plot.bottom),
        eventPaint,
      );
    }
    _drawSeries(
      canvas,
      plot,
      points
          .map((point) => (point.timestamp, point.heartRate.toDouble()))
          .toList(),
      x,
      colorScheme.primary,
    );
    _drawSeries(
      canvas,
      plot,
      [
        for (final point in points)
          if (point.rmssd != null) (point.timestamp, point.rmssd!),
      ],
      x,
      colorScheme.tertiary,
    );
    _axisLabels(
      canvas,
      size,
      points.map((point) => point.heartRate.toDouble()).toList(),
      points
          .where((point) => point.rmssd != null)
          .map((point) => point.rmssd!)
          .toList(),
    );
    final label = '${_formatTime(start)} – ${_formatTime(end)}';
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    text.paint(canvas, Offset(0, size.height - text.height));
  }

  void _axisLabels(
    Canvas canvas,
    Size size,
    List<double> heartRates,
    List<double> rmssd,
  ) {
    void label(String text, Offset offset, Color color) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(fontSize: 10, color: color),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, offset);
    }

    if (heartRates.isNotEmpty) {
      label(
        '${heartRates.reduce(math.max).round()}',
        const Offset(0, 8),
        colorScheme.primary,
      );
      label(
        '${heartRates.reduce(math.min).round()}',
        Offset(0, size.height - 34),
        colorScheme.primary,
      );
    }
    if (rmssd.isNotEmpty) {
      final high = rmssd.reduce(math.max).toStringAsFixed(0);
      final low = rmssd.reduce(math.min).toStringAsFixed(0);
      label(high, Offset(size.width - 30, 8), colorScheme.tertiary);
      label(
        low,
        Offset(size.width - 30, size.height - 34),
        colorScheme.tertiary,
      );
    }
  }

  void _drawSeries(
    Canvas canvas,
    Rect plot,
    List<(DateTime, double)> values,
    double Function(DateTime) x,
    Color color,
  ) {
    if (values.length < 2) return;
    final low = values.map((value) => value.$2).reduce(math.min);
    final high = values.map((value) => value.$2).reduce(math.max);
    final span = math.max(1.0, high - low);
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final value = values[index];
      final y = plot.bottom - ((value.$2 - low) / span) * plot.height;
      final point = Offset(x(value.$1), y);
      if (index == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  String _formatTime(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  @override
  bool shouldRepaint(covariant _SessionTimelinePainter oldDelegate) => true;
}
