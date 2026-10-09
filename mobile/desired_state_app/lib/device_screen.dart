import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'session_controller.dart';
import 'o2_ring_service.dart';
import 'o2_ring_diagnostics_screen.dart';
import 'device_detail_screen.dart';
import 'bluetooth_permissions.dart';

/// Device discovery lives here; acquisition remains owned by SessionController.
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  SessionController get _controller => widget.controller;
  final Map<String, List<ScanResult>> _results = {};
  String _scanKind = 'h10';
  bool _scanning = false;
  String? _scanStatus;
  final _controlsChanged = ValueNotifier<int>(0);
  final TextEditingController _athenaSerial = TextEditingController();

  @override
  void dispose() {
    _controlsChanged.dispose();
    _athenaSerial.dispose();
    super.dispose();
  }

  void _update(VoidCallback change) {
    if (!mounted) {
      return;
    }
    setState(change);
    _controlsChanged.value++;
  }

  void _detail(String kind) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => DeviceDetailScreen(
        controller: _controller,
        kind: kind,
        controlsChanged: _controlsChanged,
        connectionBuilder: () => kind == 'h10'
            ? _h10Card()
            : kind == 'ring'
            ? _ringCard()
            : _athenaCard(),
      ),
    ),
  );
  Widget _h10Card() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Polar H10', style: Theme.of(context).textTheme.titleLarge),
          Text(_controller.deviceName),
          Text(_controller.connectionStatus),
          if (_controller.error != null) Text(_controller.error!),
          Text(
            _controller.heartRate == null
                ? 'No H10 heart-rate data received yet'
                : 'H10 heart rate: ${_controller.heartRate} bpm · last data ${_controller.lastDataAge?.inSeconds ?? 0}s ago',
          ),
          if (_controller.polarId != null) ...[
            Text('H10 ACC: ${_controller.accelerationStatus}'),
            Text('H10 ECG: ${_controller.ecgStatus}'),
          ],
          if (_controller.canReconnect)
            FilledButton.icon(
              onPressed: _controller.reconnect,
              icon: const Icon(Icons.refresh),
              label: const Text('Reconnect H10'),
            ),
          if (_controller.connected || _controller.polarId != null)
            TextButton(
              onPressed: _controller.busy ? null : _disconnect,
              child: const Text('Disconnect H10'),
            ),
          if (_controller.sessionLogger == null || _controller.polarId == null)
            _scanControls('h10'),
          if (_controller.sessionLogger != null && _controller.polarId == null)
            const Text(
              'Connect an H10 to add heart rate and RR to this recording.',
            ),
          if (_controller.sessionLogger != null)
            const Text(
              'Reconnect keeps this session. Stop before selecting a different H10.',
            ),
        ],
      ),
    ),
  );
  Widget _ringCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('O2Ring', style: Theme.of(context).textTheme.titleLarge),
          Text('${_controller.ringName} · ${_controller.ringStatus.name}'),
          Text('O2Ring rows recorded: ${_controller.recordedRingReadings}'),
          Text(
            _controller.latestRingReading == null
                ? 'No O2Ring measurements received yet'
                : 'SpO2 ${_controller.latestRingReading!.spo2}% · pulse ${_controller.latestRingReading!.pulse} bpm',
          ),
          if (_controller.ringDevice != null)
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _controller.busy || _scanning
                      ? null
                      : () async {
                          try {
                            await _controller.connectRing(
                              _controller.ringDevice!,
                            );
                          } catch (error) {
                            if (!mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'O2Ring connection failed: $error',
                                ),
                              ),
                            );
                          }
                        },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect O2Ring'),
                ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          O2RingDiagnosticsScreen(controller: _controller),
                    ),
                  ),
                  icon: const Icon(Icons.sensors),
                  label: const Text('O2Ring diagnostics'),
                ),
                TextButton(
                  onPressed: _controller.disconnectRing,
                  child: const Text('Disconnect O2Ring'),
                ),
              ],
            ),
          if (_controller.sessionLogger == null || _controller.ringId == null)
            _scanControls('ring'),
          if (_controller.sessionLogger != null && _controller.ringId == null)
            const Text(
              'Connect an O2Ring to add oxygen and pulse to this recording.',
            ),
        ],
      ),
    ),
  );

  Future<void> _connectAthena() async {
    final permissions = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    if (!(permissions[Permission.bluetoothScan]?.isGranted ?? false) ||
        !(permissions[Permission.bluetoothConnect]?.isGranted ?? false)) {
      _controller.museAthena.reportStatus('Nearby devices permission denied');
      return;
    }
    await _controller.loadUserSettings();
    await _controller.museAthena.connect(
      serialNumber: _athenaSerial.text,
      optical: _controller.preferences.museOpticalCapture,
    );
  }

  Widget _athenaCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: ListenableBuilder(
        listenable: _controller.museAthena,
        builder: (context, _) {
          final muse = _controller.museAthena;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Muse S Athena',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text(
                'EEG and motion · included when recording. Detailed diagnostics below.',
              ),
              SwitchListTile(
                title: const Text('Capture Athena optical data (experimental)'),
                subtitle: const Text(
                  'Raw intensity, not a brain oxygenation score. Reconnect to change.',
                ),
                value: _controller.preferences.museOpticalCapture,
                onChanged: muse.streaming || muse.busy
                    ? null
                    : (v) async {
                        try {
                          await _controller.savePreferences(
                            _controller.preferences.copyWith(
                              museOpticalCapture: v,
                            ),
                          );
                          if (mounted) {
                            setState(() {});
                          }
                        } catch (error) {
                          if (mounted && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Optical setting not saved: $error',
                                ),
                              ),
                            );
                          }
                        }
                      },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _athenaSerial,
                enabled: !muse.streaming && !muse.busy,
                decoration: const InputDecoration(
                  labelText: 'Advertised Muse name (optional)',
                  hintText: 'MuseS-XXXX',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed:
                        muse.busy ||
                            muse.streaming ||
                            _scanning ||
                            _controller.connecting ||
                            _controller.busy
                        ? null
                        : _connectAthena,
                    icon: Icon(
                      muse.streaming
                          ? Icons.sensors
                          : Icons.bluetooth_searching,
                    ),
                    label: Text(muse.busy ? 'Starting…' : 'Connect & stream'),
                  ),
                  if (muse.streaming)
                    OutlinedButton.icon(
                      onPressed: muse.busy ? null : muse.disconnect,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Disconnect'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(muse.status),
              if (muse.streaming || muse.eegSamples > 0)
                ExpansionTile(
                  title: const Text('Athena diagnostics'),
                  children: [
                    Text(
                      '${muse.deviceHint} · EEG ${muse.eegRate} Hz (${muse.eegSamples} samples) · motion ${muse.motionRate} Hz (${muse.motionSamples} samples)',
                    ),
                    if (muse.latestEeg.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'EEG latest values (µV by BrainFlow channel order)',
                      ),
                      for (final entry in muse.latestEeg.entries)
                        Text('${entry.key}: ${entry.value.toStringAsFixed(2)}'),
                    ],
                    if (muse.latestAccel.isNotEmpty)
                      Text(
                        'Motion latest · ${muse.latestAccel.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(3)}').join(' · ')}',
                      ),
                    if (muse.latestGyro.isNotEmpty)
                      Text(
                        'Gyroscope latest · ${muse.latestGyro.entries.map((e) => '${e.key} ${e.value.toStringAsFixed(3)}').join(' · ')}',
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    ),
  );
  Future<bool> _requestPermissions() => requestDeviceBluetoothPermissions();

  Future<void> _scan(String kind) async {
    if (_scanning) {
      return;
    }
    _update(() {
      _scanning = true;
      _scanKind = kind;
      _results[kind] = [];
      _scanStatus = kind == 'h10'
          ? 'Scanning for Polar H10...'
          : 'Scanning for O2Ring...';
    });

    try {
      final permissionOk = await _requestPermissions();
      if (!mounted) {
        return;
      }
      if (!permissionOk) {
        _update(() => _scanStatus = 'Bluetooth permission denied');
        return;
      }
      final results = await _scanOne(kind);

      if (!mounted) {
        return;
      }

      _update(() {
        _results[kind] = results;
        _scanStatus = results.isEmpty
            ? 'No supported device found'
            : 'Found ${results.length} device(s)';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      _update(() {
        _scanStatus = 'Scan error: $e';
      });
    } finally {
      if (mounted) {
        _update(() {
          _scanning = false;
        });
      }
    }
  }

  Future<List<ScanResult>> _scanOne(String kind) async {
    if (kind == 'h10') {
      return _controller.polar.scan();
    }
    final adapter = O2RingService();
    try {
      return await adapter.scan();
    } finally {
      await adapter.dispose();
    }
  }

  Widget _scanControls(String kind) => Column(
    children: [
      FilledButton.icon(
        onPressed:
            _scanning ||
                _controller.connecting ||
                _controller.busy ||
                _controller.museAthena.busy
            ? null
            : () => _scan(kind),
        icon: const Icon(Icons.bluetooth_searching),
        label: Text(
          _scanning && _scanKind == kind
              ? 'Searching...'
              : kind == 'h10'
              ? 'Scan for Polar H10'
              : 'Scan for O2Ring',
        ),
      ),
      if (_scanKind == kind && _scanStatus != null) Text(_scanStatus!),
      for (final result in _results[kind] ?? <ScanResult>[])
        ListTile(
          title: Text(
            result.device.platformName.isEmpty
                ? (kind == 'h10' ? 'Polar H10' : 'O2Ring')
                : result.device.platformName,
          ),
          subtitle: Text(result.device.remoteId.str),
          trailing: const Icon(Icons.bluetooth_connected),
          onTap: _controller.connecting || _controller.busy
              ? null
              : () async {
                  try {
                    await _connect(result, kind);
                  } catch (error) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Connection failed: $error')),
                      );
                    }
                  }
                },
        ),
    ],
  );

  Future<void> _connect(ScanResult result, String kind) async {
    _update(() {
      _scanKind = kind;
      _scanStatus = kind == 'h10'
          ? 'Connecting to H10…'
          : 'Opening O2Ring connection…';
    });
    if (kind == 'ring') {
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              O2RingDiagnosticsScreen(controller: _controller, result: result),
        ),
      );
      return;
    }
    await _controller.connect(result.device);
    if (mounted) {
      _update(() => _scanStatus = _controller.connectionStatus);
      if (!_controller.connected) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_controller.connectionStatus)));
      }
    }
  }

  Future<void> _disconnect() => _controller.disconnect();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            ListTile(
              leading: const Icon(Icons.monitor_heart_outlined),
              title: const Text('Polar H10'),
              subtitle: Text(_controller.connectionStatus),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _detail('h10'),
            ),
            ListTile(
              leading: const Icon(Icons.bloodtype_outlined),
              title: const Text('O2Ring'),
              subtitle: Text(
                '${_controller.ringName} · ${_controller.ringStatus.name}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _detail('ring'),
            ),
            if (Theme.of(context).platform == TargetPlatform.android)
              ListTile(
                leading: const Icon(Icons.psychology_outlined),
                title: const Text('Muse S Athena'),
                subtitle: Text(_controller.museAthena.status),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _detail('muse'),
              ),
          ],
        ),
      ),
    ),
  );
}
