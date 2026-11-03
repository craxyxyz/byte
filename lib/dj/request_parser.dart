/// The DJ's ear: turns "sad Hindi", "Arijit jaisa", "party Bengali",
/// "kuch naya", "jo maine kal suna" (Hinglish, Bengali in Latin or Bangla
/// script, English) into a request the recommender can act on. Pure Dart,
/// runs on the phone. Byte © 2026 Apurba Laskar.
library;

/// What kind of thing a chip stands for.
enum DjChipKind { mood, activity, language, artistBy, artistLike, era, energy, genre, history, fresh, familiar, mix, text }

/// One understood piece of a request, shown as an editable chip.
class DjChip {
  final DjChipKind kind;
  final String value;
  const DjChip(this.kind, this.value);

  String get label => switch (kind) {
    DjChipKind.mood || DjChipKind.activity => DjVocab.moodLabel[value] ?? _cap(value),
    DjChipKind.language => _cap(value),
    DjChipKind.artistBy => 'By $value',
    DjChipKind.artistLike => 'Like $value',
    DjChipKind.era => DjVocab.eraLabel[value] ?? value,
    DjChipKind.energy => value == 'high' ? 'High energy' : 'Slow & soft',
    DjChipKind.genre => DjVocab.genreLabel[value] ?? _cap(value),
    DjChipKind.history => value == 'yesterday' ? "Yesterday's songs" : 'Recently played',
    DjChipKind.fresh => 'Something new',
    DjChipKind.familiar => 'Your favourites',
    DjChipKind.mix => 'Mix for you',
    DjChipKind.text => '"$value"',
  };

  @override
  bool operator ==(Object other) => other is DjChip && other.kind == kind && other.value == value;
  @override
  int get hashCode => Object.hash(kind, value);
  @override
  String toString() => '${kind.name}:$value';
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// What the listener asked for.
class DjRequest {
  final String text;
  final List<DjChip> chips;
  const DjRequest(this.text, this.chips);

  static const empty = DjRequest('', []);

  Iterable<String> _of(DjChipKind k) => chips.where((c) => c.kind == k).map((c) => c.value);
  List<String> get moods => [..._of(DjChipKind.mood), ..._of(DjChipKind.activity)];
  List<String> get languages => _of(DjChipKind.language).toList();
  List<String> get byArtists => _of(DjChipKind.artistBy).toList();
  List<String> get likeArtists => _of(DjChipKind.artistLike).toList();
  List<String> get genres => _of(DjChipKind.genre).toList();
  String? get era => _of(DjChipKind.era).firstOrNull;
  String? get energy => _of(DjChipKind.energy).firstOrNull;
  String? get history => _of(DjChipKind.history).firstOrNull;
  String? get freeText => _of(DjChipKind.text).firstOrNull;
  bool get fresh => chips.any((c) => c.kind == DjChipKind.fresh);
  bool get familiar => chips.any((c) => c.kind == DjChipKind.familiar);

  /// Nothing specific asked for: a daily-mix style set from history.
  bool get isMix => chips.isEmpty || chips.every((c) => c.kind == DjChipKind.mix || c.kind == DjChipKind.fresh || c.kind == DjChipKind.familiar);

  DjRequest without(DjChip c) => DjRequest(text, [...chips]..remove(c));
  DjRequest withChip(DjChip c) {
    final l = [...chips];
    // one era / energy / history at a time
    if (const {DjChipKind.era, DjChipKind.energy, DjChipKind.history}.contains(c.kind)) l.removeWhere((x) => x.kind == c.kind);
    if (!l.contains(c)) l.add(c);
    l.removeWhere((x) => x.kind == DjChipKind.mix && c.kind != DjChipKind.mix);
    return DjRequest(text, l);
  }

  DjRequest replace(DjChip old, DjChip now) {
    final l = [...chips];
    final i = l.indexOf(old);
    if (i < 0) return withChip(now);
    l[i] = now;
    return DjRequest(text, l.toSet().toList());
  }

  /// Short summary of the request ("sad Hindi, like Arijit Singh").
  String get summary {
    if (chips.isEmpty || isMix && !fresh) return 'mix for you';
    final parts = <String>[];
    final m = [...moods.map((x) => (DjVocab.moodLabel[x] ?? x).toLowerCase()), ...genres.map((g) => DjVocab.genreLabel[g] ?? g)];
    final langs = languages.map(_cap);
    final e = era == null ? null : (DjVocab.eraLabel[era] ?? era!);
    final head = [?e, ...m, ...langs].join(' ');
    if (head.isNotEmpty) parts.add(head);
    if (energy != null) parts.add(energy == 'high' ? 'high energy' : 'slow & soft');
    for (final a in byArtists) {
      parts.add('by $a');
    }
    for (final a in likeArtists) {
      parts.add('like $a');
    }
    if (history == 'yesterday') parts.add("yesterday's songs");
    if (history == 'recent') parts.add('recently played');
    if (fresh) parts.add('something new');
    if (familiar) parts.add('your favourites');
    if (freeText != null) parts.add('"$freeText"');
    return parts.join(', ');
  }

