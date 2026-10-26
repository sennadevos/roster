import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// The speech engines voice chat runs on, or null where there is none (the
/// web app). Tests put fakes here.
(SpeechInput, SpeechOutput) Function()? voiceEngines =
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? () => (PhoneSpeechInput(), PhoneSpeechOutput()) : null;

/// Speech to text. One utterance per [listen]: it reports what it hears as
/// it goes and ends with the whole of it ('' when nothing was heard).
///
/// The phone's recognizer is the one there is now; a server engine (audio
/// to the hub, transcribed there) can stand in for devices without one.
abstract class SpeechInput {
  /// Ready to listen: the microphone permission is granted and a recognizer
  /// is there. Asks for the permission the first time.
  Future<bool> available();

  Future<String> listen({required void Function(String words) onPartial});

  Future<void> stop();
}

/// Text to speech. [speak] completes when the text has been spoken, or
/// stopped.
abstract class SpeechOutput {
  Future<void> speak(String text);

  Future<void> stop();
}

/// Android's own speech recognizer (Google's, or any other installed one).
class PhoneSpeechInput implements SpeechInput {
  final _stt = SpeechToText();
  bool _ready = false;
  Completer<String>? _current;
  String _last = '';

  @override
  Future<bool> available() async {
    if (_ready) return true;
    _ready = await _stt.initialize(onStatus: _onStatus, onError: (_) => _finish());
    return _ready;
  }

  void _onStatus(String status) {
    if (status == SpeechToText.doneStatus || status == SpeechToText.notListeningStatus) _finish();
  }

  void _finish() {
    final c = _current;
    _current = null;
    if (c != null && !c.isCompleted) c.complete(_last.trim());
  }

  @override
  Future<String> listen({required void Function(String words) onPartial}) async {
    _finish();
    final c = _current = Completer<String>();
    _last = '';
    await _stt.listen(
      onResult: (SpeechRecognitionResult r) {
        _last = r.recognizedWords;
        onPartial(_last);
        if (r.finalResult) _finish();
      },
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
        autoPunctuation: true,
        // A pause this long ends what was said, and so sends it.
        pauseFor: const Duration(seconds: 3),
        listenFor: const Duration(minutes: 2),
      ),
    );
    return c.future;
  }

  @override
  Future<void> stop() async {
    await _stt.stop();
    _finish();
  }
}

/// Android's own text to speech, in the phone's language and voice.
class PhoneSpeechOutput implements SpeechOutput {
  final _tts = FlutterTts();
  bool _set = false;

  @override
  Future<void> speak(String text) async {
    if (!_set) {
      await _tts.awaitSpeakCompletion(true);
      _set = true;
    }
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
  }
}
