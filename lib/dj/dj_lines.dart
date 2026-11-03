import 'dart:math';

/// What the DJ is introducing.
enum DjMoment { favourites, throwback, discover, language, vibe, switchUp, request }

/// The DJ's spoken lines: short, natural, Hinglish or English, never the
/// same one twice in a row. Byte © 2026 Apurba Laskar.
class DjLines {
  final Random _rng;
  final List<String> _recent = [];
  DjLines({Random? rng}) : _rng = rng ?? Random();

  static String partOfDay(DateTime t) {
    final h = t.hour;
    if (h >= 5 && h < 12) return 'morning';
    if (h >= 12 && h < 17) return 'afternoon';
    if (h >= 17 && h < 21) return 'evening';
    return 'night';
  }

  static const _greet = <String, Map<String, List<String>>>{
    'hinglish': {
      'morning': [
        'Good morning {name}! Main hoon tumhara DJ. Chai ready hai? Chalo din ki shuruaat karte hain.',
        'Subah subah {name}, ekdum fresh start. Aaj ka mood main set karta hoon.',
        'Rise and shine, {name}! Aankhein kholo, music on.',
        'Good morning {name}. Aaram se uthho, gaane main laga deta hoon.',
      ],
      'afternoon': [
        'Hey {name}, dopahar ho gayi. Thodi energy chahiye? Main hoon na.',
        'Lunch ke baad wali susti? {name}, yeh gaane bhaga denge.',
        'Hello {name}! Afternoon session shuru karte hain.',
      ],
      'evening': [
        'Good evening {name}! Din kaisa gaya? Ab relax karo, music main sambhal leta hoon.',
        'Shaam ho gayi {name}. Chalo thoda unwind karte hain.',
        'Hey {name}, evening vibes on. Baith jao, sab set hai.',
      ],
      'night': [
        'Late night vibes, {name}. Lights dim karo, baaki main dekh leta hoon.',
        'Raat ho gayi, {name}. Chalo kuch soothing gaane sunte hain.',
        'Hey {name}, raat lambi hai aur gaane bahut. Shuru karein?',
      ],
    },
    'english': {
      'morning': [
        'Good morning {name}! I\'m your DJ. Let\'s ease into the day.',
        'Morning, {name}. Fresh start, fresh music. I\'ve got this.',
        'Rise and shine, {name}! Let\'s get you going.',
      ],
      'afternoon': [
        'Hey {name}, afternoon slump? Not on my watch.',
        'Hello {name}! Let\'s keep the afternoon moving.',
        'Hey {name}, here\'s a little something for the middle of your day.',
      ],
      'evening': [
        'Good evening {name}! Long day? Sit back, I\'ll handle the music.',
        'Evening, {name}. Time to unwind.',
        'Hey {name}, evening mode is on.',
      ],
      'night': [
        'Late night, {name}? Dim the lights, I\'ll take it from here.',
        'Still up, {name}? Let\'s keep it smooth.',
        'Hey {name}, the night is long and so is this mix.',
      ],
    },
  };

