import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../api/hub_client.dart';
import '../theme.dart';

/// What each status is called in a sentence.
String statusWord(String status) => switch (status) {
      'working' => 'working',
      'blocked' => 'needs you',
      'done' => 'done',
      'idle' => 'idle',
      'gone' => 'gone',
      'left' => 'left',
      'parked' => 'parked',
      _ => 'starting',
    };

/// The status as a small shape in its colour, the shapes `roster list`
/// uses: a dot that pulses while working, a triangle when blocked, a tick
/// when done, a ring when idle, a cross when gone. No pulse when the
/// platform asks for less motion (and in tests, which wait for it to end).
class StatusDot extends StatefulWidget {
  const StatusDot(this.status, {super.key, this.size = 12});

  final String status;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
  AnimationController? _pulse;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(StatusDot old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) _sync();
  }

  void _sync() {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.status == 'working' && !still) {
      _pulse ??= AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
      if (!_pulse!.isAnimating) _pulse!.repeat();
    } else {
      _pulse?.stop();
    }
  }

  @override
  void dispose() {
    _pulse?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = statusColors(context).of(widget.status);
    return Semantics(
      label: widget.status,
      child: SizedBox.square(
        dimension: widget.size * 1.8,
        child: CustomPaint(painter: _DotPainter(widget.status, color, widget.status == 'working' ? _pulse : null)),
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter(this.status, this.color, this.pulse) : super(repaint: pulse);

  final String status;
  final Color color;
  final Animation<double>? pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 1.8 / 2;
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(1.6, r * 0.32)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (status) {
      case 'working':
        final t = Curves.easeOut.transform(pulse?.value ?? 0);
        if (t > 0) {
          canvas.drawCircle(c, r * (0.85 + 0.75 * t), Paint()..color = color.withValues(alpha: 0.4 * (1 - t)));
        }
        canvas.drawCircle(c, r * 0.85, fill);
      case 'blocked':
        final h = r * 2.0;
        final path = Path()
          ..moveTo(c.dx, c.dy - h * 0.55)
          ..lineTo(c.dx + h * 0.58, c.dy + h * 0.45)
          ..lineTo(c.dx - h * 0.58, c.dy + h * 0.45)
          ..close();
        canvas.drawPath(path, fill);
        canvas.drawPath(path, stroke..strokeWidth = r * 0.3);
      case 'done':
        final path = Path()
          ..moveTo(c.dx - r * 0.85, c.dy + r * 0.05)
          ..lineTo(c.dx - r * 0.2, c.dy + r * 0.7)
          ..lineTo(c.dx + r * 0.95, c.dy - r * 0.65);
        canvas.drawPath(path, stroke..strokeWidth = r * 0.4);
      case 'idle':
        canvas.drawCircle(c, r * 0.72, stroke);
      case 'gone':
        final d = r * 0.6;
        canvas.drawLine(c.translate(-d, -d), c.translate(d, d), stroke);
        canvas.drawLine(c.translate(d, -d), c.translate(-d, d), stroke);
      case 'left':
        canvas.drawLine(c.translate(-r * 0.7, 0), c.translate(r * 0.7, 0), stroke);
      case 'parked':
        // Two bars: paused.
        canvas.drawLine(c.translate(-r * 0.35, -r * 0.6), c.translate(-r * 0.35, r * 0.6), stroke);
        canvas.drawLine(c.translate(r * 0.35, -r * 0.6), c.translate(r * 0.35, r * 0.6), stroke);
      default:
        // Starting or unknown: a dashed ring.
        const n = 8;
        for (var k = 0; k < n; k += 2) {
          canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.72), k * 2 * pi / n, 2 * pi / n, false, stroke);
        }
    }
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.status != status || old.color != color || old.pulse != pulse;
}

/// A small spinner for something running, still when motion is reduced.
class RunningSpinner extends StatelessWidget {
  const RunningSpinner({super.key, this.size = 10, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? statusColors(context).working;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return SizedBox.square(
      dimension: size,
      child: CircularProgressIndicator(strokeWidth: 1.6, color: c, value: still ? 0.7 : null),
    );
  }
}

/// A minute clock that runs only while something shows a relative time.
class _Clock extends ChangeNotifier {
  Timer? _timer;
  int _listeners = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_listeners++ == 0) _timer = Timer.periodic(const Duration(seconds: 30), (_) => notifyListeners());
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (--_listeners == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

final _clock = _Clock();

/// `now`, `4m`, `3h`, `2d`: how long ago [t] was, compact.
String ago(DateTime t, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 45) return 'now';
  if (d.inMinutes < 60) return '${max(1, d.inMinutes)}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 30) return '${d.inDays}d';
  return '${d.inDays ~/ 30}mo';
}

/// A relative time that keeps itself current, with the full time on hover.
class Ago extends StatelessWidget {
  const Ago(this.time, {super.key, this.style, this.prefix = ''});

  final DateTime time;
  final TextStyle? style;
  final String prefix;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _clock,
        builder: (context, _) => Tooltip(
          message: fullTime(time),
          child: Text('$prefix${ago(time)}', style: style, maxLines: 1),
        ),
      );
}

String _two(int n) => n.toString().padLeft(2, '0');

String fullTime(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

/// `14:02`, or `Yesterday 14:02`, `Mon 14:02`, `12 Oct 14:02` further back.
String clockTime(DateTime t, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  final days = DateTime(n.year, n.month, n.day).difference(DateTime(t.year, t.month, t.day)).inDays;
  if (days == 0) return hm;
  if (days == 1) return 'Yesterday $hm';
  if (days < 7) return '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday - 1]} $hm';
  return '${t.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][t.month - 1]} $hm';
}

/// An error as a sentence that says what to do about it.
String friendlyError(Object error) {
  if (error is HubException) {
    if (error.status == 0) {
      return error.message.contains('in time')
          ? 'The hub did not answer in time. Try again in a moment.'
          : 'Cannot reach the hub. Check the connection, then try again.';
    }
    final m = error.message.replaceFirst(RegExp(r'^roster: '), '').trim();
    if (m.isEmpty) return 'The hub refused (${error.status}).';
    final sentence = '${m[0].toUpperCase()}${m.substring(1)}';
    return sentence.endsWith('.') ? sentence : '$sentence.';
  }
  return '$error';
}

/// Shows an error (or a short notice) as a toast, with an optional action.
void showError(BuildContext context, Object error, {String? action, VoidCallback? onAction}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(error is String ? error : friendlyError(error)),
      action: action == null ? null : SnackBarAction(label: action, onPressed: onAction ?? () {}),
    ));
}
