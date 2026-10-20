import 'dart:async';

import 'package:flutter/material.dart';

import '../models/agent.dart';
import '../theme.dart';
import 'status.dart';

/// A key as printed on a keyboard, for shortcut hints.
class Keycap extends StatelessWidget {
  const Keycap(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      constraints: const BoxConstraints(minWidth: 18),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Text(label,
          textAlign: TextAlign.center,
          style: mono(fontSize: 11, height: 1.4, color: cs.onSurfaceVariant)),
    );
  }
}

/// Keys and what they do, in a row: `j` `k` move · `Enter` open.
class ShortcutHints extends StatelessWidget {
  const ShortcutHints(this.hints, {super.key});

  final List<(List<String>, String)> hints;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 14,
      runSpacing: 8,
      children: [
        for (final (keys, what) in hints)
          Row(mainAxisSize: MainAxisSize.min, children: [
            for (final k in keys) Padding(padding: const EdgeInsets.only(right: 3), child: Keycap(k)),
            const SizedBox(width: 3),
            Text(what, style: style),
          ]),
      ],
    );
  }
}

/// Unread mail: an envelope and the count.
class UnreadPill extends StatelessWidget {
  const UnreadPill(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: '$count unread',
      child: Container(
        padding: const EdgeInsets.fromLTRB(5, 1, 6, 1),
        decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.mail, size: 11, color: cs.onPrimary),
          const SizedBox(width: 3),
          Text('$count', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: cs.onPrimary, height: 1.3)),
        ]),
      ),
    );
  }
}

/// A small rounded label.
class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.color, this.icon, this.tooltip});

  final String label;
  final Color? color;
  final IconData? icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = color ?? cs.onSurfaceVariant;
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: c), const SizedBox(width: 4)],
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: c, height: 1.35)),
        ),
      ]),
    );
    return tooltip == null ? tag : Tooltip(message: tooltip!, child: tag);
  }
}

/// A subagent: never an agent of its own, so a quiet line with a spinner
/// while it runs and a tick when done.
class SubagentLine extends StatelessWidget {
  const SubagentLine(this.sub, {super.key, this.dense = false});

  final Subagent sub;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(color: cs.outline, fontSize: dense ? 11.5 : 12);
    return Tooltip(
      message: '${sub.type} subagent${sub.running ? ', running' : ', done'}\n${sub.label}',
      child: Row(
        children: [
          SizedBox(
            width: 14,
            child: sub.running
                ? const Center(child: RunningSpinner(size: 9))
                : Icon(Icons.check, size: 12, color: statusColors(context).done),
          ),
          const SizedBox(width: 6),
          Text(sub.type, style: style?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
          const SizedBox(width: 6),
          Expanded(child: Text(sub.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
        ],
      ),
    );
  }
}

/// Grey bars in the shape of what is loading, gently fading.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, required this.child});

  final Widget child;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100), lowerBound: 0.45);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) {
      _c.repeat(reverse: true);
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _c, child: widget.child);
}

class Bar extends StatelessWidget {
  const Bar({super.key, required this.width, this.height = 10});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(height / 2),
        ),
      );
}

/// Shows [child] only once it has been wanted for [delay], so a blip
/// (a reconnect that takes half a second) does not flash on screen.
class Delayed extends StatefulWidget {
  const Delayed({super.key, required this.child, this.delay = const Duration(seconds: 2)});

  final Widget child;
  final Duration delay;

  @override
  State<Delayed> createState() => _DelayedState();
}

class _DelayedState extends State<Delayed> {
  bool _show = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () => setState(() => _show = true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: _show ? widget.child : const SizedBox(width: double.infinity),
      );
}