  static const _moments = <String, Map<DjMoment, List<String>>>{
    'hinglish': {
      DjMoment.favourites: [
        'Hey {name}, shuru karte hain tumhare favourites se.',
        'Shuru karte hain un gaano se jo tum baar baar sunte ho. Pehla, {artist}.',
        'Yeh rahe tumhare favourites, {name}. Volume thoda upar?',
        'Tumhari playlist ke heroes, ek ke baad ek.',
        'Woh gaane jo tumhare repeat pe rehte hain. Shuru karte hain.',
        'Ab sirf tumhare favourites. {artist} se start.',
      ],
      DjMoment.throwback: [
        'Ab thoda {period} ke throwbacks. Yaad hain yeh?',
        '{name}, chalo {period} mein wapas chalte hain. Yeh tum tab khoob sunte the.',
        '{name}, ab thoda throwback ho jaye? Yeh gaane yaad hain na.',
        'Chalo thoda peeche chalte hain. Purani yaadein, wahi feeling.',
        'Throwback time! Yeh wale tumne kaafi time se nahi sune.',
        'Kuch purane gaane, jo kabhi tumhare favourite the. Yaad aaya?',
      ],
      DjMoment.discover: [
        'Kuch naya jo tumhe pasand aa sakta hai.',
        'Ab kuch naya, {name}. Tumhari pasand dekh ke dhoonda hai, try karo.',
        'New for you: yeh tumne pehle nahi sune, par mujhe lagta hai pasand aayenge.',
        'Thoda explore karte hain. {artist} ka yeh, ekdum tumhare type ka.',
        'Kuch fresh gaane, sirf tumhare liye chune hain.',
      ],
      DjMoment.language: [
        'Ab thoda {lang}. Ghar wali feeling.',
        '{name}, ab ek desi mix. {lang}, dil se.',
        'Chalo ab apni bhasha ke gaane. {lang} mix shuru.',
      ],
      DjMoment.vibe: [
        'Ab thoda {vibe}. Bilkul abhi ke mood ke hisaab se.',
        '{name}, yeh {vibe} wala set tumhare liye.',
        'Next up, {vibe}. Enjoy karo.',
      ],
      DjMoment.switchUp: [
        'Theek hai, vibe badalte hain. Ab {vibe}.',
        'Samajh gaya, kuch alag chahiye. Yeh lo, {vibe}.',
        'Chalo mood change! {vibe} time.',
        'Okay {name}, ab {vibe}. Batana kaisa laga.',
      ],
      DjMoment.request: [
        'Yeh lo {name}, {vibe}. Skip karoge toh main samajh jaunga.',
        'Done! {vibe}, sirf tumhare liye.',
        'Theek hai, {vibe}. Chalo shuru karte hain.',
      ],
    },
    'english': {
      DjMoment.favourites: [
        'Hey {name}, let\'s start with your favourites.',
        'Let\'s start with the songs you keep coming back to. First up, {artist}.',
        'Here are your favourites, {name}. Turn it up.',
        'The heroes of your library, one after another.',
        'Your on-repeat songs, coming right up.',
      ],
      DjMoment.throwback: [
        'Now some throwbacks from {period}. Remember these?',
        '{name}, how about a little throwback? You\'ll remember these.',
        'Let\'s go back in time for a bit.',
        'Throwback time! You haven\'t played these in a while.',
      ],
      DjMoment.discover: [
        'Something new you might love.',
        'Something new, {name}. Picked from what you love, give it a try.',
        'New for you: songs you haven\'t heard yet, but I think you\'ll like them.',
        'Let\'s explore a little. This one from {artist} is right up your street.',
      ],
      DjMoment.language: [
        'Now a little {lang}. Feels like home.',
        '{name}, here\'s a {lang} mix, straight from the heart.',
      ],
      DjMoment.vibe: [
        'Now, some {vibe}. Just right for this moment.',
        '{name}, this {vibe} set is for you.',
        'Next up, {vibe}. Enjoy.',
      ],
      DjMoment.switchUp: [
        'Alright, switching it up. Here\'s {vibe}.',
        'Got it, something different. {vibe}, coming up.',
        'Mood change! Time for {vibe}.',
      ],
      DjMoment.request: [
        'Here you go {name}, {vibe}. Skip anything and I\'ll learn.',
        'Done! {vibe}, just for you.',
        'Alright, {vibe}. Let\'s go.',
      ],
    },
  };

  String _pick(List<String> options) {
    final fresh = options.where((o) => !_recent.contains(o)).toList();
    var pool = fresh;
    if (pool.isEmpty) {
      // all used lately: anything but the one said last from this set
      final last = _recent.lastWhere(options.contains, orElse: () => '');
      pool = options.length > 1 ? options.where((o) => o != last).toList() : options;
    }
    final s = pool[_rng.nextInt(pool.length)];
    _recent.add(s);
    if (_recent.length > 14) _recent.removeAt(0);
    return s;
  }

  static String _fill(String s, Map<String, String?> v) {
    var out = s;
    v.forEach((k, val) => out = out.replaceAll('{$k}', val ?? ''));
    return out.replaceAll(RegExp(r'\s+'), ' ').replaceAll(' .', '.').replaceAll(' ,', ',').trim();
  }

  /// One line for [moment]. [opening] adds the hello for the time of day.
  String line(
    DjMoment moment, {
    required String name,
    required bool hinglish,
    required DateTime now,
    String? artist,
    String? vibe,
    String? language,
    String? period,
    bool opening = false,
  }) {
    final lang = hinglish ? 'hinglish' : 'english';
    var options = _moments[lang]![moment]!;
    // lines that need an artist / a period only when we know one
    if (artist == null || artist.isEmpty) options = options.where((o) => !o.contains('{artist}')).toList();
    if (period == null || period.isEmpty) {
      options = options.where((o) => !o.contains('{period}')).toList();
    } else if (moment == DjMoment.throwback) {
      options = options.where((o) => o.contains('{period}')).toList();
    }
    // the very first line: hello, then "starting with your favourites"
    final body = opening && moment == DjMoment.favourites
        ? (hinglish ? 'Shuru karte hain tumhare favourites se.' : 'Let\'s start with your favourites.')
        : _pick(options);
    final h = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final vals = <String, String?>{'name': name, 'artist': artist, 'vibe': vibe, 'lang': language, 'hour': '$h', 'period': period};
    final b = _fill(body, vals);
    if (!opening) return b;
    final g = _fill(_pick(_greet[lang]![partOfDay(now)]!), vals);
    return '$g $b';
  }

  /// The line when the DJ goes quiet at the end (nothing left to play).
  String goodbye({required String name, required bool hinglish}) =>
      hinglish ? 'Aaj ke liye bas itna, $name. Phir milte hain!' : 'That\'s all for now, $name. Catch you later!';

  /// Every line the DJ can say (tests check them for names and length).
  static Iterable<String> get allTemplates sync* {
    for (final l in _greet.values) {
      for (final v in l.values) {
        yield* v;
      }
    }
    for (final l in _moments.values) {
      for (final v in l.values) {
        yield* v;
      }
    }
  }
}
