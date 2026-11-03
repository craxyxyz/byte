import 'recommender.dart';
import 'request_parser.dart';

/// What the DJ says in the chat. Byte © 2026 Apurba Laskar.
class DjChatLines {
  /// "Aaj kal tum Arijit aur Anirudh zyada sun rahe ho — kya mood hai?"
  static String greeting(TasteProfile t, {required bool hinglish, String name = ''}) {
    final a = t.latelyArtists(2).map(short).toList();
    final hi = name.trim().isEmpty ? '' : (hinglish ? 'Hey ${name.trim()}! ' : 'Hey ${name.trim()}! ');
    if (a.isEmpty) {
      return hinglish
          ? '${hi}Main tumhara DJ hoon. Kya sunna hai abhi? Mood, bhasha, singer, kuch bhi bolo ya likho.'
          : '${hi}I\'m your DJ. What do you want to hear right now? Tell me a mood, a language or a singer.';
    }
    final who = a.length == 1 ? a.first : '${a[0]} ${hinglish ? 'aur' : 'and'} ${a[1]}';
    return hinglish
        ? '${hi}Aaj kal tum $who zyada sun rahe ho. Kya mood hai? Kya sunna hai abhi?'
        : '${hi}Lately you\'ve been playing a lot of $who. What\'s the mood? What do you want to hear?';
  }

  /// A short name for chat ("Arijit Singh" → "Arijit").
  static String short(String name) {
    final n = name.trim();
    final parts = n.split(RegExp(r'\s+'));
    if (parts.length < 2) return n;
    final first = parts.first.replaceAll('.', '');
    return first.length >= 4 ? parts.first : n;
  }

  /// What the DJ understood, before playing.
  static String understood(DjRequest r, {required bool hinglish}) {
    if (r.isMix && !r.fresh) {
      return hinglish ? 'Theek hai, tumhare liye ek mix: favourites, kuch purane aur kuch naye.' : 'Okay, a mix for you: favourites, a few older ones and some new picks.';
    }
    if (r.freeText != null && r.chips.length == 1) {
      return hinglish ? 'Dhoondh raha hoon: "${r.freeText}"' : 'Looking for "${r.freeText}"';
    }
    return hinglish ? 'Samajh gaya: ${r.summary}. Gaane chun raha hoon…' : 'Got it: ${r.summary}. Picking songs…';
  }

  /// After the picks are ready.
  static String playing(DjRequest r, List<DjPick> picks, {required bool hinglish}) {
    final fresh = picks.where((p) => p.fresh).length;
    if (hinglish) {
      final f = fresh == picks.length ? ' Sab naye hain, tumne pehle nahi sune.' : (fresh > 0 ? ' $fresh naye bhi hain jo tumne nahi sune.' : '');
      return 'Yeh lo! ${picks.length} gaane, pehla "${picks.first.item.title}".$f Skip karoge toh main seekh ke list badal dunga.';
    }
    final f = fresh == picks.length ? ' All new to you.' : (fresh > 0 ? ' $fresh are new to you.' : '');
    return 'Here you go! ${picks.length} songs, starting with "${picks.first.item.title}".$f Skip anything and I\'ll adjust.';
  }

  static String nothing({required bool hinglish}) => hinglish
      ? 'Iske liye gaane nahi mile. Thoda alag likh ke dekho, ya internet check karo.'
      : 'I couldn\'t find songs for that. Try other words, or check the internet.';

  static String micDenied({required bool hinglish}) => hinglish
      ? 'Mic ki permission nahi mili. Koi baat nahi, neeche likh ke bolo.'
      : 'No microphone permission. No problem, just type it below.';

  static String micUnavailable({required bool hinglish}) => hinglish
      ? 'Is phone pe voice se bolna abhi kaam nahi kar raha. Neeche likh ke bolo.'
      : 'Voice input isn\'t available on this phone right now. Type it below.';

