import 'package:flutter/material.dart';

import '../voice/voice_session.dart';
import 'message_tile.dart' show conversationWidth;

/// Above the composer while voice chat runs: what it does now, what it
/// hears, and a stop button. Tapping the bar while it speaks or waits cuts in
/// and listens.
class VoiceBar extends StatelessWidget {
  const VoiceBar(this.voice, {super.key});

  final VoiceSession voice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        if (!voice.active && voice.note == null) return const SizedBox(width: double.infinity);
        final (icon, label) = switch (voice.state) {
          VoiceState.off => (Icons.mic_off_outlined, voice.note ?? ''),
          VoiceState.starting => (Icons.mic_none_rounded, 'Starting…'),
          VoiceState.listening => (Icons.mic_rounded, voice.heard.isEmpty ? 'Listening… pause to send' : voice.heard),
          VoiceState.sending => (Icons.arrow_upward_rounded, voice.heard),
          VoiceState.waiting => (Icons.hourglass_top_rounded, 'Claude is on it… tap to talk now'),
          VoiceState.speaking => (Icons.volume_up_rounded, 'Speaking… tap to cut in'),
        };
        final listening = voice.state == VoiceState.listening;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: conversationWidth - 24),
              child: Material(
                color: listening ? cs.primaryContainer : cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: voice.interject,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                    child: Row(children: [
                      Icon(icon, size: 20, color: listening ? cs.onPrimaryContainer : cs.onSurfaceVariant),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: listening ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: voice.active ? () => voice.stop() : () => voice.start(),
                        icon: Icon(voice.active ? Icons.stop_circle_outlined : Icons.mic_none_rounded),
                        tooltip: voice.active ? 'Stop voice chat' : 'Talk again',
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
