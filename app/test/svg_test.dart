import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roster/widgets/message_tile.dart';
import 'package:roster/widgets/svg_block.dart';

void main() {
  test('an svg fence is a drawing; other code is not', () {
    const drawing = '<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="4"/></svg>';
    expect(SvgBlock.isSvg('svg', drawing), isTrue);
    // an agent that labels it xml, or does not label it at all, still means a drawing
    expect(SvgBlock.isSvg('xml', drawing), isTrue);
    expect(SvgBlock.isSvg(null, drawing), isTrue);
    expect(SvgBlock.isSvg('dart', 'void main() {}'), isFalse);
    expect(SvgBlock.isSvg(null, 'git status --short'), isFalse);
    // talking about svg is not drawing one
    expect(SvgBlock.isSvg('bash', 'inkscape --export-type=svg a.svg'), isFalse);
  });

  test('an svg written into the text without a fence gets one', () {
    const said = 'Here is the layout:\n<svg width="10" height="10"><rect width="10" height="10"/></svg>\nThe notch is on the left.';
    final out = fenceBareSvg(said);
    expect(out, contains('```svg\n<svg width="10"'));
    expect(out, contains('The notch is on the left.'));
    // one that is already fenced is left alone
    const already = 'look:\n```svg\n<svg><rect/></svg>\n```\n';
    expect(fenceBareSvg(already), already);
    // and text with no drawing in it is untouched
    expect(fenceBareSvg('no pictures here'), 'no pictures here');
  });

  test('the drawing keeps its own shape', () {
    expect(SvgBlock.aspect('<svg viewBox="0 0 240 120">'), closeTo(2, 1e-9));
    expect(SvgBlock.aspect('<svg width="300" height="100" xmlns="x">'), closeTo(3, 1e-9));
    // viewBox wins over the attributes, as it does when drawing
    expect(SvgBlock.aspect('<svg width="300" height="100" viewBox="0 0 100 100">'), closeTo(1, 1e-9));
    // nothing to go on: a shape that at least does not eat the page
    expect(SvgBlock.aspect('<svg xmlns="x">'), closeTo(16 / 9, 1e-9));
  });

  test('a link to an svg is a drawing too', () {
    const said = 'The SVG of the three new outlines is ready: '
        'http://10.137.42.3:8791/projects/hair-comb/drawings/outlines-r02.svg (file: drawings/outlines-r02.svg).';
    expect(svgLinksIn(said).single.toString(),
        'http://10.137.42.3:8791/projects/hair-comb/drawings/outlines-r02.svg');
    // the same link twice is one drawing, and a full stop is not part of it
    expect(svgLinksIn('see http://h/a.svg. and http://h/a.svg again').length, 1);
    expect(svgLinksIn('http://h/a.svg.').single.toString(), 'http://h/a.svg');
    expect(svgLinksIn('a page at https://example.com/svg/guide'), isEmpty);
  });

  testWidgets('a drawing renders, and its source is one tap away', (tester) async {
    const drawing = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
        '<circle cx="5" cy="5" r="4" fill="black"/></svg>';
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SvgBlock(drawing))));
    await tester.pumpAndSettle();
    expect(find.text('Source'), findsOneWidget);
    expect(find.textContaining('<circle'), findsNothing);
    await tester.tap(find.text('Source'));
    await tester.pumpAndSettle();
    expect(find.textContaining('<circle'), findsOneWidget);
    expect(find.text('Drawing'), findsOneWidget);
  });
}
