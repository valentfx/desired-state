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
import 'participant_tools.dart';
import 'compact_eeg_panel.dart';
import 'preferences_screen.dart';
import 'session_timeline_screen.dart';
import 'session_review_screen.dart';
import 'settings_screen.dart';

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
  final _navigator = GlobalKey<NavigatorState>();
  final _shell = GlobalKey<ScaffoldState>();
  final _collector = GlobalKey<_CollectorScreenState>();
  final _view = ValueNotifier<(int, int)>((0, 0));

  void _select(int index) {
    _shell.currentState?.closeDrawer();
    _navigator.currentState?.popUntil((route) => route.isFirst);
    _view.value = (index, _view.value.$2 + 1);
  }

  void _open(Widget screen) {
    _shell.currentState?.closeDrawer();
    _navigator.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppNavigation(
    showLive: () => _select(1),
    showHistory: () => _select(2),
    child: Scaffold(
      key: _shell,
      appBar: AppBar(
        toolbarHeight: 44,
        title: ListenableBuilder(
          listenable: Listenable.merge([widget.controller, _view]),
          builder: (context, _) => Text(
            widget.controller.sessionLogger == null
                ? (_view.value.$1 == 1 ? 'Live' : 'Screens')
                : '${_view.value.$1 == 1 ? 'Live · ' : ''}${widget.controller.recordingState == RecordingState.paused ? 'Paused' : 'Recording'} · ${widget.controller.participant}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            children: [
              const ListTile(
                title: Text('Desired State'),
                subtitle: Text('Screens and tools'),
              ),
              ListTile(
                leading: const Icon(Icons.home_outlined),
                title: const Text('Overview'),
                onTap: () => _select(0),
              ),
              ListTile(
                leading: const Icon(Icons.monitor_heart_outlined),
                title: const Text('Live'),
                onTap: () => _select(1),
              ),
              ListTile(
                leading: const Icon(Icons.insights_outlined),
                title: const Text('Analyze'),
                onTap: () => _select(2),
              ),
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: const Text('Devices'),
                onTap: () => _open(DeviceScreen(controller: widget.controller)),
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                onTap: () =>
                    _open(SettingsScreen(controller: widget.controller)),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.science_outlined),
                title: const Text('Advanced tools'),
                onTap: () {
                  _shell.currentState?.closeDrawer();
                  _select(1);
                  _collector.currentState?._openAdvanced();
                },
              ),
            ],
          ),
        ),
      ),
      body: NavigatorPopHandler<Object?>(
        onPopWithResult: (_) => _navigator.currentState?.maybePop(),
        child: Navigator(
          key: _navigator,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => ValueListenableBuilder<(int, int)>(
              valueListenable: _view,
              builder: (context, selection, _) => IndexedStack(
                index: selection.$1,
                children: [
                  OverviewScreen(
                    controller: widget.controller,
                    revision: selection.$2,
                    onLive: () => _select(1),
                    onAnalyze: () => _select(2),
                  ),
                  CollectorScreen(
                    key: _collector,
                    controller: widget.controller,
                  ),
                  HistoryScreen(
                    controller: widget.controller,
                    revision: selection.$2,
                    analyze: true,
                    onLive: () => _select(1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
      : _controller.ringId != null
      ? _controller.ringName
      : 'Muse S Athena';

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
    _controller.loadUserSettings().catchError((Object error) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
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
                  leading: const Icon(Icons.dashboard_customize_outlined),
                  title: const Text('Customize Live'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          PreferencesScreen(controller: _controller),
                    ),
                  ),
                ),
                if (_sessionLogger != null)
                  ListTile(
                    leading: const Icon(Icons.show_chart),
                    title: const Text('All session signals'),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SessionTimelineScreen(
                          directory: _sessionLogger!.directory,
                          origin: _controller.sessionStartedAt!,
                          title: 'Current recording',
                          controller: _controller,
                        ),
                      ),
                    ),
                  ),
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

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    // Only the app owner disposes a shared controller, never navigation.
    _participantNameController.dispose();
    _eventDescriptionController.dispose();

    super.dispose();
  }

  String _participantName() => _controller.participant;
  Future<void> _editParticipant() async {
    final active = _controller.sessionLogger != null;
    final values = await editParticipant(
      context,
      name: active ? _controller.participant : _participantNameController.text,
      info: _controller.participantInfo,
      participantId: _controller.participantId,
      store: ParticipantStore(directoryProvider: _controller.directoryProvider),
      correction: active,
    );
    if (values == null) {
      return;
    }
    try {
      if (active) {
        await _controller.editRecordingParticipant(
          values.$1,
          values.$2,
          profileId: values.$3,
        );
        _participantNameController.text = values.$1;
      } else {
        _participantNameController.text = values.$1;
        _controller.participantInfo = values.$2;
        _controller.participantId = values.$3;
      }
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Participant not saved: $error')),
        );
      }
    }
  }

  Future<void> _markEvent() async {
    await _controller.markEvent(_eventDescriptionController.text);
    _eventDescriptionController.clear();
  }

  Future<void> _startSession() async {
    await _controller.start(
      participantName: _participantNameController.text,
      participantProfileId: _controller.participantId,
    );
    if (_controller.sessionLogger != null &&
        _controller.participantInfo.isNotEmpty) {
      await _controller.editRecordingParticipant(
        _controller.participant,
        _controller.participantInfo,
        profileId: _controller.participantId,
      );
    }
    if (mounted) {
      setState(() => _showConnect = false);
    }
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
    if (logger == null) {
      return;
    }
    // Only the owning Live screen edits annotations during recording.
    // History's separate repository retains its active-session write guard.
    final repository = SessionHistoryRepository(
      directoryProvider: _controller.directoryProvider,
    );
    try {
      final entry = await repository.readEntry(logger.directory);
      if (!mounted) {
        return;
      }
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

  Future<void> _reviewLastSession() async {
    final logger = _lastSessionLogger;
    if (logger == null || _controller.busy) {
      return;
    }
    try {
      final repository = SessionHistoryRepository(
        directoryProvider: _controller.directoryProvider,
        activeSessionId: () => _controller.sessionLogger?.sessionId,
      );
      final entry = await repository.readEntry(logger.directory);
      final session = await repository.open(entry);
      if (!mounted) {
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SessionReviewScreen(
            session: session,
            repository: repository,
            controller: _controller,
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not review session: $error')),
        );
      }
    }
  }

  Future<void> _exportLastSession() async {
    final logger = _lastSessionLogger;
    if (logger == null || _exporting) {
      return;
    }
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
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  Duration get _sessionElapsed => _controller.sessionElapsed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 36,
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
            tooltip: 'Live settings',
            icon: const Icon(Icons.tune),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => PreferencesScreen(controller: _controller),
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
      Wrap(
        spacing: 16,
        children: [
          Text('BPM ${_controller.heartRate ?? '--'}'),
          Text('RMSSD ${_controller.rmssd?.toStringAsFixed(1) ?? '--'} ms'),
          if (_controller.preferences.showOxygen)
            Text('SpO2 ${_controller.latestRingReading?.spo2 ?? '--'}%'),
        ],
      ),
      if (_controller.preferences.showEeg)
        CompactEegPanel(controller: _controller),
      if (_lastSessionLogger != null)
        TextButton(
          onPressed: () => setState(() => _showConnect = false),
          child: const Text('Back to saved session'),
        ),
      const SizedBox(height: 24),
      TextField(
        controller: _participantNameController,
        onChanged: (_) {
          _controller.participantInfo = '';
          _controller.participantId = null;
        },
        decoration: const InputDecoration(
          labelText: 'Participant name',
          hintText: 'Optional; blank records as unassigned',
        ),
      ),
      TextButton.icon(
        onPressed: _editParticipant,
        icon: const Icon(Icons.person_outline),
        label: const Text('Choose / edit participant'),
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
          label: const Text('Connect devices'),
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
    padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
    child: Column(
      children: [
        Expanded(
          child: ProcessingScreen(
            controller: _controller,
            embedded: true,
            header: [
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    _recordingState == RecordingState.recording
                        ? '● REC'
                        : 'PAUSED',
                  ),
                  Text(_participantName()),
                  Text(_formatDuration(_sessionElapsed)),
                  if (_controller.preferences.showOxygen)
                    Text(
                      'SpO2 ${_controller.ringDataFresh ? _controller.latestRingReading?.spo2 ?? '--' : '--'}%',
                    ),
                  if (_controller.preferences.showPosture &&
                      _controller.polarId != null)
                    Text(_controller.currentPosture),
                ],
              ),
              if (_controller.preferences.showEeg)
                CompactEegPanel(controller: _controller),
              if (_controller.error != null) Text(_controller.error!),
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
        FilledButton.icon(
          onPressed: _controller.busy ? null : _reviewLastSession,
          icon: const Icon(Icons.analytics_outlined),
          label: const Text('Review session'),
        ),
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
