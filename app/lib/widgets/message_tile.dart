import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../models/transcript.dart';
import '../platform/platform.dart';
import '../theme.dart';
import 'status.dart';

/// How wide the conversation column gets on a wide window, so lines stay
/// readable; it sits in the middle of the pane, with the dialog card and
/// the composer under it at the same width.
const conversationWidth = 880.0;

/// What is selected in the conversation now, for Ctrl+C.
///
/// Each message's text is selectable by itself (SelectableText, selectable
/// markdown), never through a SelectionArea over the conversation: Flutter's
/// SelectableRegion fails a null check when its parts are torn down while
/// rows come and go during a turn, and the release build then paints the
/// conversation gray.
final conversationSelection = ValueNotifier<String?>(null);

/// Keeps the conversation still when its text is clicked: selectable text
/// takes focus, and focus asks the list to scroll it (and a margin) into
/// view. Here that request stops.
class StayPut extends SingleChildRenderObjectWidget {
  const StayPut({super.key, required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _StayPut();
}

class _StayPut extends RenderProxyBox {
  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {}
}

void _selected(String? text, TextSelection selection) {
  conversationSelection.value =
      text == null || !selection.isValid || selection.isCollapsed ? null : selection.textInside(text);
}

/// Centres [child] in a column [conversationWidth] wide.
Widget inColumn(Widget child) => Center(
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: conversationWidth), child: child),
    );

/// What the user typed: a bubble on the right.
class UserBubble extends StatelessWidget {
  const UserBubble(this.text, {super.key, this.pending = false, this.queued = false, this.withdrawn = false});

  final String text;

  /// Sent but not yet in the transcript.
  final bool pending;

  /// In the transcript, waiting for Claude to take it in at its next step.
  final bool queued;

  /// Pulled back into the agent's input to edit: never sent as it was.
  final bool withdrawn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return LayoutBuilder(builder: (context, box) {
      return Align(
        alignment: Alignment.centerRight,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: pending || withdrawn ? 0.6 : queued ? 0.8 : 1,
          child: Container(
            constraints: BoxConstraints(maxWidth: min(box.maxWidth * 0.82, 620)),
            margin: const EdgeInsets.fromLTRB(48, 8, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: Color.alphaBlend(cs.primary.withValues(alpha: dark ? 0.22 : 0.10), cs.surface),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(text,
                    onSelectionChanged: (sel, _) => _selected(text, sel),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface,
                      decoration: withdrawn ? TextDecoration.lineThrough : null,
                    )),
                if (pending)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(Icons.schedule, size: 12, color: cs.outline),
                  ),
                if (queued || withdrawn)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(withdrawn ? Icons.undo : Icons.schedule, size: 12, color: cs.outline),
                      const SizedBox(width: 4),
                      Text(withdrawn ? 'taken back to edit' : 'queued: Claude takes it in at its next step',
                          style: theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
                    ]),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

/// Something that happened rather than was said: a background task's
/// summary, a slash command's output, a compaction. A quiet line of its own.
class EventLine extends StatelessWidget {
  const EventLine(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.info_outline, size: 14, color: cs.outline),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              text,
              maxLines: 6,
              onSelectionChanged: (sel, _) => _selected(text, sel),
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// What Claude wrote: markdown on the page itself, no bubble, so long
/// answers read like a document.
class AssistantBlock extends StatelessWidget {
  const AssistantBlock(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 32, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: MarkdownBody(
            data: text,
            selectable: true,
            onSelectionChanged: (t, sel, _) => _selected(t, sel),
            styleSheet: markdownStyle(context),
            builders: {'pre': CodeBlockBuilder()},
            onTapLink: (text, href, title) {
              final url = Uri.tryParse(href ?? '');
              if (url != null && const {'http', 'https', 'mailto'}.contains(url.scheme)) openLink(url);
            },
          ),
        ),
      ),
    );
  }
}

MarkdownStyleSheet markdownStyle(BuildContext context) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final body = theme.textTheme.bodyMedium!.copyWith(color: cs.onSurface, height: 1.5);
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body,
    listBullet: body,
    h1: theme.textTheme.titleLarge,
    h2: theme.textTheme.titleMedium?.copyWith(fontSize: 17),
    h3: theme.textTheme.titleSmall?.copyWith(fontSize: 15),
    h1Padding: const EdgeInsets.only(top: 8),
    h2Padding: const EdgeInsets.only(top: 8),
    h3Padding: const EdgeInsets.only(top: 6),
    blockSpacing: 10,
    code: body.copyWith(
      fontFamily: monoFont,
      fontFeatures: monoFeatures,
      fontSize: body.fontSize! * 0.88,
      backgroundColor: cs.surfaceContainerHigh,
      color: cs.onSurface,
    ),
    // The code block draws itself (CodeBlockBuilder).
    codeblockDecoration: const BoxDecoration(),
    codeblockPadding: EdgeInsets.zero,
    blockquote: body.copyWith(color: cs.onSurfaceVariant),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: cs.primary.withValues(alpha: 0.6), width: 3)),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
    tableHead: body.copyWith(fontWeight: FontWeight.w600),
    tableBody: body,
    tableBorder: TableBorder.all(color: cs.outlineVariant),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    tableColumnWidth: const IntrinsicColumnWidth(),
    horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: cs.outlineVariant))),
    a: body.copyWith(color: cs.primary, decoration: TextDecoration.underline),
  );
}