  /// Search phrases for YouTube Music ("90s sad hindi songs").
  List<String> get queries {
    final out = <String>[];
    final e = switch (era) {
      null || 'new' => era == 'new' ? 'latest' : '',
      'old' => 'old',
      final x => x,
    };
    final moodWords = [for (final m in moods) DjVocab.moodQuery[m] ?? m, for (final g in genres) DjVocab.genreQuery[g] ?? g];
    final en = energy == 'high' ? 'upbeat' : (energy == 'low' ? 'soft' : '');
    String q(String lang, String mood) => [e, lang, mood, en, if (!mood.contains('bhajan') && !mood.contains('sangeet')) 'songs'].where((s) => s.isNotEmpty).join(' ').replaceAll(RegExp(r'\s+'), ' ');
    final langs = languages.isEmpty ? [''] : languages;
    for (final a in byArtists) {
      out.add([a, ...moodWords.take(1), 'songs'].join(' '));
    }
    if (byArtists.isEmpty) {
      final hasTopic = moodWords.isNotEmpty || languages.isNotEmpty || era != null || energy != null;
      if (hasTopic) {
        for (final l in langs) {
          if (moodWords.isEmpty) {
            out.add(q(l, ''));
          } else {
            for (final m in moodWords) {
              out.add(q(l, m));
            }
          }
        }
      }
    }
    if (freeText != null) out.add(freeText!);
    return out.toSet().toList();
  }

  @override
  String toString() => 'DjRequest($chips)';
}

/// A well-known artist and how people type their name.
class KnownArtist {
  final String name;
  final String? language;
  final List<String> aliases; // lower case
  const KnownArtist(this.name, this.language, this.aliases);
}

class DjVocab {
  static const moodLabel = {
    'sad': 'Sad',
    'happy': 'Happy',
    'romantic': 'Romantic',
    'party': 'Party',
    'chill': 'Chill',
    'devotional': 'Devotional',
    'workout': 'Workout',
    'sleep': 'Sleep',
    'focus': 'Focus',
    'drive': 'Drive',
  };
  static const moodQuery = {
    'sad': 'sad',
    'happy': 'happy',
    'romantic': 'romantic',
    'party': 'party',
    'chill': 'chill',
    'devotional': 'devotional',
    'workout': 'workout',
    'sleep': 'sleep',
    'focus': 'focus',
    'drive': 'road trip',
  };
  static const activities = {'workout', 'sleep', 'focus', 'drive'};
  static const eraLabel = {
    '60s': '60s',
    '70s': '70s',
    '80s': '80s',
    '90s': '90s',
    '2000s': '2000s',
    '2010s': '2010s',
    'old': 'Old songs',
    'new': 'New releases',
  };
  static const genreLabel = {
    'rabindra': 'Rabindra Sangeet',
    'ghazal': 'Ghazal',
    'sufi': 'Sufi',
    'qawwali': 'Qawwali',
    'lofi': 'Lo-fi',
    'rap': 'Rap',
    'rock': 'Rock',
    'indie': 'Indie',
    'folk': 'Folk',
    'classical': 'Classical',
    'unplugged': 'Unplugged',
    'instrumental': 'Instrumental',
    'edm': 'EDM',
  };
  static const genreQuery = {
    'rabindra': 'rabindra sangeet',
    'lofi': 'lofi',
    'rap': 'rap',
    'edm': 'edm',
  };

  /// word or phrase → mood. Phrases are matched as whole words.
  static const moods = <String, List<String>>{
    'sad': ['sad', 'dukhi', 'udaas', 'udas', 'dard', 'dardbhare', 'dard bhare', 'dard bhari', 'heartbreak', 'heart break', 'broken heart', 'breakup', 'break up', 'emotional', 'rona', 'mon kharap', 'mon kharaap', 'kosto', 'koshto', 'kashto', 'dukkho', 'dukho', 'judaai', 'judai', 'bewafa', 'tanha', 'tanhai', 'alone', 'lonely', 'cry', 'crying', 'মন খারাপ', 'দুঃখ', 'দুঃখের', 'কষ্ট', 'কষ্টের', 'উদাস', 'उदास', 'दर्द', 'दुखी', 'सैड'],
    'happy': ['happy', 'khush', 'khushi', 'cheerful', 'feel good', 'feelgood', 'feel-good', 'mast', 'masti', 'anondo', 'anando', 'anondor', 'khushir', 'আনন্দ', 'আনন্দের', 'খুশি', 'খুশির', 'খুশ', 'खुश', 'खुशी', 'मस्त'],
    'romantic': ['romantic', 'romance', 'pyaar', 'pyar', 'pyaar wale', 'love', 'love songs', 'ishq', 'mohabbat', 'prem', 'premer', 'bhalobasha', 'bhalobasa', 'valobasha', 'valobasa', 'bhalobashar', 'date night', 'ভালোবাসা', 'ভালোবাসার', 'প্রেম', 'প্রেমের', 'রোমান্টিক', 'रोमांटिक', 'प्यार', 'इश्क', 'मोहब्बत'],
    'party': ['party', 'dance', 'dancing', 'naach', 'nach', 'nacho', 'nachne', 'club', 'clubbing', 'disco', 'shaadi', 'wedding', 'sangeet night', 'baraat', 'পার্টি', 'নাচ', 'নাচের', 'पार्टी', 'नाच', 'डांस'],
    'chill': ['chill', 'chilled', 'relax', 'relaxing', 'sukoon', 'sukun', 'calm', 'shant', 'shanti', 'peaceful', 'aaram', 'aram', 'chill out', 'আরাম', 'শান্ত', 'शांत', 'सुकून', 'आराम'],
    'devotional': ['devotional', 'bhakti', 'bhajan', 'bhajans', 'aarti', 'arti', 'kirtan', 'kirtans', 'bhakti geet', 'bhoktigeeti', 'prayer', 'mantra', 'mantras', 'shyama sangeet', 'god songs', 'ভক্তি', 'ভক্তিগীতি', 'কীর্তন', 'ভজন', 'भजन', 'भक्ति', 'आरती'],
    'workout': ['workout', 'work out', 'gym', 'exercise', 'running', 'run', 'jogging', 'kasrat', 'pump up', 'cardio', 'ব্যায়াম', 'জিম', 'जिम', 'कसरत', 'वर्कआउट'],
    'sleep': ['sleep', 'sleeping', 'neend', 'nind', 'sone', 'sone ke liye', 'lori', 'lullaby', 'ghum', 'ghumer', 'bedtime', 'bed time', 'ঘুম', 'ঘুমের', 'নিদ্রা', 'नींद', 'लोरी'],
    'focus': ['study', 'studying', 'padhai', 'padhne', 'porashona', 'porashuna', 'focus', 'concentration', 'concentrate', 'coding', 'পড়াশোনা', 'পড়া', 'पढ़ाई'],
    'drive': ['drive', 'driving', 'long drive', 'road trip', 'roadtrip', 'safar', 'travel', 'journey', 'traveling', 'travelling', 'ড্রাইভ', 'সফর'],
  };

