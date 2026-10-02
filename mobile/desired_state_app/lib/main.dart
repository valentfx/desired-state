import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'rr_history.dart';
import 'session_controller.dart';
import 'session_logger.dart';
import 'quick_marker_widgets.dart';
import 'history_screen.dart';
import 'processing_screen.dart';
import 'session_history.dart';
import 'app_navigation.dart';
import 'device_screen.dart';
import 'overview_screen.dart';

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
      home: SessionHome(controller: _controller),
    );
  }
}

class SessionHome extends StatefulWidget {
  const SessionHome({super.key, required this.controller});
  final SessionController controller;
  @override
  State<SessionHome> createState() => _SessionHomeState();
}

class _SessionHomeState extends State<SessionHome> {
  int _tab = 0, _historyRevision = 0, _overviewRevision = 0;
  void _select(int tab) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() {
      _tab = tab;
      if (tab == 0) _overviewRevision++;
      if (tab == 2) _historyRevision++;
    });
  }

  @override
  Widget build(BuildContext context) => AppNavigation(
    showLive: () => _select(1),
    showHistory: () => _select(2),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final pages = IndexedStack(
          index: _tab,
          children: [
            OverviewScreen(
              controller: widget.controller,
              revision: _overviewRevision,
              onLive: () => _select(1),
              onAnalyze: () => _select(2),
            ),
            CollectorScreen(controller: widget.controller),
            HistoryScreen(
              controller: widget.controller,
              revision: _historyRevision,
              onLive: () => _select(1),
            ),
          ],
        );
        return Scaffold(
          body: Row(
            children: [
              if (wide) ...[
                SafeArea(
                  child: NavigationRail(
                    extended: constraints.maxWidth >= 1200,
                    selectedIndex: _tab,
                    onDestinationSelected: _select,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.home_outlined),
                        label: Text('Overview'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.monitor_heart_outlined),
                        label: Text('Live'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.insights_outlined),
                        label: Text('Analyze'),
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
              ],
              Expanded(key: const ValueKey('workspace-pages'), child: pages),
            ],
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _tab,
                  onDestinationSelected: _select,
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.home_outlined),
                      label: 'Overview',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.monitor_heart_outlined),
                      label: 'Live',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.insights_outlined),
                      label: 'Analyze',
                    ),
                  ],
                ),
        );
      },
    ),
  );
}

class CollectorScreen extends StatefulWidget {
  const CollectorScreen({super.key, required this.controller});

  final SessionController controller;

  @override
  State<CollectorScreen> createState() => _CollectorScreenState();
}

class _CollectorScreenState extends State<CollectorScreen> {
  late final SessionController _controller;
  bool _exporting = false;
  bool _showConnect = false;
  bool get _connected => _controller.canStart;
  String get _status => _controller.error ?? _controller.status;
  String get _deviceName => _controller.connected || _controller.polarId != null
      ? _controller.deviceName
      : _controller.ringName;

  RecordingState get _recordingState => _controller.recordingState;

  RrHistory get _rrHistory => _controller.rrHistory;
  List<TimelinePoint> get _timeline => _controller.timeline;
  List<DateTime> get _eventTimes => _controller.eventTimes;
  SessionLogger? get _sessionLogger => _controller.sessionLogger;
  SessionLogger? get _lastSessionLogger => _controller.lastSessionLogger;