/// A fenced code block: monospace on its own background, the language on
/// top, a copy button, and sideways scrolling instead of wrapping.
class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) => const SizedBox.shrink();

  @override
  Widget? visitElementAfterWithContext(
      BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    var code = element.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    String? lang;
    final first = element.children?.firstOrNull;
    if (first is md.Element) {
      final cls = first.attributes['class'];
      if (cls != null && cls.startsWith('language-')) lang = cls.substring('language-'.length);
    }
    return CodeBlock(code: code, language: lang);
  }
}

class CodeBlock extends StatefulWidget {
  const CodeBlock({super.key, required this.code, this.language, this.maxHeight, this.error = false});

  final String code;
  final String? language;
  final double? maxHeight;
  final bool error;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  final _h = ScrollController();
  final _v = ScrollController();

  @override
  void dispose() {
    _h.dispose();
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final color = widget.error ? statusColors(context).blocked : cs.onSurface;
    final style = mono(fontSize: 12.5, height: 1.5, color: color);
    Widget body = Scrollbar(
      controller: _h,
      child: SingleChildScrollView(
        controller: _h,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: Text(widget.code, style: style, softWrap: false),
      ),
    );
    if (widget.maxHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight!),
        child: Scrollbar(
          controller: _v,
          child: SingleChildScrollView(controller: _v, child: body),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 30,
            child: Row(
              children: [
                const SizedBox(width: 14),
                Text(widget.language ?? '', style: theme.textTheme.labelSmall?.copyWith(color: cs.outline)),
                const Spacer(),
                CopyButton(text: widget.code),
                const SizedBox(width: 2),
              ],
            ),
          ),
          body,
        ],
      ),
    );
  }
}

/// Copies [text]; shows a tick for a moment after.
class CopyButton extends StatefulWidget {
  const CopyButton({super.key, required this.text, this.label = 'Copy'});

  final String text;
  final String label;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  bool _done = false;

  Future<void> _copy() async {
    await copyText(widget.text);
    if (!mounted) return;
    setState(() => _done = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _done = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: _copy,
      tooltip: _done ? 'Copied' : widget.label,
      visualDensity: VisualDensity.compact,
      iconSize: 15,
      style: IconButton.styleFrom(minimumSize: const Size(28, 28), padding: EdgeInsets.zero),
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: _done
            ? Icon(Icons.check, key: const ValueKey(1), color: statusColors(context).done)
            : Icon(Icons.content_copy_outlined, key: const ValueKey(0), color: cs.outline),
      ),
    );
  }
}