  static const languages = <String, List<String>>{
    'hindi': ['hindi', 'bollywood', 'hindustani', 'हिंदी', 'हिन्दी', 'হিন্দি'],
    'bengali': ['bengali', 'bangla', 'bangali', 'bengoli', 'bongo', 'বাংলা', 'বাঙালি', 'बंगाली', 'বাংলার'],
    'tamil': ['tamil', 'kollywood', 'தமிழ்', 'তামিল'],
    'telugu': ['telugu', 'tollywood telugu', 'తెలుగు'],
    'punjabi': ['punjabi', 'panjabi', 'bhangra', 'ਪੰਜਾਬੀ', 'पंजाबी', 'পাঞ্জাবি'],
    'english': ['english', 'angrezi', 'angreji', 'western', 'hollywood', 'ইংরেজি', 'ইংলিশ', 'अंग्रेजी', 'इंग्लिश'],
    'marathi': ['marathi', 'मराठी'],
    'malayalam': ['malayalam', 'mollywood', 'മലയാളം'],
    'kannada': ['kannada', 'sandalwood', 'ಕನ್ನಡ'],
    'gujarati': ['gujarati', 'garba', 'ગુજરાતી'],
    'bhojpuri': ['bhojpuri', 'भोजपुरी'],
    'assamese': ['assamese', 'axomiya', 'bihu', 'অসমীয়া'],
    'nepali': ['nepali', 'नेपाली'],
    'urdu': ['urdu'],
    'korean': ['korean', 'kpop', 'k-pop'],
  };

  static const eras = <String, List<String>>{
    '60s': ['60s', "60's", 'sixties', '1960s'],
    '70s': ['70s', "70's", 'seventies', '1970s', 'sattar'],
    '80s': ['80s', "80's", 'eighties', '1980s', 'assi', 'assi ke'],
    '90s': ['90s', "90's", 'nineties', '1990s', 'nabbe', 'nabbe ke', '৯০', '৯০-এর', 'নব্বই', 'নব্বইয়ের', '९०'],
    '2000s': ['2000s', "2000's", 'two thousands', '2000 ke'],
    '2010s': ['2010s', "2010's"],
    'old': ['old', 'oldies', 'old songs', 'purane', 'purana', 'puraane', 'puraana', 'puraani', 'purani', 'retro', 'classic', 'classics', 'evergreen', 'golden', 'golden era', 'purono', 'purano', 'puraton', 'puratan', 'throwback', 'throwbacks', 'vintage', 'পুরনো', 'পুরোনো', 'পুরানো', 'पुराने', 'पुराना', 'रेट्रो'],
    'new': ['new songs', 'new song', 'new', 'latest', 'latest songs', 'naye gaane', 'naye gane', 'naya gaana', 'naya gana', 'nayi', 'naye', 'new release', 'new releases', 'trending', 'notun gaan', 'notun gan', 'notun', 'this year', '2025', '2026', 'নতুন গান', 'নতুন', 'नए गाने', 'नया', 'नए', 'नई'],
  };

  static const genres = <String, List<String>>{
    'rabindra': ['rabindra sangeet', 'rabindrasangeet', 'rabindra sangit', 'tagore songs', 'robindro songit', 'রবীন্দ্রসঙ্গীত', 'রবীন্দ্র সঙ্গীত', 'রবীন্দ্রসংগীত'],
    'ghazal': ['ghazal', 'ghazals', 'gazal', 'gazals', 'ग़ज़ल', 'गज़ल'],
    'sufi': ['sufi'],
    'qawwali': ['qawwali', 'qawali', 'kawali'],
    'lofi': ['lofi', 'lo-fi', 'lo fi', 'slowed reverb', 'slowed and reverb'],
    'rap': ['rap', 'hip hop', 'hiphop', 'hip-hop', 'desi hip hop'],
    'rock': ['rock', 'metal'],
    'indie': ['indie'],
    'folk': ['folk', 'baul', 'lok geet', 'lokgeet', 'bhatiyali', 'বাউল', 'লোকগীতি'],
    'classical': ['classical', 'raag', 'raga', 'shastriya'],
    'unplugged': ['unplugged', 'acoustic'],
    'instrumental': ['instrumental', 'no vocals', 'bina lyrics'],
    'edm': ['edm', 'remix', 'remixes', 'mashup'],
  };

