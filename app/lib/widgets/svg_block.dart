import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A drawing an agent made, shown where it wrote it.
///
/// An agent that is asked to draw something writes an ```svg fence, or just
/// the `<svg>` itself; either way the picture belongs on the page, not a wall
/// of markup. The source stays one tap away, because a drawing that is wrong
/// is read by looking at what it says.
class SvgBlock extends StatefulWidget {
  const SvgBlock(this.source, {super.key});

  final String source;

  /// Whether this fence is a drawing: an `svg` fence, or an `xml`/unlabelled
  /// one whose contents are an `<svg>` element.
  static bool isSvg(String? language, String code) {
    final lang = language?.toLowerCase();
    if (lang == 'svg') return true;
    if (lang != null && lang.isNotEmpty && lang != 'xml' && lang != 'html') return false;
    return looksLikeSvg(code);
  }

  /// How wide the drawing is against its height, from `viewBox` or from the
  /// `width`/`height` on the root element. Without this the picture is given
  /// whatever height is going: a box far taller than the drawing, or an
  /// unbounded one that eats the page.
  static double aspect(String source, {double fallback = 16 / 9}) {
    final head = source.substring(0, source.length.clamp(0, 600));
    final box = RegExp(r'viewBox\s*=\s*["\x27]\s*([-\d.eE]+)[\s,]+([-\d.eE]+)[\s,]+([\d.eE]+)[\s,]+([\d.eE]+)')
        .firstMatch(head);
    if (box != null) {
      final w = double.tryParse(box.group(3)!) ?? 0;
      final h = double.tryParse(box.group(4)!) ?? 0;
      if (w > 0 && h > 0) return w / h;
    }
    double? side(String name) {
      final m = RegExp('$name\\s*=\\s*["\\x27]\\s*([\\d.]+)').firstMatch(head);
      return m == null ? null : double.tryParse(m.group(1)!);
    }
    final w = side('width'), h = side('height');
    if (w != null && h != null && w > 0 && h > 0) return w / h;
    return fallback;
  }

  static bool looksLikeSvg(String code) {
    final t = code.trimLeft();
    final start = t.startsWith('<?xml') || t.startsWith('<!DOCTYPE') ? t.indexOf('<svg') : (t.startsWith('<svg') ? 0 : -1);
    return start >= 0 && code.contains('</svg>');
  }

  @override
  State<SvgBlock> createState() => _SvgBlockState();
}

class _SvgBlockState extends State<SvgBlock> {
  bool _showSource = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              // a drawing is usually made for a light page: give it one
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
            ),
            padding: const EdgeInsets.all(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: _showSource
                  ? SingleChildScrollView(
                      child: SelectableText(
                        widget.source,
                        style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'JetBrainsMono', color: Colors.black87),
                      ),
                    )
                  : _error != null
                  ? Text('this drawing did not render: $_error',
                      style: theme.textTheme.bodySmall?.copyWith(color: cs.error))
                  : AspectRatio(
                      // its own shape decides the height, so there is no empty
                      // room under a wide drawing
                      aspectRatio: SvgBlock.aspect(widget.source),
                      child: SvgPicture.string(
                      widget.source,
                      fit: BoxFit.contain,
                      width: double.infinity,
                      placeholderBuilder: (_) => const SizedBox(height: 80),
                      errorBuilder: (context, error, stack) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && _error == null) setState(() => _error = '$error');
                        });
                        return const SizedBox(height: 40);
                      },
                    )),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() => _showSource = !_showSource),
              icon: Icon(_showSource ? Icons.image_outlined : Icons.code, size: 16),
              label: Text(_showSource ? 'Drawing' : 'Source'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: cs.outline),
            ),
          ),
        ],
      ),
    );
  }
}

/// Links to a drawing an agent saved somewhere instead of writing it out: the
/// picture is fetched and shown under the message, so a link to an `.svg` is
/// still a drawing rather than homework.
List<Uri> svgLinksIn(String text) {
  final out = <Uri>[];
  for (final m in RegExp(r'https?://[^\s)<>"\x27\]]+', caseSensitive: false).allMatches(text)) {
    final url = Uri.tryParse(m.group(0)!.replaceAll(RegExp(r'[.,;:]+$'), ''));
    if (url == null || !url.path.toLowerCase().endsWith('.svg')) continue;
    if (!out.contains(url)) out.add(url);
  }
  return out;
}

/// A drawing that lives at a URL. It is fetched when it comes into view; if it
/// cannot be reached - the machine is off, the page is another origin - the
/// message keeps its link and nothing shouts about it.
class NetworkSvg extends StatelessWidget {
  const NetworkSvg(this.url, {super.key});

  final Uri url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
        ),
        padding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SvgPicture.network(
            url.toString(),
            fit: BoxFit.contain,
            placeholderBuilder: (_) => const SizedBox(height: 60),
            errorBuilder: (context, error, stack) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