/// An icon per tool, so a run of calls reads at a glance.
IconData toolIcon(String? tool) {
  final t = tool ?? '';
  if (t.startsWith('mcp__')) return Icons.extension_outlined;
  return switch (t) {
    'Bash' || 'BashOutput' || 'KillShell' => Icons.terminal,
    'Read' => Icons.description_outlined,
    'Edit' || 'MultiEdit' => Icons.edit_outlined,
    'Write' => Icons.note_add_outlined,
    'NotebookEdit' => Icons.edit_note,
    'Grep' => Icons.manage_search,
    'Glob' || 'LS' => Icons.folder_open_outlined,
    'WebFetch' => Icons.public,
    'WebSearch' => Icons.travel_explore,
    'Task' || 'Agent' => Icons.account_tree_outlined,
    'TodoWrite' => Icons.checklist,
    'AskUserQuestion' => Icons.help_outline,
    'Skill' => Icons.auto_awesome_outlined,
    'ExitPlanMode' => Icons.map_outlined,
    _ => Icons.build_outlined,
  };
}

/// A run of tool calls, one compact line each. A long run shows its last
/// few, with the rest behind one line.
class ToolGroup extends StatefulWidget {
  const ToolGroup(this.calls, {super.key});

  final List<Message> calls;

  @override
  State<ToolGroup> createState() => _ToolGroupState();
}

class _ToolGroupState extends State<ToolGroup> {
  bool _all = false;
  static const _shown = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final calls = widget.calls;
    final hidden = _all || calls.length <= _shown + 1 ? 0 : calls.length - _shown;
    final counts = <String, int>{};
    for (final c in calls.take(hidden)) {
      counts[c.tool ?? 'tool'] = (counts[c.tool ?? 'tool'] ?? 0) + 1;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 16, 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hidden > 0)
                _Line(
                  onTap: () => setState(() => _all = true),
                  icon: Icons.unfold_more,
                  iconColor: cs.outline,
                  child: Text(
                    '$hidden more · ${counts.entries.map((e) => e.value > 1 ? '${e.key} ×${e.value}' : e.key).join(', ')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
                  ),
                ),
              for (final c in calls.skip(hidden)) ToolRow(c, key: ValueKey(c.key)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.iconColor, required this.child, this.onTap, this.trailing});

  final IconData icon;
  final Color iconColor;
  final Widget child;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          children: [
            Icon(icon, size: 15, color: iconColor),
            const SizedBox(width: 9),
            Expanded(child: child),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// One tool call: its icon, name and one-line summary; opens to its result.
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
    final err = statusColors(context).blocked;
    final code = mono(fontSize: 12.5, color: cs.onSurfaceVariant);
    final result = m.result;
    final running = result == null;
    final canOpen = result != null && result.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Line(
          onTap: canOpen ? () => setState(() => _open = !_open) : null,
          icon: m.error ? Icons.error_outline : toolIcon(m.tool),
          iconColor: m.error ? err : cs.outline,
          trailing: running
              ? const Padding(padding: EdgeInsets.only(left: 8), child: RunningSpinner(size: 11))
              : canOpen
                  ? AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(Icons.expand_more, size: 16, color: cs.outline),
                    )
                  : null,
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                text: m.tool ?? 'tool',
                style: code.copyWith(fontWeight: FontWeight.w600, color: m.error ? err : cs.onSurfaceVariant),
              ),
              const TextSpan(text: '  '),
              TextSpan(text: m.text.replaceAll('\n', ' '), style: code.copyWith(color: cs.outline)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open && canOpen
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(30, 2, 0, 8),
                  child: CodeBlock(
                    code: m.text.contains('\n') || m.text.length > 80 ? '${m.text}\n\n$result' : result,
                    language: m.error ? 'error' : null,
                    error: m.error,
                    maxHeight: 360,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// A quiet time label between messages far apart.
class TimeSeparator extends StatelessWidget {
  const TimeSeparator(this.time, {super.key});

  final DateTime time;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Center(
        child: Tooltip(
          message: fullTime(time),
          child: Text(clockTime(time), style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
        ),
      ),
    );
  }
}