  static const energyHigh = ['energetic', 'high energy', 'energy', 'josh', 'joshila', 'upbeat', 'fast', 'tez', 'dhamakedar', 'dhamaka', 'banger', 'bangers', 'loud', 'jhakaas', 'hype', 'pumped', 'জোশ', 'জোরে', 'जोश', 'तेज़'];
  static const energyLow = ['slow', 'soft', 'dheere', 'dheema', 'dheemi', 'mellow', 'halka', 'halke', 'soothing', 'quiet', 'gentle', 'aste', 'dhire', 'ধীরে', 'নরম', 'धीमे', 'धीमा'];

  static const fresh = ['kuch naya', 'kuchh naya', 'kuch nya', 'kuch alag', 'kuchh alag', 'something new', 'something different', 'new for me', 'naya sunao', 'naya kuch', 'jo maine nahi suna', 'jo nahi suna', 'never heard', 'discover', 'discovery', 'notun kichu', 'kichu notun', 'nuton kichu', 'kichu alada', 'অন্য কিছু', 'নতুন কিছু', 'কিছু নতুন', 'कुछ नया', 'कुछ अलग'];
  static const familiar = ['favourite', 'favourites', 'favorite', 'favorites', 'fav', 'favs', 'pasandida', 'pasand wale', 'jo mujhe pasand', 'mere wale', 'my songs', 'priyo', 'priyo gaan', 'amar priyo', 'পছন্দের', 'প্রিয়', 'पसंदीदा'];
  static const mix = ['mere liye mix', 'mere liye', 'mera mix', 'my mix', 'daily mix', 'mix for me', 'amar jonno mix', 'amar jonno', 'amar mix', 'kuch bhi', 'kuchh bhi', 'kuch bhi chalao', 'anything', 'surprise me', 'tum chuno', 'aap chuno', 'tumi bacho', 'tumi choose koro', 'je kono', 'jekono', 'mix', 'আমার জন্য', 'যা খুশি', 'मेरे लिए', 'कुछ भी'];
  static const yesterday = ['jo maine kal suna', 'jo kal suna', 'kal suna', 'kal sune', 'kal wale', 'kal vale', 'kal ke gaane', 'kal wala', 'kal jo suna', 'kal sunne wale', 'yesterday', "yesterday's", 'gotokal', 'gotokaal', 'kalke shunechilam', 'kal shunechilam', 'kal sunechilam', 'kaalke', 'গতকাল', 'কাল শুনেছিলাম', 'कल सुना', 'कल वाले'];
  static const recent = ['abhi jo sun raha tha', 'recently played', 'recent', 'recently', 'haal hi mein', 'last played', 'aaj wale', 'aaj jo suna', 'abhi wale'];

  /// Words that carry no meaning for the request ("play", "bajao", "kuch").
  static const filler = {
    'play', 'plz', 'please', 'pls', 'bajao', 'baja', 'bajade', 'bajado', 'chalao', 'chala', 'chalado', 'lagao', 'laga', 'sunao', 'suna', 'sunna', 'sunaao', 'sunni', 'hai', 'he', 'h', 'kuch', 'kuchh', 'koi', 'mujhe', 'muje', 'mereko', 'mera', 'mere', 'me', 'mein', 'main', 'mai', 'aaj', 'abhi', 'thoda', 'thode', 'bhai', 'yaar', 'yar', 'dj', 'gaane', 'gane', 'gaana', 'gana', 'gaan', 'gan', 'songs', 'song', 'music', 'track', 'tracks', 'some', 'a', 'an', 'the', 'and', 'aur', 'or', 'ar', 'ebong', 'with', 'wale', 'wala', 'vale', 'waale', 'type', 'ke', 'ka', 'ki', 'ko', 'se', 'er', 'r', 'kichu', 'ekta', 'koro', 'shunbo', 'shunao', 'shonao', 'chai', 'chahiye', 'chaiye', 'want', 'i', 'to', 'listen', 'hear', 'put', 'on', 'something', 'for', 'of', 'by', 'like', 'jaisa', 'jaise', 'jaisi', 'moto', 'moton', 'similar', 'style', 'mood', 'hits', 'hit', 'best', 'top', 'only', 'sirf', 'just', 'ab', 'now', 'right', 'ekhon', 'aj', 'today', 'kya', 'what', 'naa', 'na', 'de', 'do', 'dena', 'dijiye', 'ek', 'one', 'set', 'playlist', 'list', 'vibe', 'feel', 'feeling', 'raha', 'rahi', 'rahe', 'hoon', 'hu', 'hun', 'am', 'is', 'are', 'it', 'my', 'karo', 'kar', 'gaao', 'baje', 'bajega', 'vibes', 'hai?', 'chahte', 'ho', 'tha', 'thi', 'wali', 'dikhao', 'chahta', 'chahti', 'give', 'hindi?',
  };

