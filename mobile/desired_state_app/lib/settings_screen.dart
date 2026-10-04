import 'package:flutter/material.dart';

import 'processing_screen.dart';
import 'session_controller.dart';
import 'session_history.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('Processing & plots'),
          subtitle: const Text('Metrics, screening, plot options and presets'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => ProcessingScreen(controller: controller),
            ),
          ),
        ),
        ExpansionTile(
          title: const Text('Recording storage'),
          children: [
            FutureBuilder<String>(
              future: SessionHistoryRepository(
                directoryProvider: controller.directoryProvider,
              ).storageDiagnostics(),
              builder: (context, snapshot) => Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  snapshot.hasError
                      ? '${snapshot.error}'
                      : snapshot.data ?? 'Loading…',
                ),
              ),
            ),
          ],
        ),
        const ListTile(
          title: Text('Original data is preserved'),
          subtitle: Text(
            'Processing affects derived views. Participant corrections are recorded separately and included in exports.',
          ),
        ),
      ],
    ),
  );
}
