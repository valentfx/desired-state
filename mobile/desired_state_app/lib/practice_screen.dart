import 'package:flutter/material.dart';

import 'session_controller.dart';

class PracticeLiveControls extends StatelessWidget {
  const PracticeLiveControls({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller.practice,
    builder: (context, _) {
      final p = controller.practice;
      if (!p.running) return const SizedBox.shrink();
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Text(p.paused ? 'Practice paused' : '${p.phase} · ${p.elapsed}s'),
              LinearProgressIndicator(value: p.progress),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: p.paused ? p.resume : p.pause,
                    child: Text(
                      p.paused ? 'Resume practice' : 'Pause practice',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: p.stop,
                    child: const Text('Stop practice'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen> {
  late int _inhale = widget.controller.practice.inhaleSeconds;
  late int _exhale = widget.controller.practice.exhaleSeconds;
  late bool _vibration = widget.controller.practice.vibration;
  late bool _sound = widget.controller.practice.sound;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Practice')),
    body: ListenableBuilder(
      listenable: widget.controller.practice,
      builder: (context, _) {
        final p = widget.controller.practice;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Breathing pacer', style: TextStyle(fontSize: 22)),
            const Text(
              'Choose a comfortable pace. Visual pacing, phone vibration and optional system clicks. Recording is controlled separately in Live.',
            ),
            const SizedBox(height: 16),
            Text('Inhale: $_inhale seconds'),
            Slider(
              value: _inhale.toDouble(),
              min: 2,
              max: 10,
              divisions: 8,
              onChanged: p.running
                  ? null
                  : (v) => setState(() => _inhale = v.round()),
            ),
            Text('Exhale: $_exhale seconds'),
            Slider(
              value: _exhale.toDouble(),
              min: 2,
              max: 10,
              divisions: 8,
              onChanged: p.running
                  ? null
                  : (v) => setState(() => _exhale = v.round()),
            ),
            SwitchListTile(
              title: const Text('Phone vibration at phase changes'),
              value: _vibration,
              onChanged: p.running
                  ? null
                  : (v) => setState(() => _vibration = v),
            ),
            SwitchListTile(
              title: const Text('System click at phase changes'),
              subtitle: const Text(
                'Audibility depends on phone sound settings',
              ),
              value: _sound,
              onChanged: p.running ? null : (v) => setState(() => _sound = v),
            ),
            if (!p.running)
              FilledButton(
                onPressed: () {
                  p.configure(
                    inhale: _inhale,
                    exhale: _exhale,
                    haptic: _vibration,
                    audio: _sound,
                  );
                  p.start();
                },
                child: const Text('Start practice'),
              ),
            PracticeLiveControls(controller: widget.controller),
            if (p.running)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Container(
                    width: 80 + p.progress * 100,
                    height: 80 + p.progress * 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.primaryContainer,
                    ),
                    alignment: Alignment.center,
                    child: Text(p.paused ? 'Paused' : p.phase),
                  ),
                ),
              ),
            const Text(
              'Practice keeps running when you change screens. Pausing recording pauses the practice; stopping recording stops it.',
            ),
          ],
        );
      },
    ),
  );
}