  static const artists = <KnownArtist>[
    KnownArtist('Arijit Singh', 'hindi', ['arijit singh', 'arijit', 'arjit', 'arijeet', 'অরিজিৎ', 'অরিজিত', 'অরিজিৎ সিং', 'अरिजीत', 'अरिजीत सिंह']),
    KnownArtist('Anirudh Ravichander', 'tamil', ['anirudh ravichander', 'anirudh', 'anirudh ravichandar', 'অনিরুদ্ধ', 'अनिरुद्ध']),
    KnownArtist('Shreya Ghoshal', 'hindi', ['shreya ghoshal', 'shreya', 'শ্রেয়া ঘোষাল', 'শ্রেয়া', 'श्रेया घोषाल', 'श्रेया']),
    KnownArtist('A.R. Rahman', 'hindi', ['a.r. rahman', 'ar rahman', 'a r rahman', 'arr', 'rahman', 'এ আর রহমান', 'रहमान']),
    KnownArtist('Atif Aslam', 'hindi', ['atif aslam', 'atif']),
    KnownArtist('Sonu Nigam', 'hindi', ['sonu nigam', 'sonu']),
    KnownArtist('Kishore Kumar', 'hindi', ['kishore kumar', 'kishore', 'kishore da', 'কিশোর কুমার', 'কিশোর', 'किशोर कुमार', 'किशोर']),
    KnownArtist('Lata Mangeshkar', 'hindi', ['lata mangeshkar', 'lata', 'lata ji', 'লতা মঙ্গেশকর', 'লতা', 'लता']),
    KnownArtist('Mohammed Rafi', 'hindi', ['mohammed rafi', 'mohammad rafi', 'md rafi', 'rafi', 'rafi saab', 'রফি', 'रफ़ी', 'रफी']),
    KnownArtist('Asha Bhosle', 'hindi', ['asha bhosle', 'asha', 'আশা ভোঁসলে']),
    KnownArtist('KK', 'hindi', ['kk', 'k.k.']),
    KnownArtist('Pritam', 'hindi', ['pritam', 'pritam chakraborty']),
    KnownArtist('Badshah', 'hindi', ['badshah', 'baadshah']),
    KnownArtist('Yo Yo Honey Singh', 'punjabi', ['yo yo honey singh', 'honey singh', 'yo yo']),
    KnownArtist('Diljit Dosanjh', 'punjabi', ['diljit dosanjh', 'diljit']),
    KnownArtist('Sidhu Moose Wala', 'punjabi', ['sidhu moose wala', 'sidhu moosewala', 'sidhu', 'moosewala']),
    KnownArtist('AP Dhillon', 'punjabi', ['ap dhillon']),
    KnownArtist('Sid Sriram', 'tamil', ['sid sriram']),
    KnownArtist('Jubin Nautiyal', 'hindi', ['jubin nautiyal', 'jubin']),
    KnownArtist('Neha Kakkar', 'hindi', ['neha kakkar', 'neha kakar']),
    KnownArtist('Darshan Raval', 'hindi', ['darshan raval', 'darshan']),
    KnownArtist('Vishal Mishra', 'hindi', ['vishal mishra']),
    KnownArtist('Armaan Malik', 'hindi', ['armaan malik', 'armaan', 'arman malik']),
    KnownArtist('Mohit Chauhan', 'hindi', ['mohit chauhan']),
    KnownArtist('Lucky Ali', 'hindi', ['lucky ali']),
    KnownArtist('Udit Narayan', 'hindi', ['udit narayan', 'udit']),
    KnownArtist('Kumar Sanu', 'hindi', ['kumar sanu', 'sanu da', 'কুমার শানু']),
    KnownArtist('Alka Yagnik', 'hindi', ['alka yagnik', 'alka']),
    KnownArtist('Sunidhi Chauhan', 'hindi', ['sunidhi chauhan', 'sunidhi']),
    KnownArtist('Shaan', 'hindi', ['shaan']),
    KnownArtist('Papon', 'hindi', ['papon', 'angaraag mahanta']),
    KnownArtist('Zubeen Garg', 'assamese', ['zubeen garg', 'zubeen', 'জুবিন গাৰ্গ', 'জুবিন']),
    KnownArtist('Anupam Roy', 'bengali', ['anupam roy', 'anupam', 'অনুপম রায়', 'অনুপম']),
    KnownArtist('Nachiketa', 'bengali', ['nachiketa', 'nachiketa chakraborty', 'নচিকেতা']),
    KnownArtist('Rupam Islam', 'bengali', ['rupam islam', 'rupam', 'রূপম ইসলাম', 'রূপম']),
    KnownArtist('Iman Chakraborty', 'bengali', ['iman chakraborty', 'iman', 'ইমন চক্রবর্তী', 'ইমন']),
    KnownArtist('Shilajit Majumder', 'bengali', ['shilajit', 'shilajit majumder', 'শিলাজিৎ']),
    KnownArtist('Hemanta Mukherjee', 'bengali', ['hemanta mukherjee', 'hemanta', 'hemant kumar', 'হেমন্ত মুখোপাধ্যায়', 'হেমন্ত']),
    KnownArtist('Manna Dey', 'bengali', ['manna dey', 'manna de', 'মান্না দে']),
    KnownArtist('Fossils', 'bengali', ['fossils', 'ফসিলস']),
    KnownArtist('Shankar Mahadevan', 'hindi', ['shankar mahadevan']),
    KnownArtist('Amit Trivedi', 'hindi', ['amit trivedi']),
    KnownArtist('Vishal-Shekhar', 'hindi', ['vishal shekhar', 'vishal-shekhar']),
    KnownArtist('Shankar-Ehsaan-Loy', 'hindi', ['shankar ehsaan loy']),
    KnownArtist('Ilaiyaraaja', 'tamil', ['ilaiyaraaja', 'ilayaraja', 'ilaiyaraja']),
    KnownArtist('Yuvan Shankar Raja', 'tamil', ['yuvan shankar raja', 'yuvan']),
    KnownArtist('Harris Jayaraj', 'tamil', ['harris jayaraj']),
    KnownArtist('S. P. Balasubrahmanyam', 'tamil', ['spb', 's p balasubrahmanyam', 'sp balasubrahmanyam']),
    KnownArtist('Devi Sri Prasad', 'telugu', ['devi sri prasad', 'dsp']),
    KnownArtist('Taylor Swift', 'english', ['taylor swift', 'taylor']),
    KnownArtist('Ed Sheeran', 'english', ['ed sheeran']),
    KnownArtist('The Weeknd', 'english', ['the weeknd', 'weeknd']),
    KnownArtist('Coldplay', 'english', ['coldplay']),
    KnownArtist('Justin Bieber', 'english', ['justin bieber', 'bieber']),
    KnownArtist('Billie Eilish', 'english', ['billie eilish', 'billie']),
    KnownArtist('Dua Lipa', 'english', ['dua lipa']),
    KnownArtist('Imagine Dragons', 'english', ['imagine dragons']),
    KnownArtist('BTS', 'korean', ['bts']),
    KnownArtist('Prateek Kuhad', 'english', ['prateek kuhad', 'prateek']),
    KnownArtist('Divine', 'hindi', ['divine']),
    KnownArtist('King', 'hindi', ['king rocco']),
    KnownArtist('Talwiinder', 'punjabi', ['talwiinder', 'talwinder']),
    KnownArtist('Karan Aujla', 'punjabi', ['karan aujla', 'aujla']),
    KnownArtist('Shubh', 'punjabi', ['shubh']),
    KnownArtist('Guru Randhawa', 'punjabi', ['guru randhawa']),
    KnownArtist('Jagjit Singh', 'hindi', ['jagjit singh', 'jagjit']),
    KnownArtist('Nusrat Fateh Ali Khan', 'urdu', ['nusrat fateh ali khan', 'nusrat', 'nfak']),
    KnownArtist('Rahat Fateh Ali Khan', 'hindi', ['rahat fateh ali khan', 'rahat']),
    KnownArtist('Javed Ali', 'hindi', ['javed ali']),
    KnownArtist('Mithoon', 'hindi', ['mithoon']),
    KnownArtist('Tanishk Bagchi', 'hindi', ['tanishk bagchi']),
    KnownArtist('Sachet Tandon', 'hindi', ['sachet tandon', 'sachet parampara', 'sachet']),
    KnownArtist('B Praak', 'punjabi', ['b praak', 'bpraak']),
    KnownArtist('Raghav Chaitanya', 'hindi', ['raghav chaitanya']),
    KnownArtist('Shankuraj Konwar', 'assamese', ['shankuraj konwar', 'shankuraj']),
    KnownArtist('Lagnajita Chakraborty', 'bengali', ['lagnajita', 'lagnajita chakraborty', 'লগ্নজিতা']),
    KnownArtist('Arnab Dutta', 'bengali', ['arnab dutta']),
    KnownArtist('Nikhita Gandhi', 'hindi', ['nikhita gandhi']),
  ];