  /// Quick picks: (label, what gets sent).
  static List<(String, String)> quickPicks(TasteProfile t, {required bool hinglish}) {
    final top = t.latelyArtists(1);
    final artist = top.isEmpty ? 'Arijit' : short(top.first);
    return hinglish
        ? [
            ('Mere liye mix', 'mere liye mix'),
            ('Sad Hindi', 'sad hindi'),
            ('Party Bengali', 'party bengali'),
            ('$artist jaisa', '$artist jaisa'),
            ('90s', '90s ke gaane'),
            ('Workout', 'workout'),
            ('Romantic', 'romantic'),
            ('Chill', 'chill'),
            ('Kuch naya', 'kuch naya'),
            ('Jo maine kal suna', 'jo maine kal suna'),
          ]
        : [
            ('Mix for me', 'mix for me'),
            ('Sad Hindi', 'sad hindi'),
            ('Party Bengali', 'party bengali'),
            ('Like $artist', 'like $artist'),
            ('90s', '90s songs'),
            ('Workout', 'workout'),
            ('Romantic', 'romantic'),
            ('Chill', 'chill'),
            ('Something new', 'something new'),
            ('Yesterday\'s songs', 'yesterday'),
          ];
  }

  /// Ideas by kind (mood / language / artist / era / activity): (group, [(label, text)]).
  static List<(String, List<(String, String)>)> ideas(TasteProfile t, {required bool hinglish}) {
    final artists = t.latelyArtists(3).map(short).toList();
    if (artists.isEmpty) artists.addAll(const ['Arijit', 'Shreya']);
    return [
      (hinglish ? 'Mood' : 'Mood', [for (final m in const ['Sad', 'Happy', 'Romantic', 'Party', 'Chill', 'Devotional']) (m, m.toLowerCase())]),
      (hinglish ? 'Bhasha' : 'Language', [for (final l in const ['Hindi', 'Bengali', 'English', 'Punjabi', 'Tamil']) (l, '$l songs'.toLowerCase())]),
      (hinglish ? 'Singer' : 'Artist', [for (final a in artists) (hinglish ? '$a jaisa' : 'Like $a', hinglish ? '$a jaisa' : 'like $a')]),
      (hinglish ? 'Zamana' : 'Era', hinglish ? const [('90s', '90s ke gaane'), ('Purane', 'purane gaane'), ('Latest', 'latest gaane')] : const [('90s', '90s songs'), ('Old', 'old songs'), ('Latest', 'latest songs')]),
      (hinglish ? 'Kaam' : 'Activity', hinglish ? const [('Workout', 'workout'), ('Neend', 'neend ke liye'), ('Padhai', 'padhai ke liye'), ('Long drive', 'long drive')] : const [('Workout', 'workout'), ('Sleep', 'sleep'), ('Study', 'study'), ('Long drive', 'long drive')]),
    ];
  }

  /// Options to swap a chip for (tap on a chip).
  static List<DjChip> alternatives(DjChip c) => switch (c.kind) {
    DjChipKind.mood || DjChipKind.activity => [
      for (final m in DjVocab.moodLabel.keys) DjChip(DjVocab.activities.contains(m) ? DjChipKind.activity : DjChipKind.mood, m),
    ],
    DjChipKind.language => [for (final l in const ['hindi', 'bengali', 'english', 'punjabi', 'tamil', 'telugu', 'assamese', 'marathi']) DjChip(DjChipKind.language, l)],
    DjChipKind.era => [for (final e in DjVocab.eraLabel.keys) DjChip(DjChipKind.era, e)],
    DjChipKind.energy => const [DjChip(DjChipKind.energy, 'high'), DjChip(DjChipKind.energy, 'low')],
    DjChipKind.artistBy || DjChipKind.artistLike => [DjChip(DjChipKind.artistBy, c.value), DjChip(DjChipKind.artistLike, c.value)],
    _ => const [],
  };
}
