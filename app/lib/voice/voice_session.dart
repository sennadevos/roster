import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/agent.dart';
import '../state/conversation.dart';
import 'engines.dart';
import 'speakable.dart';

enum VoiceState { off, starting, listening, sending, waiting, speaking }

/// A hands-free conversation with one agent: listen, read Claude's text aloud
/// as it comes (not its tool calls), and listen again once the turn is over. A
/// question from the agent is read out with its options, and a spoken answer
/// picks one.
///
/// A pause sends nothing. Stopping to think mid-sentence is normal, and a
/// recognizer that submits the moment the talking stops makes that impossible:
/// what is heard is collected in [draft] across as many pauses as he likes. It
/// goes when he says so - the send button, or the word "over" at the end of a
/// sentence, the way it is said on a radio. Holding the mic button captures
/// while held, for when he wants to be certain nothing is missed.
class VoiceSession extends ChangeNotifier {
  VoiceSession({
    required this.conversation,
    required this.row,
    required this.changes,
    required this.input,
    required this.output,
  });

  final Conversation conversation;

  /// The agent's row now (status, dialog), from the app's snapshot.
  final Agent? Function() row;

  /// Fires whenever the snapshot changes, so the status is looked at again.
  final Listenable changes;

  final SpeechInput input;
  final SpeechOutput output;

  VoiceState state = VoiceState.off;

  /// What the recognizer hears in the round running now.
  String heard = '';

  /// Everything heard since the last send, pauses and all. Nothing leaves on
  /// its own; this is what goes when he sends.
  String draft = '';

  /// All there is to send: what was collected, plus the round in progress.
  String get pending => [draft, heard].where((s) => s.trim().isNotEmpty).join(' ').trim();

  /// Held down rather than left running: it listens while the button is held.
  bool holding = false;

  /// Why it stopped, or a passing problem, for the bar to show.
  String? note;

  Set<String> _before = {};
  final Set<String> _spoken = {};
  final List<String> _toSay = [];
  bool _sawWorking = false;
  bool _dialogSaid = false;
  bool _lastFetched = false;
  bool _attached = false;

  bool get active => state != VoiceState.off;

  void _set(VoiceState s) {
    state = s;
    notifyListeners();
  }

  Future<void> start() async {
    if (active) return;
    note = null;
    _set(VoiceState.starting);
    if (!await input.available()) {
      note = 'No speech recognizer, or no microphone permission.';
      _set(VoiceState.off);
      return;
    }
    if (!_attached) {
      conversation.addListener(_update);
      changes.addListener(_update);
      _attached = true;
    }
    draft = '';
    // Only what Claude writes from now on is read out.
    _spoken.addAll(conversation.messages.map((m) => m.key));
    final r = row();
    if (r?.status == 'blocked' && conversation.screen?.dialog != null) {
      _waitForTurn();
      _update();
      return;
    }
    unawaited(_listen());
  }

  Future<void> stop({String? why}) async {
    note = why;
    draft = '';
    heard = '';
    holding = false;
    _toSay.clear();
    _set(VoiceState.off);
    await input.stop();
    await output.stop();
  }

  /// Tapped while it speaks or waits: be quiet and listen now.
  Future<void> interject() async {
    if (state != VoiceState.speaking && state != VoiceState.waiting) return;
    _toSay.clear();
    _spoken.addAll(conversation.messages.map((m) => m.key));
    await output.stop();
    unawaited(_listen());
  }

  /// Listens, round after round. A round ends when the recognizer decides the
  /// talking stopped; its words are kept and the next round starts. Nothing is
  /// sent from here: a pause is a pause.
  Future<void> _listen() async {
    if (!active) return;
    heard = '';
    _set(VoiceState.listening);
    final said = await input.listen(onPartial: (w) {
      heard = w;
      notifyListeners();
    });
    if (state != VoiceState.listening) return; // sent, interjected or stopped meanwhile
    if (said.trim().isNotEmpty) {
      draft = [draft, said.trim()].where((s) => s.isNotEmpty).join(' ');
    }
    heard = '';
    notifyListeners();
    // "over" at the end is him handing the turn over, as on a radio
    final over = endsWithOver(draft);
    if (over != null) {
      draft = over;
      return send();
    }
    if (holding) return;    // held: the next round starts when he presses again
    return _listen();
  }

