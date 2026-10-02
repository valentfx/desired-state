import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'device_models.dart';
import 'o2_ring_service.dart';

/// Engineering view for O2Ring acquisition and raw protocol investigation.
class O2RingDiagnosticsScreen extends StatefulWidget {
  const O2RingDiagnosticsScreen({super.key, required this.result});
  final ScanResult result;

  @override
  State<O2RingDiagnosticsScreen> createState() =>
      _O2RingDiagnosticsScreenState();
}

class _O2RingDiagnosticsScreenState extends State<O2RingDiagnosticsScreen> {
  final O2RingService _service = O2RingService();
  StreamSubscription<DeviceConnectionStatus>? _statusSubscription;
  StreamSubscription<RawBlePacket>? _packetSubscription;
  StreamSubscription<O2RingReading>? _readingSubscription;
  StreamSubscription<void>? _diagnosticsSubscription;
  DeviceConnectionStatus _status = DeviceConnectionStatus.disconnected;
  final List<RawBlePacket> _packets = [];
  final List<O2RingReading> _readings = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _statusSubscription = _service.statusStream.listen((value) {
      if (mounted) setState(() => _status = value);
    });
    _diagnosticsSubscription = _service.diagnosticsChanged.listen((_) {
      if (mounted) setState(() {});
    });
    _packetSubscription = _service.packets.listen((value) {
      if (!mounted) return;
      setState(() {
        _packets.add(value);
        if (_packets.length > 250) _packets.removeAt(0);
      });
    });
    _readingSubscription = _service.readings.listen((value) {
      if (!mounted) return;
      setState(() {
        _readings.add(value);
        if (_readings.length > 120) _readings.removeAt(0);
      });
    });
    _connect();
  }

  Future<void> _connect() async {
    if (mounted) setState(() => _error = null);
    try {
      await _service.connect(widget.result.device);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _diagnosticsSubscription?.cancel();
    _packetSubscription?.cancel();
    _readingSubscription?.cancel();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final latest = _readings.isEmpty ? null : _readings.last;
    final notifyStatuses = _service.notifyStatuses;
    final gatt = _service.gattCharacteristics;
    return Scaffold(
      appBar: AppBar(title: const Text('O2Ring diagnostics')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              widget.result.device.platformName.isEmpty
                  ? 'Viatom / Wellue candidate'
                  : widget.result.device.platformName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text('Driver: ${O2RingService.diagnosticsBuildId}'),
            SelectableText('BLE ID: ${widget.result.device.remoteId.str}'),
            Text('Connection: ${_status.name}'),
            Text('Service discovery: ${_service.serviceDiscoveryStatus}'),
            Text('Notify subscription: ${_notifySummary(notifyStatuses)}'),
            Text('Detected protocol/write paths: ${_service.writeCharacteristicStatus}'),
            Text('Last TX: ${_service.lastTx}'),
            Text('Last RX: ${_service.lastRx}'),
            if (_error != null) SelectableText('Connection error: $_error'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _value('SpO₂', latest?.spo2 == null ? '--' : '${latest!.spo2}%'),
                _value('Pulse', latest?.pulse == null ? '--' : '${latest!.pulse} bpm'),
                _value('PI', '--'),
                _value('Motion', latest?.motion?.toStringAsFixed(2) ?? '--'),
                _value('Battery', '--'),
                _value('Worn / signal', '--'),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Vendor responses are captured as raw bytes. SpO₂, pulse, PI, motion, battery, and worn-state offsets are not decoded until the physical packet format and integrity checks are verified.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _status == DeviceConnectionStatus.connecting
                      ? null
                      : _connect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect'),
                ),
                OutlinedButton.icon(
                  onPressed: _service.canRequestSensors
                      ? () async {
                          try {
                            await _service.requestSensors();
                          } catch (error) {
                            if (mounted) setState(() => _error = '$error');
                          }
                        }
                      : null,
                  icon: const Icon(Icons.sensors),
                  label: const Text('Request reading'),
                ),
                TextButton(
                  onPressed: _service.disconnect,
                  child: const Text('Disconnect'),
                ),
              ],
            ),
            const Divider(height: 32),
            Text('GATT characteristics (${gatt.length})',
                style: Theme.of(context).textTheme.titleMedium),
            if (gatt.isEmpty) const Text('No GATT characteristics discovered yet.'),
            for (final characteristic in gatt)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        '${characteristic.serviceUuid}\n${characteristic.characteristicUuid}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text('Properties: ${characteristic.properties.join(', ')}'),
                      if (notifyStatuses.containsKey(
                        '${characteristic.serviceUuid}/${characteristic.characteristicUuid}',
                      ))
                        Text(
                          'Notify: ${notifyStatuses['${characteristic.serviceUuid}/${characteristic.characteristicUuid}']}',
                        ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 32),
            Text('Raw TX/RX packets (${_packets.length}/250)',
                style: Theme.of(context).textTheme.titleMedium),
            if (_packets.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No TX or RX packets yet. Keep the ring on and awake. Supported request(s) are sent after notification subscription; each detected protocol uses its own polling interval.'),
              ),
            for (final packet in _packets.reversed)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${packet.direction.name.toUpperCase()}  ${packet.receivedAt.toLocal().toIso8601String()}  ${packet.characteristic}  (${packet.bytes.length} bytes)',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      SelectableText(packet.hex),
                      Text(packet.interpretation ?? 'Unparsed packet'),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _notifySummary(Map<String, String> statuses) {
    if (statuses.isEmpty) return 'No notify/indicate characteristics found';
    final ringStatus = statuses['${O2RingService.viatomService}/${O2RingService.viatomNotify}'];
    return ringStatus ?? '${statuses.values.where((value) => value == 'Subscribed').length} subscribed / ${statuses.length} found';
  }

  Widget _value(String label, String value) => Chip(label: Text('$label: $value'));
}
