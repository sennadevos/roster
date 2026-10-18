import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/transcript.dart';

/// A transcript entry: user on the right, assistant on the left (markdown),
/// a tool call as one compact row that opens to its result.
class MessageTile extends StatelessWidget {
  const MessageTile(this.message, {super.key});

  final Message message;

  @override
  Widget build(BuildContext context) {
    return switch (message.role) {
      'user' => _Bubble(message, mine: true),
      'tool' => ToolRow(message),
      _ => _Bubble(message, mine: false),
    };
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.message, {required this.mine});

  final Message message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: width * (mine ? 0.85 : 0.94)),
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: mine
            ? SelectableText(message.text, style: TextStyle(color: cs.onPrimaryContainer))
            : MarkdownBody(
                data: message.text,
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  code: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  codeblockDecoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
      ),
    );
  }
}

class ToolRow extends StatefulWidget {
  const ToolRow(this.message, {super.key});

  final Message message;

  @override
  State<ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<ToolRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final result = m.result;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: result == null || result.isEmpty ? null : () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  Icon(m.error ? Icons.error_outline : Icons.terminal, size: 16, color: m.error ? cs.error : cs.outline),
                  const SizedBox(width: 6),
                  Text(m.tool ?? 'tool', style: mono?.copyWith(fontWeight: FontWeight.bold, color: cs.outline)),
                  const SizedBox(width: 6),
                  Expanded(child: Text(m.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono)),
                  if (result == null)
                    Text('…', style: mono?.copyWith(color: cs.outline))
                  else if (result.isNotEmpty)
                    Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: cs.outline),
                ],
              ),
            ),
          ),
          if (_open && result != null)
            Container(
              margin: const EdgeInsets.only(left: 22, bottom: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText('${m.text}\n\n$result', style: mono?.copyWith(color: m.error ? cs.error : null)),
            ),
        ],
      ),
    );
  }
}