  /// Sends what has been collected, and nothing else does.
  Future<void> send() async {
    final text = pending;
    if (text.isEmpty) return;
    draft = '';
    heard = text;
    holding = false;
    await input.stop();
    await _heard(text);
  }

  /// Throws away what was heard, without sending, and keeps listening.
  void clear() {
    draft = '';
    heard = '';
    notifyListeners();
    if (state == VoiceState.listening && !holding) unawaited(input.stop());
  }

  /// Push to talk: it listens while the button is held, so nothing is cut off
  /// by a pause, and keeps what it heard when the button comes up.
  Future<void> hold() async {
    holding = true;
    if (state == VoiceState.listening) return;
    if (!active) return start();
    if (state == VoiceState.speaking || state == VoiceState.waiting) return interject();
  }

  Future<void> release() async {
    holding = false;
    if (state == VoiceState.listening) await input.stop();
  }

  Future<void> _heard(String said) async {
    final r = row();
    final dialog = conversation.screen?.dialog;
    if (r?.status == 'blocked' && dialog != null) {
      final opt = spokenOption(dialog, said);
      final typed = dialog.options.where((o) => o.input);
      _set(VoiceState.sending);
      try {
        if (opt != null && opt.input) {
          await conversation.answerText(opt, said);
        } else if (opt != null) {
          await conversation.answer(opt);
        } else if (typed.isNotEmpty) {
          await conversation.answerText(typed.first, said);
        } else {
          await _say('I did not catch which option. ${speakDialog(dialog)}');
          unawaited(_listen());
          return;
        }
      } catch (e) {
        note = '$e';
      }
      _waitForTurn();
      return;
    }
    _set(VoiceState.sending);
    _before = conversation.messages.map((m) => m.key).toSet();
    try {
      await conversation.send(said);
    } catch (e) {
      note = 'Not sent: $e';
      await _say('That did not go through.');
      return _listen();
    }
    _waitForTurn();
  }

  void _waitForTurn() {
    _sawWorking = false;
    _dialogSaid = false;
    _lastFetched = false;
    _set(VoiceState.waiting);
    _update();
  }

  /// New text from Claude is queued to be said; a question is read out; a
  /// turn that is over (and said) means listening again.
  void _update() {
    if (state != VoiceState.waiting && state != VoiceState.speaking) return;
    final r = row();
    final status = r?.status ?? 'unknown';
    if (status == 'working') _sawWorking = true;
    var fresh = false;
    for (final m in conversation.messages) {
      if (m.role != 'assistant' || _spoken.contains(m.key)) continue;
      _spoken.add(m.key);
      if (_before.contains(m.key)) continue;
      fresh = true;
      final text = speakable(m.text);
      if (text.isNotEmpty) _toSay.add(text);
    }
    if (fresh) _sawWorking = true;
    final dialog = conversation.screen?.dialog;
    if (status == 'blocked' && dialog != null && !_dialogSaid) {
      _dialogSaid = true;
      _toSay.add(speakDialog(dialog));
    }
    if (state == VoiceState.waiting) unawaited(_drain());
  }

  Future<void> _drain() async {
    while (_toSay.isNotEmpty && active) {
      final text = _toSay.removeAt(0);
      await _say(text);
      if (state != VoiceState.speaking) return; // interjected or stopped
      _set(VoiceState.waiting);
    }
    if (state != VoiceState.waiting) return;
    final status = row()?.status ?? 'unknown';
    final over = (status == 'idle' || status == 'done') && _sawWorking;
    final asked = status == 'blocked' && _dialogSaid;
    if (!over && !asked) return;
    if (over && !_lastFetched) {
      // The status can be there before the turn's last words are fetched:
      // fetch once more, and say what came before listening.
      _lastFetched = true;
      await conversation.fetchNew();
      if (state == VoiceState.waiting) _update(); // queues them and drains again
      return;
    }
    unawaited(_listen());
  }

  Future<void> _say(String text) async {
    _set(VoiceState.speaking);
    await output.speak(text);
  }

  @override
  void dispose() {
    if (_attached) {
      conversation.removeListener(_update);
      changes.removeListener(_update);
    }
    unawaited(input.stop());
    unawaited(output.stop());
    super.dispose();
  }
}
