import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import 'rr_history.dart';
import 'session_controller.dart';
import 'session_logger.dart';
import 'quick_marker_widgets.dart';

void main() {
  runApp(const DesiredStateApp());
}

class DesiredStateApp extends StatefulWidget {
  const DesiredStateApp({super.key});

  @override
  State<DesiredStateApp> createState() => _DesiredStateAppState();
}

class _DesiredStateAppState extends State<DesiredStateApp> {
  final SessionController _controller = SessionController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Desired State',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: CollectorScreen(controller: _controller),
    );
  }
}

class CollectorScreen extends StatefulWidget {
  const CollectorScreen({super.key, required this.controller});

  final SessionController controller;

  @override
  State<CollectorScreen> createState() => _CollectorScreenState();
}

class _CollectorScreenState extends State<CollectorScreen> {
  late final SessionController _controller;
  List<ScanResult> _scanResults = [];
  bool _scanning = false;
  bool _exporting = false;
  bool _showConnect = false;
  String? _scanStatus;
  bool get _connecting => _controller.connecting;
  bool get _connected => _controller.connected;
  String get _status => _controller.error ?? _scanStatus ?? _controller.status;
  String get _deviceName => _controller.deviceName;
  int? get _heartRate => _controller.heartRate;
  double? get _latestRr => _controller.latestRr;
  double? get _rmssd => _controller.rmssd;
  RecordingState get _recordingState => _controller.recordingState;
  DateTime? get _sessionStartedAt => _controller.sessionStartedAt;
  RrHistory get _rrHistory => _controller.rrHistory;
  List<TimelinePoint> get _timeline => _controller.timeline;
  List<DateTime> get _eventTimes => _controller.eventTimes;
  SessionLogger? get _sessionLogger => _controller.sessionLogger;
  SessionLogger? get _lastSessionLogger => _controller.lastSessionLogger;
  _TimelineRange _timelineRange = _TimelineRange.minutes10;
  final _participantNameController = TextEditingController();
  final _eventDescriptionController = TextEditingController();
  final _sessionDescriptionController = TextEditingController();
  final _outcomeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = widget.controller;
    _controller.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
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
        _scanStatus = 'Bluetooth permission denied';
      });
      return;
    }

    setState(() {
      _scanning = true;
      _scanResults = [];
      _scanStatus = 'Scanning for Polar H10...';
    });

    try {
      final results = await _controller.polar.scan();

      if (!mounted) return;

      setState(() {
        _scanResults = results;
        _scanStatus = results.isEmpty
            ? 'No Polar H10 found'
            : 'Found ${results.length} device(s)';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _scanStatus = 'Scan error: $e';
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
    _scanStatus = null;
    await _controller.connect(result.device);
  }

  Future<void> _disconnect() => _controller.disconnect();

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    // Only the app owner disposes a shared controller, never navigation.
    _participantNameController.dispose();
    _eventDescriptionController.dispose();
    _sessionDescriptionController.dispose();
    _outcomeController.dispose();
    super.dispose();
  }

  String _participantName() => _controller.participant;

  Future<void> _markEvent() async {
    await _controller.markEvent(_eventDescriptionController.text);
    _eventDescriptionController.clear();
  }

  Future<void> _startSession() async {
    await _controller.start(
      participantName: _participantNameController.text,
      description: _sessionDescriptionController.text,
    );
    if (mounted) setState(() => _showConnect = false);
  }

  void _pauseSession() => _controller.pause();
  void _resumeSession() => _controller.resume();

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
                _outcomeController.clear();
                Navigator.pop(context);
                await _controller.stop(outcome: outcome);
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

  Duration get _sessionElapsed => _controller.sessionElapsed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: SafeArea(child: _buildScreen(context)));
  }

  Widget _buildScreen(BuildContext context) {
    if (_recordingState == RecordingState.recording ||
        _recordingState == RecordingState.paused) {
      return _buildDashboard(context);
    }
    if (_lastSessionLogger != null && !_showConnect) {
      return _buildCompleted(context);
    }
    return _buildConnect(context);
  }

  Widget _buildConnect(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('Desired State', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 4),
      Text(_status),
      QuickMarkerBar(controller: _controller),
      if (_lastSessionLogger != null)
        TextButton(
          onPressed: () => setState(() => _showConnect = false),
          child: const Text('Back to saved session'),
        ),
      const SizedBox(height: 24),
      if (_connected) ...[
        _deviceLine(),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _controller.busy ? null : _showSessionSetup,
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
        Expanded(
          child: ListView(
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
                    _recordingState == RecordingState.recording
                        ? 'REC'
                        : 'PAUSED',
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
                '${_controller.connectionStatus} · last data ${_controller.lastDataAge?.inSeconds.toString() ?? '--'}s ago · ${_rrHistory.artifactCount} artifacts',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              if (_controller.error != null) Text(_controller.error!),
              Wrap(
                alignment: WrapAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _controller.canReconnect
                        ? _controller.reconnect
                        : null,
                    icon: const Icon(Icons.bluetooth_connected),
                    label: const Text('Reconnect H10'),
                  ),
                  TextButton(
                    onPressed: _controller.busy ? null : _disconnect,
                    child: const Text('Disconnect'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              QuickMarkerBar(controller: _controller),
              _TimelineCard(
                points: _timeline,
                eventTimes: _eventTimes,
                sessionStartedAt: _sessionStartedAt,
                range: _timelineRange,
                onRangeChanged: (value) =>
                    setState(() => _timelineRange = value),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
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
                onPressed: _controller.busy ? null : _pauseSession,
                child: const Text('Pause'),
              )
            else
              FilledButton(
                onPressed: _controller.busy ? null : _resumeSession,
                child: const Text('Continue'),
              ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: _controller.busy ? null : _showFinishSession,
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
        QuickMarkerBar(controller: _controller),
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
        if (!_connected)
          TextButton(
            onPressed: () => setState(() => _showConnect = true),
            child: const Text('Connect H10'),
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

class _TimelineCard extends StatelessWidget {
  const _TimelineCard({
    required this.points,
    required this.eventTimes,
    required this.sessionStartedAt,
    required this.range,
    required this.onRangeChanged,
  });

  final List<TimelinePoint> points;
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
          mainAxisSize: MainAxisSize.min,
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
                  constrained: true,
                  panAxis: PanAxis.horizontal,
                  minScale: 1,
                  maxScale: 12,
                  boundaryMargin: EdgeInsets.zero,
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
            const Text(
              'Pinch to zoom · drag horizontally · blue HR / orange RMSSD',
            ),
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

  final List<TimelinePoint> points;
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
      ..color = Colors.purple.shade600.withValues(alpha: .75)
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
          .map(
            (point) =>
                (point.timestamp, point.heartRate.toDouble(), point.segment),
          )
          .toList(),
      x,
      Colors.blue.shade700,
    );
    _drawSeries(
      canvas,
      plot,
      [
        for (final point in points)
          if (point.rmssd != null)
            (point.timestamp, point.rmssd!, point.segment),
      ],
      x,
      Colors.orange.shade800,
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
        Colors.blue.shade700,
      );
      label(
        '${heartRates.reduce(math.min).round()}',
        Offset(0, size.height - 34),
        Colors.blue.shade700,
      );
    }
    if (rmssd.isNotEmpty) {
      final high = rmssd.reduce(math.max).toStringAsFixed(0);
      final low = rmssd.reduce(math.min).toStringAsFixed(0);
      label(high, Offset(size.width - 30, 8), Colors.orange.shade800);
      label(
        low,
        Offset(size.width - 30, size.height - 34),
        Colors.orange.shade800,
      );
    }
  }

  void _drawSeries(
    Canvas canvas,
    Rect plot,
    List<(DateTime, double, int)> values,
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
      if (index == 0 || values[index - 1].$3 != value.$3) {
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
