import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:roster/models/agent.dart';
import 'package:roster/models/misc.dart';
import 'package:roster/state/conversation.dart';
import 'package:roster/voice/engines.dart';
import 'package:roster/voice/speakable.dart';
import 'package:roster/voice/voice_session.dart';

import 'fake_hub.dart';

/// Says what it is given, one utterance per listen; '' once the script is out.
class ScriptedInput implements SpeechInput {
  ScriptedInput(this.script);
  final List<String> script;
  int listens = 0;

  @override
  Future<bool> available() async => true;

  @override
  Future<String> listen({required void Function(String words) onPartial}) async {
    listens++;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final said = script.isEmpty ? '' : script.removeAt(0);
    if (said.isNotEmpty) onPartial(said);
    return said;
  }

  @override
  Future<void> stop() async {}
}

class RecordingOutput implements SpeechOutput {
  final said = <String>[];

  @override
  Future<void> speak(String text) async {
    said.add(text);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  @override
  Future<void> stop() async {}
}

Agent agent(String status) => Agent.fromJson({'name': 'a', 'machine': 'm', 'agent': 'a@m', 'status': status});

ScreenDialog dialog() => ScreenDialog.fromJson({
      'title': 'Allow Bash: rm -rf build?',
      'options': [
        {'key': '1', 'label': 'Yes'},
        {'key': '2', 'label': "Yes, and don't ask again for this"},
        {'key': '3', 'label': 'No, and tell Claude what to do differently', 'input': true},
      ],
    });

Future<void> until(bool Function() ok, {Duration within = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(within);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('markdown is said as words: no code, links, markup', () {
    expect(speakable('## Done\n\nI fixed **the parser** in `lib/parse.dart`.\n\n```dart\nvoid main() {}\n```\nSee [the PR](https://x.y/1).'),
        'Done\nI fixed the parser in lib parse dart.\n(code on screen)\nSee the PR.');
    expect(speakable('Go to https://example.com/a?b now'), 'Go to a link now');
    final long = speakable(List.filled(200, 'This is a sentence.').join(' '), max: 300);
    expect(long.length, lessThan(340));
    expect(long, endsWith('The rest is on screen.'));
  });

  test('a spoken answer picks a dialog option', () {
    final d = dialog();
    expect(spokenOption(d, 'two')?.key, '2');
    expect(spokenOption(d, 'option 1')?.key, '1');
    expect(spokenOption(d, 'Yes.')?.key, '1');
    expect(spokenOption(d, 'yes and don\'t ask again for this')?.key, '2');
    expect(spokenOption(d, 'no')?.key, '3');
    expect(spokenOption(d, 'please use the trash instead of deleting it'), isNull);
    expect(speakDialog(d), contains('1: Yes'));
    expect(speakDialog(d), contains('Or say your own answer.'));
  });

  test('the loop: hear, send, read the reply aloud, listen again, stop after two silences', () async {
    var transcript = <Map<String, dynamic>>[
      {'i': 1, 'role': 'assistant', 'text': 'Earlier words, never read out.'},
    ];
    final prompts = <String>[];
    final hub = FakeHub({
      'GET /v1/transcript': (_, q) {
        final after = q['after'] == null ? null : int.parse(q['after']!);
        final rows = after == null ? transcript : transcript.where((m) => (m['i'] as int) > after).toList();
        return {'agent': 'a@m', 'session_id': 's', 'messages': rows, 'next': transcript.last['i'] as int};
      },
      'POST /v1/prompt': (b, _) {
        prompts.add(b['text'] as String);
        transcript = [...transcript, {'i': (transcript.last['i'] as int) + 1, 'role': 'user', 'text': b['text']}];
        return {'ok': true};
      },
    });
    final conv = Conversation(hub.client(Uri.parse('https://hub'), 'tok-1'), 'a@m');
    await conv.loadTail();
    var row = agent('idle');
    final changes = ChangeNotifier();
    final input = ScriptedInput(['What changed today?']);
    final output = RecordingOutput();
    final v = VoiceSession(conversation: conv, row: () => row, changes: changes, input: input, output: output);

    await v.start();
    await until(() => prompts.isNotEmpty);
    expect(prompts, ['What changed today?']);
    await until(() => v.state == VoiceState.waiting);

    // The agent works and writes; then the turn ends.
    row = agent('working');
    changes.notifyListeners();
    transcript = [...transcript, {'i': 9, 'role': 'assistant', 'text': 'Two **fixes** landed.'}];
    await conv.fetchNew();
    await until(() => output.said.isNotEmpty);
    expect(output.said, ['Two fixes landed.']);
    // Its last words come in only with the end of the turn.
    transcript = [...transcript, {'i': 12, 'role': 'assistant', 'text': 'All tests pass.'}];
    row = agent('idle');
    changes.notifyListeners();
    await until(() => output.said.length == 2);
    expect(output.said.last, 'All tests pass.');

    // Listening again, it hears nothing twice and stops.
    await until(() => v.state == VoiceState.off);
    expect(input.listens, 3);
    expect(v.note, contains('two silences'));
    v.dispose();
  });

  test('a question from the agent is read out and answered by voice', () async {
    final keys = <List<String>>[];
    final hub = FakeHub({
      'GET /v1/transcript': (_, _) => {'agent': 'a@m', 'session_id': 's', 'messages': [], 'next': 0},
      'GET /v1/screen': (_, _) => {'agent': 'a@m', 'status': 'blocked', 'text': '', 'dialog': {
            'title': 'Allow Bash: rm -rf build?',
            'options': [{'key': '1', 'label': 'Yes'}, {'key': '2', 'label': 'No'}],
          }},
      'POST /v1/keys': (b, _) {
        keys.add((b['keys'] as List).cast<String>());
        return {'ok': true};
      },
    });
    final conv = Conversation(hub.client(Uri.parse('https://hub'), 'tok-1'), 'a@m');
    await conv.loadTail();
    await conv.fetchScreen();
    final changes = ChangeNotifier();
    final output = RecordingOutput();
    final v = VoiceSession(
        conversation: conv, row: () => agent('blocked'), changes: changes, input: ScriptedInput(['yes']), output: output);

    await v.start();
    await until(() => keys.isNotEmpty);
    expect(output.said.single, 'Allow Bash: rm -rf build? 1: Yes. 2: No.');
    expect(keys.single, ['1']);
    await v.stop();
    v.dispose();
  });
}
