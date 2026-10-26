import '../models/misc.dart';

/// Claude's markdown as something to say: code, links and markup are not
/// read out letter by letter. Long answers are cut, with a pointer to the
/// screen.
String speakable(String markdown, {int max = 1200}) {
  var t = markdown;
  t = t.replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' (code on screen) ');
  t = t.replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m[1] ?? '');
  t = t.replaceAll(RegExp(r'https?://\S+'), 'a link');
  t = t.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => _plainCode(m[1] ?? ''));
  t = t.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*>\s?', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*\|?\s*:?-{3,}.*$', multiLine: true), '');
  t = t.replaceAll('|', ', ');
  t = t.replaceAll(RegExp(r'[*_~]{1,3}'), '');
  t = t.replaceAll(RegExp(r'[ \t]+'), ' ');
  t = t.replaceAll(RegExp(r' *\n[ \n]*'), '\n').trim();
  if (t.length > max) {
    final cut = t.lastIndexOf(RegExp(r'[.!?]\s'), max);
    t = '${t.substring(0, cut > max ~/ 2 ? cut + 1 : max)} The rest is on screen.';
  }
  return t;
}

/// A short code span said as words: paths and names lose their punctuation runs.
String _plainCode(String code) {
  if (code.length > 60) return 'code';
  return code.replaceAll(RegExp(r'[/_.\-]+'), ' ').trim();
}

/// What to say when the agent asks something: the question and its options.
String speakDialog(ScreenDialog d) {
  final opts = [
    for (final o in d.options)
      if (!o.input) '${o.key}: ${o.label}',
  ];
  final typed = d.options.any((o) => o.input);
  return '${speakable(d.title)} ${opts.join('. ')}.${typed ? ' Or say your own answer.' : ''}';
}

const _numbers = {
  'one': '1', 'two': '2', 'three': '3', 'four': '4', 'five': '5',
  'six': '6', 'seven': '7', 'eight': '8', 'nine': '9',
  'first': '1', 'second': '2', 'third': '3', 'fourth': '4',
  'een': '1', 'twee': '2', 'drie': '3', 'vier': '4', 'vijf': '5',
};

/// Which option a spoken answer picks, or null: its number ("two", "option
/// 2"), its label said out, or yes and no for a dialog that starts with Yes.
DialogOption? spokenOption(ScreenDialog d, String said) {
  final s = _words(said);
  if (s.isEmpty) return null;
  final words = s.split(RegExp(r'\s+'));
  final picks = d.options.where((o) => !o.input).toList();
  if (words.length <= 3) {
    for (final w in words.reversed) {
      final key = _numbers[w] ?? (RegExp(r'^\d{1,2}$').hasMatch(w) ? w : null);
      final hit = picks.where((o) => o.key == key);
      if (hit.isNotEmpty) return hit.first;
    }
  }
  for (final o in picks) {
    final label = _words(o.label);
    if (label.isNotEmpty && (s == label || (words.length <= 6 && s.contains(label)))) return o;
  }
  if (picks.isNotEmpty && picks.first.label.toLowerCase().startsWith('yes') && words.length <= 2) {
    if (const {'yes', 'yeah', 'yep', 'sure', 'ok', 'okay', 'ja'}.contains(words.first)) return picks.first;
    if (const {'no', 'nope', 'nee'}.contains(words.first)) {
      // Also the free-text "No, and tell Claude …": then "no" is what it is told.
      final no = d.options.where((o) => o.label.toLowerCase().startsWith('no'));
      if (no.isNotEmpty) return no.first;
    }
  }
  return null;
}

/// Lowercase words only, single spaces: "Yes, and don't" -> "yes and don t".
String _words(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
