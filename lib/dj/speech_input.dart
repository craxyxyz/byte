import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Whether the mic can be used for talking to the DJ.
enum MicStatus { ready, denied, unavailable }

/// Speech to text for the DJ (the phone's own recogniser, on the device when
/// the phone supports it). Byte © 2026 Apurba Laskar.
abstract class SpeechInput {
  Future<MicStatus> init();

  /// Listens in [locale] ("hi-IN", "bn-IN", "en-IN"). [onText] gets the words
  /// so far; [isFinal] is true once they stop talking. [onError] gets a short
  /// reason when listening fails.
  Future<void> listen({required String locale, required void Function(String text, bool isFinal) onText, void Function(String reason)? onError});
  Future<void> stop();
  bool get listening;
}

/// The mic languages offered.
const micLocales = {'hi-IN': 'हिंदी / Hinglish', 'bn-IN': 'বাংলা', 'en-IN': 'English'};

class PlatformSpeechInput implements SpeechInput {
  final SpeechToText _stt = SpeechToText();
  bool _ok = false;
  bool _onDevice = true;
  bool _listening = false;
  void Function(String)? _onError;
  Set<String> _locales = {};

  @override
  bool get listening => _listening;

  @override
  Future<MicStatus> init() async {
    if (kIsWeb) return MicStatus.unavailable;
    try {
      _ok = await _stt.initialize(
        onError: (SpeechRecognitionError e) {
          _listening = false;
          final cb = _onError;
          if (cb != null) cb(e.errorMsg);
        },
        onStatus: (s) {
          if (s == SpeechToText.doneStatus || s == SpeechToText.notListeningStatus) _listening = false;
        },
      );
      if (!_ok) {
        final perm = await _stt.hasPermission;
        return perm ? MicStatus.unavailable : MicStatus.denied;
      }
      try {
        _locales = (await _stt.locales()).map((l) => l.localeId.replaceAll('_', '-').toLowerCase()).toSet();
      } catch (_) {}
      return MicStatus.ready;
    } catch (_) {
      return MicStatus.unavailable;
    }
  }

  String _pick(String want) {
    if (_locales.isEmpty || _locales.contains(want.toLowerCase())) return want;
    final lang = want.split('-').first.toLowerCase();
    final same = _locales.where((l) => l.startsWith('$lang-')).toList();
    if (same.isNotEmpty) return same.first;
    return _locales.contains('en-in') ? 'en-IN' : want;
  }

  @override
  Future<void> listen({required String locale, required void Function(String text, bool isFinal) onText, void Function(String reason)? onError}) async {
    if (!_ok) return;
    _onError = (msg) {
      // the on-device model for this language isn't on the phone: try the
      // phone's standard recogniser once
      if (_onDevice && (msg.contains('language') || msg.contains('not_supported') || msg.contains('unavailable'))) {
        _onDevice = false;
        unawaited(listen(locale: locale, onText: onText, onError: onError));
        return;
      }
      onError?.call(msg);
    };
    _listening = true;
    await _stt.listen(
      onResult: (SpeechRecognitionResult r) {
        onText(r.recognizedWords, r.finalResult);
        if (r.finalResult) _listening = false;
      },
      listenOptions: SpeechListenOptions(
        localeId: _pick(locale),
        partialResults: true,
        onDevice: _onDevice,
        cancelOnError: true,
        listenMode: ListenMode.search,
        listenFor: const Duration(seconds: 20),
        pauseFor: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Future<void> stop() async {
    _listening = false;
    try {
      await _stt.stop();
    } catch (_) {}
  }
}