  static KnownArtist? languageOfArtist(String name) {
    final n = name.toLowerCase();
    for (final a in artists) {
      if (a.name.toLowerCase() == n) return a;
    }
    return null;
  }
}

/// Parses free text into a [DjRequest].
class DjRequestParser {
  /// Artists from the listener's own history (so "anupam" finds "Anupam Roy"
  /// even when it isn't in the built-in list).
  final List<String> historyArtists;
  DjRequestParser({this.historyArtists = const []});

  static final _latinWord = RegExp(r"[a-z0-9']");

  static String normalize(String s) {
    var t = s.toLowerCase();
    t = t.replaceAll(RegExp(r'[“”"!?¿¡।॥,;:()\[\]{}…]+'), ' ');
    t = t.replaceAll(RegExp(r'\.(?=\s|$)'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  /// Finds [phrase] in [text] as whole word(s); returns the match start or -1.
  static int _find(String text, String phrase) {
    var from = 0;
    while (true) {
      final i = text.indexOf(phrase, from);
      if (i < 0) return -1;
      final end = i + phrase.length;
      final beforeOk = i == 0 || !_isWordChar(text[i - 1], phrase[0]);
      final afterOk = end >= text.length || !_isWordChar(text[end], phrase[phrase.length - 1]);
      if (beforeOk && afterOk) return i;
      from = i + 1;
    }
  }

  static bool _isWordChar(String c, String neighbour) {
    // Latin phrases need word boundaries; Indic phrases may take suffixes
    // (অরিজিতের, প্রেমের), so only Latin letters count as joined.
    if (!_latinWord.hasMatch(neighbour)) return false;
    return _latinWord.hasMatch(c);
  }

  /// Removes [phrase] once from [text] (as a whole word), returns the rest.
  static String _cut(String text, String phrase) {
    final i = _find(text, phrase);
    if (i < 0) return text;
    return '${text.substring(0, i)} ${text.substring(i + phrase.length)}'.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Looks for the longest phrase from [vocab] in [text]; returns its key and phrase.
  static List<(String, String)> _all(String text, Map<String, List<String>> vocab) {
    final hits = <(String, String, int)>[];
    for (final e in vocab.entries) {
      for (final p in e.value) {
        final i = _find(text, p);
        if (i >= 0) hits.add((e.key, p, i));
      }
    }
    // longest phrases first, so "long drive" beats "drive"
    hits.sort((a, b) => b.$2.length.compareTo(a.$2.length));
    final out = <(String, String)>[];
    final usedKeys = <String>{};
    var t = text;
    for (final h in hits) {
      if (usedKeys.contains(h.$1)) {
        t = _cut(t, h.$2);
        continue;
      }
      if (_find(t, h.$2) < 0) continue;
      usedKeys.add(h.$1);
      out.add((h.$1, h.$2));
      t = _cut(t, h.$2);
    }
    return out;
  }

  static final _likeAfter = RegExp(r"(?:\s|^)(jaisa|jaise|jaisi|jesa|jese|type ke|type|types|style|style ke|vibes|ki tarah|ke jaisa|ke jaise|er moto|r moto|er moton|r moton|er mto|moto|er type|ke type)(?=\s|$)");

  List<KnownArtist> get _artistBook => [
    ...DjVocab.artists,
    for (final h in historyArtists)
      if (h.trim().isNotEmpty && !DjVocab.artists.any((a) => a.name.toLowerCase() == h.trim().toLowerCase()))
        KnownArtist(h.trim(), null, [h.trim().toLowerCase(), if (h.trim().split(' ').first.length >= 4) h.trim().split(' ').first.toLowerCase()]),
  ];

  /// Known artists named in [text]: (artist, alias, index).
  List<(KnownArtist, String, int)> _knownArtists(String text) {
    final hits = <(KnownArtist, String, int)>[];
    for (final a in _artistBook) {
      // longest alias first
      final al = [...a.aliases]..sort((x, y) => y.length.compareTo(x.length));
      for (final alias in al) {
        final i = _find(text, alias);
        if (i >= 0) {
          hits.add((a, alias, i));
          break;
        }
      }
    }
    // drop hits contained in a longer hit ("yo yo honey singh" vs "honey singh")
    hits.sort((x, y) => y.$2.length.compareTo(x.$2.length));
    final kept = <(KnownArtist, String, int)>[];
    for (final h in hits) {
      final s = h.$3, e = h.$3 + h.$2.length;
      if (kept.any((k) => s >= k.$3 && e <= k.$3 + k.$2.length)) continue;
      if (kept.any((k) => k.$1.name == h.$1.name)) continue;
      kept.add(h);
    }
    kept.sort((x, y) => x.$3.compareTo(y.$3));
    return kept;
  }

  static bool _vocabWord(String w) {
    if (DjVocab.filler.contains(w)) return true;
    for (final m in [DjVocab.moods, DjVocab.languages, DjVocab.eras, DjVocab.genres]) {
      for (final l in m.values) {
        if (l.contains(w)) return true;
      }
    }
    return DjVocab.energyHigh.contains(w) || DjVocab.energyLow.contains(w);
  }

  /// Cleans a captured artist name: drops request words around it.
  static String? _cleanName(String raw) {
    final words = raw.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    while (words.isNotEmpty && _vocabWord(words.first)) {
      words.removeAt(0);
    }
    while (words.isNotEmpty && _vocabWord(words.last)) {
      words.removeLast();
    }
    if (words.isEmpty || words.length > 4) return words.length > 4 ? words.sublist(words.length - 3).join(' ') : null;
    final n = words.join(' ');
    if (n.length < 2) return null;
    return n.split(' ').map((w) => w.length <= 2 && w != 'kk' ? w.toUpperCase() : _cap(w)).join(' ');
  }

  DjRequest parse(String input) {
    final original = input.trim();
    var t = normalize(original);
    final chips = <DjChip>[];
    void add(DjChip c) {
      if (!chips.contains(c)) chips.add(c);
    }

    if (t.isEmpty) return DjRequest(original, const [DjChip(DjChipKind.mix, 'mix')]);

    // 1) history ("jo maine kal suna"), freshness ("kuch naya"), favourites
    for (final p in [...DjVocab.yesterday]..sort((a, b) => b.length.compareTo(a.length))) {
      if (_find(t, p) >= 0) {
        add(const DjChip(DjChipKind.history, 'yesterday'));
        t = _cut(t, p);
        break;
      }
    }
    if (!chips.any((c) => c.kind == DjChipKind.history)) {
      for (final p in [...DjVocab.recent]..sort((a, b) => b.length.compareTo(a.length))) {
        if (_find(t, p) >= 0) {
          add(const DjChip(DjChipKind.history, 'recent'));
          t = _cut(t, p);
          break;
        }
      }
    }
    for (final p in [...DjVocab.fresh]..sort((a, b) => b.length.compareTo(a.length))) {
      if (_find(t, p) >= 0) {
        add(const DjChip(DjChipKind.fresh, 'fresh'));
        t = _cut(t, p);
      }
    }
    for (final p in [...DjVocab.familiar]..sort((a, b) => b.length.compareTo(a.length))) {
      if (_find(t, p) >= 0) {
        add(const DjChip(DjChipKind.familiar, 'favourites'));
        t = _cut(t, p);
      }
    }

    // 2) artists: known names first, then "X jaisa" / "like X" / "X ke gaane"
    for (final h in _knownArtists(t)) {
      final a = h.$1;
      final alias = h.$2;
      final i = _find(t, alias);
      if (i < 0) continue;
      final before = t.substring(0, i);
      final after = t.substring(i + alias.length);
      final bnAfter = after.replaceFirst(RegExp(r'^\s*'), '');
      final isLike = _likeAfter.matchAsPrefix(after) != null ||
          RegExp(r'^\s*(jaisa|jaise|jaisi|jesa|jese|type|types|style|vibes|ki tarah|ke jaisa|ke jaise|er moto|r moto|er moton|r moton|moto|er type|ke type)(\s|$)').hasMatch(after) ||
          RegExp(r"^(?:'s)?\s*(?:er|r)?\s*moto").hasMatch(after) ||
          RegExp(r'(songs like|like|similar to|sounds like|in the style of)\s*$').hasMatch(before) ||
          RegExp(r'^(?:এর|ের|র|ে)?\s*মত').hasMatch(bnAfter) ||
          RegExp(r'^(?:के|की)?\s*जैस').hasMatch(bnAfter);
      add(DjChip(isLike ? DjChipKind.artistLike : DjChipKind.artistBy, a.name));
      t = _cut(t, alias);
      // drop the marker that went with it
      if (isLike) {
        t = t.replaceFirstMapped(RegExp(r'(^|\s)(jaisa|jaise|jaisi|jesa|jese|ki tarah|ke jaisa|ke jaise|er moto|r moto|er moton|moto|type|style)(?=\s|$)'), (m) => m.group(1)!);
      }
      t = t.replaceAll(RegExp(r'(?:এর|ের|র|ে)?\s*মতো?|(?:के|की)?\s*जैस[ाेी]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    // unknown artists in Latin script
    if (!chips.any((c) => c.kind == DjChipKind.artistBy || c.kind == DjChipKind.artistLike)) {
      final like1 = RegExp(r"(?:^|\s)(?:songs like|like|similar to|sounds like)\s+([a-z][a-z0-9 .'&-]{1,40}?)(?=$|\s+(?:and|but|aur|ar|songs|gaane|wale)\b)").firstMatch(t);
      final like2 = RegExp(r"([a-z][a-z0-9 .'&-]{1,60}?)\s+(?:jaisa|jaise|jaisi|jesa|jese|ki tarah|ke jaisa|ke jaise|er moto|r moto|er moton|type ke|style)(?=\s|$)").firstMatch(t);
      final by1 = RegExp(r"([a-z][a-z0-9 .'&-]{1,60}?)\s+(?:ke|ka|ki|er|r|'s)\s+(?:[a-z]+\s+){0,2}?(?:gaane|gane|gaana|gana|gaan|gan|songs|hits|geet)(?=\s|$)").firstMatch(t);
      final by2 = RegExp(r"(?:^|\s)(?:songs by|songs of|by)\s+([a-z][a-z0-9 .'&-]{1,40}?)(?=$|\s+(?:and|but|aur)\b)").firstMatch(t);
      for (final (m, kind) in [(like1, DjChipKind.artistLike), (like2, DjChipKind.artistLike), (by2, DjChipKind.artistBy), (by1, DjChipKind.artistBy)]) {
        if (m == null) continue;
        final name = _cleanName(m.group(1)!);
        if (name == null) continue;
        add(DjChip(kind, name));
        t = t.replaceFirst(m.group(0)!, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
        break;
      }
    }

    // 3) moods / activities, languages, eras, genres, energy
    for (final (k, p) in _all(t, DjVocab.genres)) {
      add(DjChip(DjChipKind.genre, k));
      if (k == 'rabindra') add(const DjChip(DjChipKind.language, 'bengali'));
      t = _cut(t, p);
    }
    final eraHits = _all(t, DjVocab.eras);
    // a decade ("90s") is more precise than "purane"
    eraHits.sort((a, b) => (a.$1 == 'old' || a.$1 == 'new' ? 1 : 0).compareTo(b.$1 == 'old' || b.$1 == 'new' ? 1 : 0));
    for (final (k, p) in eraHits) {
      if (!chips.any((c) => c.kind == DjChipKind.era)) add(DjChip(DjChipKind.era, k));
      t = _cut(t, p);
    }
    for (final (k, p) in _all(t, DjVocab.moods)) {
      add(DjChip(DjVocab.activities.contains(k) ? DjChipKind.activity : DjChipKind.mood, k));
      t = _cut(t, p);
    }
    for (final (k, p) in _all(t, DjVocab.languages)) {
      add(DjChip(DjChipKind.language, k));
      t = _cut(t, p);
    }
    for (final p in [...DjVocab.energyHigh]..sort((a, b) => b.length.compareTo(a.length))) {
      if (_find(t, p) >= 0) {
        add(const DjChip(DjChipKind.energy, 'high'));
        t = _cut(t, p);
        break;
      }
    }
    if (!chips.any((c) => c.kind == DjChipKind.energy)) {
      for (final p in [...DjVocab.energyLow]..sort((a, b) => b.length.compareTo(a.length))) {
        if (_find(t, p) >= 0) {
          add(const DjChip(DjChipKind.energy, 'low'));
          t = _cut(t, p);
          break;
        }
      }
    }
    // "party" means high energy, "sleep" low, unless said otherwise
    final mixWords = [...DjVocab.mix]..sort((a, b) => b.length.compareTo(a.length));
    for (final p in mixWords) {
      if (_find(t, p) >= 0) {
        if (chips.isEmpty || chips.every((c) => c.kind == DjChipKind.fresh || c.kind == DjChipKind.familiar)) add(const DjChip(DjChipKind.mix, 'mix'));
        t = _cut(t, p);
      }
    }

    // 4) whatever is left and meaningful becomes a free search
    final rest = t.split(' ').where((w) => w.isNotEmpty && !_vocabWord(w)).join(' ').trim();
    if (chips.isEmpty) {
      if (rest.isEmpty) return DjRequest(original, const [DjChip(DjChipKind.mix, 'mix')]);
      add(DjChip(DjChipKind.text, rest));
    }
    return DjRequest(original, chips);
  }
}
