import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'state_feedback.dart';

class StateRatingBar extends StatelessWidget {
  const StateRatingBar({
    super.key,
    required this.question,
    required this.value,
    required this.onChanged,
  });
  final FeedbackQuestion question;
  final int? value;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(question.label),
      const SizedBox(height: 8),
      Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var n = question.minimum; n <= 10; n++)
            ChoiceChip(
              label: Text('$n'),
              selected: value == n,
              onSelected: (_) => onChanged(n),
            ),
        ],
      ),
      Text('${question.minimum} = ${question.low} · 10 = ${question.high}'),
      if (value == null) const Text('Optional — no answer selected.'),
    ],
  );
}

class SessionSetupResult {
  const SessionSetupResult(this.context, this.value, this.ratedAt);
  final SessionContext context;
  final int? value;
  final DateTime? ratedAt;
}

Future<SessionSetupResult?> showSessionSetup(
  BuildContext context,
  SessionContext initial, {
  bool ratingOnly = false,
}) => showModalBottomSheet<SessionSetupResult>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _SessionSetup(initial: initial, ratingOnly: ratingOnly),
);

class _SessionSetup extends StatefulWidget {
  const _SessionSetup({required this.initial, this.ratingOnly = false});
  final bool ratingOnly;
  final SessionContext initial;
  @override
  State<_SessionSetup> createState() => _SessionSetupState();
}

