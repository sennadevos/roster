import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../voice/engines.dart';
import '../widgets/status.dart';

/// A bottom sheet on a phone, a dialog on a wide window.
Future<void> showCaptureSheet(BuildContext context) => MediaQuery.sizeOf(context).width >= splitViewWidth
    ? showDialog<void>(
        context: context,
        builder: (_) => const Dialog(clipBehavior: Clip.antiAlias, child: SizedBox(width: 560, child: CaptureSheet())),
      )
    : showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const CaptureSheet(),
      );

/// `POST /v1/capture`: say (or type) a thought, and Jev sends it to the agent
/// whose work it belongs to, or starts a new agent with it. When Jev is not
/// sure, its candidates are offered to pick from.
///
/// On a phone with a speech recognizer it listens as soon as it opens, and
/// sends once you pause; tapping the field stops listening, to edit first.
class CaptureSheet extends StatefulWidget {
  const CaptureSheet({super.key});

  @override
  State<CaptureSheet> createState() => _CaptureSheetState();
}

class _CaptureSheetState extends State<CaptureSheet> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  SpeechInput? _input;
  bool _listening = false;
  bool _busy = false;

  /// Jev was unsure: where it might go, best first.
  List<(String, double)>? _candidates;

  @override
  void initState() {
    super.initState();
    final engines = voiceEngines;
    if (engines != null) {
      _input = engines().$1;
      WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
    }
    _focus.addListener(() {
      if (_focus.hasFocus && _listening) _stopListening();
    });
  }

  @override
  void dispose() {
    unawaited(_input?.stop());
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _listen() async {
    final input = _input;
    if (input == null || _listening || _busy) return;
    if (!await input.available()) {
      if (mounted) showError(context, 'No speech recognizer, or no microphone permission: type it instead.');
      return;
    }
    final before = _text.text.trim();
    setState(() {
      _listening = true;
      _candidates = null;
    });
    final said = await input.listen(onPartial: (w) {
      if (mounted) _text.text = [before, w].where((s) => s.isNotEmpty).join(' ');
    });
    if (!mounted || !_listening) return;
    setState(() => _listening = false);
    _text.text = [before, said].where((s) => s.isNotEmpty).join(' ');
    // A pause ends it: send what was said, as voice chat does.
    if (said.isNotEmpty) await _send();
  }

  Future<void> _stopListening() async {
    setState(() => _listening = false);
    await _input?.stop();
  }

  Future<void> _send({String? to, bool newAgent = false}) async {
    final text = _text.text.trim();
    if (text.isEmpty || _busy) return;
    final client = AppScope.read(context).client!;
    if (_listening) await _stopListening();
    setState(() => _busy = true);
    try {
      final got = await client.capture(text, to: to, newAgent: newAgent);
      if (!mounted) return;
      final action = got['action'];
      if (action == 'ask') {
        setState(() => _candidates = [
              for (final c in (got['candidates'] as List? ?? const []))
                if (c is Map) ('${c['agent']}', (c['p'] as num?)?.toDouble() ?? 0),
            ]);
        return;
      }
      final agent = '${got['agent'] ?? ''}';
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(
        content: Text(action == 'started' ? 'Started $agent' : 'Sent to $agent'),
        action: agent.isEmpty ? null : SnackBarAction(label: 'Open', onPressed: () => openAgent(agent)),
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final candidates = _candidates;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Capture', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Say or type a thought. Jev sends it to the agent it belongs to, or starts a new one.',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _text,
            focusNode: _focus,
            minLines: 3,
            maxLines: 8,
            autofocus: _input == null,
            enabled: !_busy,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: _listening ? 'Listening… pause to send' : 'What is on your mind?',
              border: const OutlineInputBorder(),
            ),
          ),
          if (candidates != null) ...[
            const SizedBox(height: 14),
            Text('Jev is not sure where this goes. Send it to:', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (agent, p) in candidates)
                ActionChip(
                  avatar: Icon(agent == 'new' ? Icons.add : Icons.smart_toy_outlined, size: 18),
                  label: Text('${agent == 'new' ? 'a new agent' : agent.split('@').first} · ${(p * 100).round()}%'),
                  onPressed: _busy ? null : () => agent == 'new' ? _send(newAgent: true) : _send(to: agent),
                ),
              if (!candidates.any((c) => c.$1 == 'new'))
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('a new agent'),
                  onPressed: _busy ? null : () => _send(newAgent: true),
                ),
            ]),
          ],
          const SizedBox(height: 14),
          Row(children: [
            if (_input != null)
              IconButton.filledTonal(
                onPressed: _busy ? null : (_listening ? _stopListening : _listen),
                icon: Icon(_listening ? Icons.stop_rounded : Icons.mic_rounded),
                tooltip: _listening ? 'Stop listening' : 'Talk',
              ),
            const Spacer(),
            if (_busy) const Padding(padding: EdgeInsets.only(right: 12), child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            FilledButton.icon(
              onPressed: _busy ? null : () => _send(),
              icon: const Icon(Icons.send_rounded, size: 18),
              label: const Text('Send'),
            ),
          ]),
        ],
      ),
    );
  }
}
