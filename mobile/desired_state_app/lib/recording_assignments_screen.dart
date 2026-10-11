import 'package:flutter/material.dart';

import 'participant_tools.dart';
import 'recording_presentation.dart';
import 'session_controller.dart';
import 'session_history.dart';

/// Identity administration belongs to Settings / Participants, outside Analyze.
class RecordingAssignmentsScreen extends StatefulWidget {
  const RecordingAssignmentsScreen({super.key, required this.controller});
  final SessionController controller;
  @override
  State<RecordingAssignmentsScreen> createState() =>
      _RecordingAssignmentsScreenState();
}

class _RecordingAssignmentsScreenState
    extends State<RecordingAssignmentsScreen> {
  late final _repository = SessionHistoryRepository(
    directoryProvider: widget.controller.directoryProvider,
    activeSessionId: () => widget.controller.sessionLogger?.sessionId,
  );
  late Future<List<HistoryEntry>> _entries = _repository.list();
  Future<void> _assign(HistoryEntry entry) async {
    if (_repository.isActive(entry.id)) return;
    final values = await editParticipant(
      context,
      name: entry.participant,
      info: entry.metadata.userInfo,
      participantId: entry.participantId,
      correction: true,
      store: ParticipantStore(
        directoryProvider: widget.controller.directoryProvider,
      ),
    );
    if (values == null || !mounted) return;
    try {
      await _repository.saveMetadata(
        entry,
        participantMetadata(
          entry.metadata,
          values.$1,
          values.$2,
          participantId: values.$3,
        ),
      );
      if (mounted) setState(() => _entries = _repository.list());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Recording assignments')),
    body: FutureBuilder<List<HistoryEntry>>(
      future: _entries,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Recordings could not be read: ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = snapshot.data!;
        if (entries.isEmpty) {
          return const Center(child: Text('No saved recordings'));
        }
        return ListView.builder(
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final active = _repository.isActive(entry.id);
            return ListTile(
              title: Text(recordingTitle(entry)),
              subtitle: Text(
                '${entry.participant} · ${entry.started?.toLocal() ?? "Unknown date"}\n${active ? "Currently recording" : recordingDuration(entry)}',
              ),
              trailing: const Icon(Icons.edit_outlined),
              enabled: !active && entry.readable && entry.editsReadable,
              onTap: () => _assign(entry),
            );
          },
        );
      },
    ),
  );
}