class _SessionSetupState extends State<_SessionSetup> {
  late String purpose = widget.initial.purpose, type = widget.initial.type;
  late FeedbackQuestion question = widget.initial.question;
  late final goal = TextEditingController(text: widget.initial.desiredState);
  int? value;
  DateTime? ratedAt;
  @override
  void dispose() {
    goal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.ratingOnly ? 'How do I feel?' : 'Session setup',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (!widget.ratingOnly) ...[
              DropdownButtonFormField<String>(
                initialValue: purpose,
                decoration: const InputDecoration(labelText: 'Purpose'),
                items: [
                  for (final p in [
                    'personal_tracking',
                    'experiment',
                    'device_test',
                  ])
                    DropdownMenuItem(
                      value: p,
                      child: Text(p.replaceAll('_', ' ')),
                    ),
                ],
                onChanged: (v) => setState(() => purpose = v!),
              ),
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Session type'),
                items: [
                  for (final t in [
                    'monitoring',
                    'sleep',
                    'relaxation',
                    'exercise',
                    'sensor_comparison',
                    'other',
                  ])
                    DropdownMenuItem(
                      value: t,
                      child: Text(t.replaceAll('_', ' ')),
                    ),
                ],
                onChanged: (v) => setState(() => type = v!),
              ),
            ],
            if (!widget.ratingOnly || question == FeedbackQuestion.goal) ...[
              Wrap(
                spacing: 6,
                children: [
                  for (final label in [
                    'calm',
                    'focused',
                    'energized',
                    'restful',
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: goal.text == label,
                      onSelected: (_) => setState(() {
                        goal.text = label;
                        value = null;
                        ratedAt = null;
                      }),
                    ),
                ],
              ),
              TextField(
                controller: goal,
                decoration: const InputDecoration(
                  labelText: 'Desired state',
                  hintText: 'For example calm, focused, restful',
                ),
                onChanged: (_) => setState(() {
                  value = null;
                  ratedAt = null;
                }),
              ),
            ],
            DropdownButtonFormField<FeedbackQuestion>(
              initialValue: question,
              decoration: const InputDecoration(labelText: 'Rating question'),
              items: [
                for (final q in FeedbackQuestion.values)
                  DropdownMenuItem(
                    value: q,
                    child: Text(q.id.replaceAll('_', ' ')),
                  ),
              ],
              onChanged: (v) => setState(() {
                question = v!;
                value = null;
                ratedAt = null;
              }),
            ),
            const SizedBox(height: 12),
            if (question != FeedbackQuestion.goal ||
                goal.text.trim().isNotEmpty)
              StateRatingBar(
                question: question,
                value: value,
                onChanged: (n) => setState(() {
                  value = n;
                  ratedAt = DateTime.now();
                }),
              )
            else
              const Text(
                'Enter a desired state to use goal closeness, or choose another question. Recording does not require a rating.',
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: widget.ratingOnly && value == null
                  ? null
                  : () => Navigator.pop(
                      context,
                      SessionSetupResult(
                        SessionContext(
                          purpose: purpose,
                          type: type,
                          desiredState: goal.text,
                          question: question,
                        ),
                        value,
                        ratedAt,
                      ),
                    ),
              child: Text(
                widget.ratingOnly ? 'Save rating' : 'Use for next session',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<int?> showStateRating(BuildContext context, FeedbackQuestion question) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StateRatingBar(
              question: question,
              value: null,
              onChanged: (n) {
                Navigator.pop(context, n);
              },
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Skip'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Review is shared by phone History and Windows; later answers are follow-ups.
class SessionFeedbackScreen extends StatefulWidget {
  const SessionFeedbackScreen({
    super.key,
    required this.directory,
    required this.sessionId,
    this.allowWrite = true,
  });
  final Directory directory;
  final String sessionId;
  final bool allowWrite;
  @override
  State<SessionFeedbackScreen> createState() => _SessionFeedbackScreenState();
}

class _SessionFeedbackScreenState extends State<SessionFeedbackScreen> {
  late final store = StateFeedbackStore(widget.directory, widget.sessionId);
  late Future<List<Map<String, dynamic>>> rows = store.read();
  bool busy = false;
  Future<void> _add() async {
    setState(() => busy = true);
    try {
      final manifest = jsonDecode(
        await File('${widget.directory.path}/manifest.json').readAsString(),
      ) as Map<String, dynamic>;
      final config = manifest['session_context'] as Map?;
      final id = (config?['rating_question'] as Map?)?['id'];
      var question = FeedbackQuestion.values
          .where((q) => q.id == id)
          .firstOrNull;
      if (!mounted) return;
      var desiredState = config?['desired_state'] as String?;
      int? value;
      if (question == null ||
          (question == FeedbackQuestion.goal &&
              (desiredState ?? '').trim().isEmpty)) {
        final selection = await showSessionSetup(
          context,
          const SessionContext(question: FeedbackQuestion.energy),
          ratingOnly: true,
        );
        if (selection == null || !mounted) return;
        question = selection.context.question;
        desiredState = selection.context.desiredState;
        if (question == FeedbackQuestion.goal && desiredState.trim().isEmpty) {
          return;
        }
        value = selection.value;
      }
      if (!mounted) return;
      final effectiveQuestion = question;
      value ??= await showStateRating(context, effectiveQuestion);

      if (value == null) {
        return;
      }
      await store.add(
        question: effectiveQuestion,
        value: value,
        phase: 'followup',
        source: 'session_review',
        participantId: manifest['participant_id'] as String?,
        desiredState: desiredState,
      );
      if (mounted) {
        setState(() => rows = store.read());
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Feedback not saved: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('State feedback')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: rows,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Subjective ratings. Compare only the same question and goal; these are not sensor measurements.',
            ),
            if (snapshot.data!.isEmpty)
              const Text('No state ratings recorded.'),
            for (final row in snapshot.data!)
              ListTile(
                title: Text(
                  '${(row['question'] as Map)['text']}  ${row['value']}/10',
                ),
                subtitle: Text(
                  '${row['phase']} · ${row['desired_state'] ?? ''}\n${row['event_utc']} · ${row['source']}',
                ),
              ),
            if (widget.allowWrite)
              FilledButton(
                onPressed: busy ? null : _add,
                child: const Text('Add follow-up rating'),
              ),
          ],
        );
      },
    ),
  );
}