  final _participantNameController = TextEditingController();
  final _eventDescriptionController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = widget.controller;
    _controller.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _openDevice() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DeviceScreen(controller: _controller),
    ),
  );

  void _openAdvanced() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Advanced live tools')),
        body: SafeArea(
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                RecordingHistoryBanner(
                  controller: _controller,
                  onLive: AppNavigation.maybeOf(this.context)?.showLive,
                ),
                if (_controller.polarId != null) _accLine(),
                if (_controller.ringId != null) _ringLine(),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('History'),
                  subtitle: const Text(
                    'All participants, notes and session exports',
                  ),
                  onTap: _openHistory,
                ),
                ListTile(
                  leading: const Icon(Icons.bluetooth),
                  title: const Text('Device diagnostics'),
                  subtitle: const Text(
                    'Connections, stream status and raw packets',
                  ),
                  onTap: _openDevice,
                ),
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('Processing & plots'),
                  subtitle: const Text(
                    'Raw / filtered comparison, metrics and detailed plots',
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ProcessingScreen(controller: _controller),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _streamStatus() => InkWell(
    onTap: _openAdvanced,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_controller.polarId != null)
          Text(
            'H10 · ${_controller.connectionStatus} · HR packet ${_controller.lastDataAge?.inSeconds.toString() ?? '--'}s ago · ACC ${_controller.latestAcceleration != null && DateTime.now().difference(_controller.latestAcceleration!.receivedAt) < const Duration(seconds: 5) && _controller.connected ? 'fresh' : 'no fresh data'}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        if (_controller.ringId != null)
          Text(
            'O2Ring · ${_controller.ringStatus.name} · SpO₂ ${_controller.ringDataFresh ? _controller.latestRingReading?.spo2 ?? '--' : '--'}% · ${_controller.ringDataFresh ? 'fresh' : 'no fresh data'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.deepPurple),
          ),
      ],
    ),
  );
  @override
  void dispose() {
    _controller.removeListener(_refresh);
    // Only the app owner disposes a shared controller, never navigation.
    _participantNameController.dispose();
    _eventDescriptionController.dispose();

    super.dispose();
  }

  String _participantName() => _controller.participant;

  Future<void> _markEvent() async {
    await _controller.markEvent(_eventDescriptionController.text);
    _eventDescriptionController.clear();
  }

  Future<void> _startSession() async {
    await _controller.start(participantName: _participantNameController.text);
    if (mounted) setState(() => _showConnect = false);
  }

  void _pauseSession() => _controller.pause();
  void _resumeSession() => _controller.resume();

  void _openHistory() {
    final navigation = AppNavigation.maybeOf(context);
    if (navigation != null) {
      navigation.showHistory();
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => HistoryScreen(controller: _controller),
      ),
    );
  }

  Future<void> _openSessionNotes() async {
    final logger = _sessionLogger ?? _lastSessionLogger;
    if (logger == null) return;
    // Only the owning Live screen edits annotations during recording.
    // History's separate repository retains its active-session write guard.
    final repository = SessionHistoryRepository(
      directoryProvider: _controller.directoryProvider,
    );
    try {
      final entry = await repository.readEntry(logger.directory);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => HistoryMetadataEditor(
            entry: entry,
            repository: repository,
            controller: _controller,
            onLive: AppNavigation.maybeOf(context)?.showLive,
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open session notes: $error')),
        );
      }
    }
  }

  Future<void> _showEventNote() async {
    _eventDescriptionController.clear();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        alignment: Alignment.topCenter,
        title: const Text('Mark event'),
        scrollable: true,
        content: TextField(
          controller: _eventDescriptionController,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Note',
            hintText: 'Optional event description',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await _markEvent();
            },
            child: const Text('SAVE EVENT'),
          ),
        ],
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live'),
        actions: [
          IconButton(
            tooltip: 'Device connection',
            onPressed: _openDevice,
            icon: const Icon(Icons.bluetooth),
          ),
          if (_sessionLogger != null || _lastSessionLogger != null)
            IconButton(
              tooltip: 'Session notes',
              icon: const Icon(Icons.edit_note),
              onPressed: _openSessionNotes,
            ),
          IconButton(
            tooltip: 'Processing & plots',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ProcessingScreen(controller: _controller),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Advanced tools',
            onPressed: _openAdvanced,
            icon: const Icon(Icons.more_vert),
          ),
        ],
      ),
      body: SafeArea(child: _buildScreen(context)),
    );
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
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _openHistory,
        icon: const Icon(Icons.history),
        label: const Text('Browse saved sessions'),
      ),
      const Text(
        'Review sessions by participant without connecting or recording.',
      ),
      const SizedBox(height: 4),
      Text(_status),
      _streamStatus(),
      QuickMarkerBar(controller: _controller),
      if (_lastSessionLogger != null)
        TextButton(
          onPressed: () => setState(() => _showConnect = false),
          child: const Text('Back to saved session'),
        ),
      const SizedBox(height: 24),
      TextField(
        controller: _participantNameController,
        decoration: const InputDecoration(
          labelText: 'Participant name',
          hintText: 'Optional; blank records as unassigned',
        ),
      ),
      const SizedBox(height: 12),
      if (_connected) ...[
        _deviceLine(),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _controller.busy ? null : _startSession,
          icon: const Icon(Icons.play_arrow),
          label: const Text('START RECORDING'),
        ),
      ] else ...[
        FilledButton.icon(
          onPressed: _openDevice,
          icon: const Icon(Icons.bluetooth),
          label: const Text('Connect H10'),
        ),
      ],
    ],
  );

  Widget _accLine() {
    final frame = _controller.latestAcceleration;
    final fresh =
        _controller.connected &&
        frame != null &&
        DateTime.now().difference(frame.receivedAt) <
            const Duration(seconds: 5);
    final xyz = fresh ? frame.samples.last.join(', ') : '--';
    return Text(
      'H10 ACC: ${_controller.accelerationStatus} · XYZ $xyz mG · '
      '${_controller.recordedAccSamples} samples recorded',
    );
  }

  Widget _ringLine() {
    final reading = _controller.ringDataFresh
        ? _controller.latestRingReading
        : null;
    return Text(
      'O2 ${reading?.spo2 ?? '--'}% · pulse ${reading?.pulse ?? '--'} bpm · '
      'battery ${reading?.battery ?? '--'}% · ${_controller.ringStatus.name} · '
      '${_controller.recordedRingReadings} rows · '
      '${_controller.ringDataAge?.inSeconds.toString() ?? '--'}s ago',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.deepPurple,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _buildDashboard(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    child: Column(
      children: [
        Expanded(
          child: ProcessingScreen(
            controller: _controller,
            embedded: true,
            header: [
              _streamStatus(),
              Row(
                children: [
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
                  Expanded(
                    child: Text(
                      '${_participantName()} | $_deviceName',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(_formatDuration(_sessionElapsed)),
                ],
              ),
              InkWell(
                onTap: _openDevice,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '${_controller.connectionStatus} | last data ${_controller.lastDataAge?.inSeconds.toString() ?? '--'}s ago',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (_controller.error != null)
                Text(
                  _controller.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        QuickMarkerBar(controller: _controller, compact: true),
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
              onPressed: _controller.busy ? null : () => _controller.stop(),
              tooltip: 'Stop recording',
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
          onPressed: _connected ? _startSession : null,
          child: const Text('NEW SESSION'),
        ),
        if (!_connected)
          TextButton(onPressed: _openDevice, child: const Text('Connect H10')),
        TextButton(
          onPressed: _openDevice,
          child: const Text('Device connection'),
        ),
      ],
    ),
  );

  Widget _deviceLine() => Row(
    children: [
      const Icon(Icons.monitor_heart),
      const SizedBox(width: 8),
      Expanded(child: Text(_deviceName)),
      Icon(
        _controller.lastDataAge != null || _controller.ringDataFresh
            ? Icons.sensors
            : Icons.bluetooth_connected,
      ),
    ],
  );

  String _formatDuration(Duration value) =>
      '${value.inHours.toString().padLeft(2, '0')}:${(value.inMinutes % 60).toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
}
