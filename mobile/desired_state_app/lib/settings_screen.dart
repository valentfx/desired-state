import 'package:flutter/material.dart';

import 'processing_screen.dart';
import 'preferences_screen.dart';
import 'participant_tools.dart';
import 'practice_screen.dart';
import 'history_screen.dart';
import 'session_controller.dart';
import 'session_history.dart';
import 'recording_assignments_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('Participants'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => ParticipantsScreen(
                store: ParticipantStore(
                  directoryProvider: controller.directoryProvider,
                ),
                onManageRecordings: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        RecordingAssignmentsScreen(controller: controller),
                  ),
                ),
                onViewSessions: (profile) => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => HistoryScreen(
                      controller: controller,
                      initialParticipantId: profile.id,
                      analyze: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.spa_outlined),
          title: const Text('Practice'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => PracticeScreen(controller: controller),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.dashboard_customize_outlined),
          title: const Text('Customize Live'),
          subtitle: const Text(
            'Visible metrics; recording remains independent',
          ),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => PreferencesScreen(controller: controller),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.save_outlined),
          title: const Text('Recording defaults'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => PreferencesScreen(
                controller: controller,
                streams: const [
                  'heart',
                  'ecg',
                  'acc',
                  'posture',
                  'ring',
                  'muse',
                  'pmd',
                ],
              ),
            ),
          ),
        ),
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
