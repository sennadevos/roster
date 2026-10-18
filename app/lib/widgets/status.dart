import 'package:flutter/material.dart';

/// The glyph and colour `roster list` uses for a status.
(String, Color) statusLook(String status, ColorScheme cs) => switch (status) {
      'working' => ('●', const Color(0xFFE0A100)),
      'blocked' => ('▲', cs.error),
      'done' => ('✓', const Color(0xFF2E9E4F)),
      'idle' => ('○', const Color(0xFF2E9E4F)),
      'gone' => ('✗', cs.outline),
      'left' => ('–', cs.outline),
      _ => ('?', const Color(0xFF9C4DCC)),
    };

class StatusGlyph extends StatelessWidget {
  const StatusGlyph(this.status, {super.key, this.size = 20});

  final String status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (glyph, color) = statusLook(status, Theme.of(context).colorScheme);
    return Semantics(
      label: status,
      child: SizedBox(
        width: size + 8,
        child: Text(glyph,
            textAlign: TextAlign.center,
            style: TextStyle(color: color, fontSize: size, fontWeight: FontWeight.bold)),
      ),
    );
  }
}

/// Shows a hub error as a snackbar.
void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
}
