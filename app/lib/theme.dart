import 'package:flutter/material.dart';

/// The bundled monospace font (fonts/JetBrainsMono), for code and tool calls.
/// On the web, `monospace` would fall back to Roboto.
const monoFont = 'JetBrainsMono';

/// Monospace without ligatures: code shows `=>` as typed, not as an arrow.
const monoFeatures = [FontFeature.disable('calt'), FontFeature.disable('liga')];

TextStyle mono({double? fontSize, Color? color, FontWeight? fontWeight, double? height}) => TextStyle(
      fontFamily: monoFont,
      fontFeatures: monoFeatures,
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
      height: height,
    );

const _seed = Color(0xFF00796B);

/// Colours per agent status, chosen to read at a glance in both themes.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.working,
    required this.blocked,
    required this.done,
    required this.idle,
    required this.unknown,
    required this.ended,
  });

  final Color working;
  final Color blocked;
  final Color done;
  final Color idle;
  final Color unknown;
  final Color ended;

  static const light = StatusColors(
    working: Color(0xFFD08700),
    blocked: Color(0xFFD7263D),
    done: Color(0xFF1E8E3E),
    idle: Color(0xFF4F9A6A),
    unknown: Color(0xFF8E5BD0),
    ended: Color(0xFF8A9494),
  );

  static const dark = StatusColors(
    working: Color(0xFFF6B93B),
    blocked: Color(0xFFFF6B6B),
    done: Color(0xFF5CC97B),
    idle: Color(0xFF7DBE95),
    unknown: Color(0xFFB794F6),
    ended: Color(0xFF6F7B7B),
  );

  Color of(String status) => switch (status) {
        'working' => working,
        'blocked' => blocked,
        'done' => done,
        'idle' => idle,
        'gone' || 'left' => ended,
        _ => unknown,
      };

  @override
  StatusColors copyWith() => this;

  @override
  StatusColors lerp(StatusColors? other, double t) {
    if (other == null) return this;
    return StatusColors(
      working: Color.lerp(working, other.working, t)!,
      blocked: Color.lerp(blocked, other.blocked, t)!,
      done: Color.lerp(done, other.done, t)!,
      idle: Color.lerp(idle, other.idle, t)!,
      unknown: Color.lerp(unknown, other.unknown, t)!,
      ended: Color.lerp(ended, other.ended, t)!,
    );
  }
}

/// Status colours for [context].
StatusColors statusColors(BuildContext context) =>
    Theme.of(context).extension<StatusColors>() ?? StatusColors.light;

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  // Seeded from the roster teal, with calm, nearly neutral surfaces so the
  // status colours carry the meaning.
  final cs = ColorScheme.fromSeed(seedColor: _seed, brightness: b).copyWith(
    surface: dark ? const Color(0xFF111516) : const Color(0xFFFAFCFC),
    surfaceContainerLowest: dark ? const Color(0xFF0C0F10) : const Color(0xFFFFFFFF),
    surfaceContainerLow: dark ? const Color(0xFF161B1C) : const Color(0xFFF3F6F6),
    surfaceContainer: dark ? const Color(0xFF1B2122) : const Color(0xFFEDF1F1),
    surfaceContainerHigh: dark ? const Color(0xFF222829) : const Color(0xFFE7ECEC),
    surfaceContainerHighest: dark ? const Color(0xFF293031) : const Color(0xFFE0E6E6),
    outlineVariant: dark ? const Color(0xFF323A3B) : const Color(0xFFD8E0DF),
  );
  final base = ThemeData(colorScheme: cs, brightness: b, visualDensity: VisualDensity.standard);
  final text = base.textTheme;
  return base.copyWith(
    extensions: [dark ? StatusColors.dark : StatusColors.light],
    scaffoldBackgroundColor: cs.surface,
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      bodyMedium: text.bodyMedium?.copyWith(height: 1.45),
      labelSmall: text.labelSmall?.copyWith(letterSpacing: 0.2),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface, letterSpacing: -0.2),
    ),
    dividerTheme: DividerThemeData(color: cs.outlineVariant, space: 1, thickness: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 440,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.all(12),
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
    popupMenuTheme: PopupMenuThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: cs.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: cs.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: cs.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: BorderSide(color: cs.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}
