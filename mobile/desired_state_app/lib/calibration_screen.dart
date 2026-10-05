import 'dart:async';

import 'package:flutter/material.dart';

import 'h10_accelerometer.dart';
import 'posture_calibration.dart';
import 'session_controller.dart';

class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  final _name = TextEditingController(text: 'Normal strap placement');
  final Map<String, List<double>> _positions = {};
  List<PostureCalibration> _saved = [];
  bool _capturing = false, _saving = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await CalibrationStore(widget.controller.directoryProvider)
          .load();
      if (mounted) {
        setState(() {
          _saved = list
              .where(
                (v) =>
                    v.deviceId == widget.controller.polarId &&
                    (widget.controller.participantId == null ||
                        v.participantId == widget.controller.participantId ||
                        v.participantId == null),
              )
              .toList();
          final active = widget.controller.activeCalibration;
          if (active != null && active.deviceId == widget.controller.polarId) {
            _name.text = active.name;
            _positions
              ..clear()
              ..addAll({
                for (final entry in active.positions.entries)
                  entry.key: List<double>.of(entry.value),
              });
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = '$e');
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _capture(String label) async {
    final c = widget.controller;
    final deviceId = c.polarId;
    if (!c.connected || deviceId == null) {
      setState(() => _message = 'Connect the H10 first.');
      return;
    }
    setState(() {
      _capturing = true;
      _message = 'Hold still on ${label.toLowerCase()} for 4 seconds…';
    });
    final samples = <List<int>>[];
    final rate = c.latestAcceleration?.sampleRate ?? 50;
    final subscription = c.polar.accelerationStream.listen((
      H10Acceleration frame,
    ) {
      if (c.polarId == deviceId) {
        samples.addAll(frame.samples);
      }
    });
    try {
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!mounted) {
        return;
      }
      if (!c.connected || c.polarId != deviceId) {
        throw const FormatException('H10 disconnected during capture.');
      }
      final gravity = stableGravity(samples, minimumSamples: rate * 3);
      for (final entry in _positions.entries) {
        if (entry.key != label && vectorAngle(gravity, entry.value) < 35) {
          throw FormatException(
            'Too similar to ${entry.key}. Check the position and strap placement.',
          );
        }
      }
      setState(() {
        _positions[label] = gravity;
        _message = '$label captured.';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _message = '$e');
      }
    } finally {
      await subscription.cancel();
      if (mounted) {
        setState(() => _capturing = false);
      }
    }
  }

  Future<void> _save() async {
    final c = widget.controller;
    if (c.polarId == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      final calibration = PostureCalibration(
        id: DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
        deviceId: c.polarId!,
        name: _name.text.trim().isEmpty
            ? 'Strap calibration'
            : _name.text.trim(),
        participantId: c.participantId,
        positions: Map.from(_positions),
      );
      await c.selectCalibration(calibration);
      if (mounted) {
        setState(() => _message = 'Saved and selected.');
        await _load();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _message = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('H10 posture calibration')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Keep the strap in its normal wearing position. Settle into each position, then capture. Back, right and left are required. Upright and prone are optional.',
        ),
        const SizedBox(height: 12),
        Text(
          widget.controller.activeCalibration == null
              ? 'Connect the H10 to restore its saved calibration, or capture a new one.'
              : 'Using saved calibration: ${widget.controller.activeCalibration!.name}',
        ),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Calibration name'),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_message!),
          ),
        for (final label in postureLabels)
          ListTile(
            title: Text(label),
            subtitle: Text(
              _positions.containsKey(label) ? 'Captured' : 'Not captured',
            ),
            trailing: OutlinedButton(
              onPressed: _capturing || _saving ? null : () => _capture(label),
              child: const Text('Capture'),
            ),
          ),
        FilledButton(
          onPressed:
              _capturing ||
                  _saving ||
                  ![
                    'On back',
                    'Right side',
                    'Left side',
                  ].every(_positions.containsKey)
              ? null
              : _save,
          child: const Text('Save calibration'),
        ),
        if (_saved.isNotEmpty)
          const ListTile(title: Text('Saved for this H10')),
        for (final item in _saved)
          ListTile(
            title: Text(item.name),
            subtitle: Text(
              item.participantId == null
                  ? 'Local calibration'
                  : 'Participant calibration',
            ),
            trailing: TextButton(
              onPressed: _capturing || _saving
                  ? null
                  : () async {
                      try {
                        await widget.controller.selectCalibration(item);
                        await _load();
                        if (mounted) {
                          setState(() => _message = 'Selected ${item.name}');
                        }
                      } catch (e) {
                        if (mounted) {
                          setState(() => _message = '$e');
                        }
                      }
                    },
              child: const Text('Use'),
            ),
          ),
        const SizedBox(height: 12),
        const Text(
          'Estimates may be Moving or Unknown. Recalibrate after rotating or repositioning the strap. Original acceleration is preserved.',
        ),
      ],
    ),
  );
}
