import 'dart:convert';
import 'dart:math';

import 'package:byte/core/models.dart';
import 'package:byte/data/play_log.dart';
import 'package:byte/dj/dj_chat.dart';
import 'package:byte/dj/dj_controller.dart';
import 'package:byte/dj/dj_lines.dart';
import 'package:byte/dj/dj_session.dart';
import 'package:byte/dj/recommender.dart';
import 'package:byte/dj/request_parser.dart';
import 'package:byte/dj/speech_input.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/dj_talk.dart';
import 'package:byte/ui/screens/dj_chat_screen.dart';
import 'package:byte/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'dj_test.dart' show FakeYt, SpeechSpy, song;
import 'helpers.dart';
import 'screens_test.dart' show settle;

/// Byte 1.3 "Talk to your DJ": the request parser, the recommender, the DJ
/// chat screen, sections + host voice, the floating DJ button.

// ── doubles ──────────────────────────────────────────────────────────────

/// Candidate source with fixed answers per seed / query.
class FakeSource implements CandidateSource {
  final Map<String, List<Item>> radios;
  final Map<String, List<Item>> searches;
  final List<Item> fallbackSearch;
  final List<Item> playlistItems;
  final List<String> calls = [];
  FakeSource({this.radios = const {}, this.searches = const {}, this.fallbackSearch = const [], this.playlistItems = const []});
  @override
  Future<List<Item>> radio(Item seed) async {
    calls.add('radio:${seed.id}');
    return radios[seed.id] ?? const [];
  }

  @override
  Future<List<Item>> search(String query) async {
    calls.add('search:$query');
    return searches[query] ?? fallbackSearch;
  }

  @override
  Future<List<Item>> playlist(String query) async {
    calls.add('playlist:$query');
    return playlistItems;
  }
}

class FakeSpeech implements SpeechInput {
  MicStatus status;
  List<String> say;
  bool _l = false;
  int inits = 0;
  FakeSpeech(this.status, {this.say = const []});
  @override
  Future<MicStatus> init() async {
    inits++;
    return status;
  }

  @override
  bool get listening => _l;
  @override
  Future<void> listen({required String locale, required void Function(String text, bool isFinal) onText, void Function(String reason)? onError}) async {
    _l = true;
    for (var i = 0; i < say.length; i++) {
      onText(say[i], i == say.length - 1);
    }
    _l = false;
  }

  @override
  Future<void> stop() async => _l = false;
}

Item s(String id, String artist, {String? title, int sec = 200}) =>
    Item(kind: ItemKind.song, id: id.padRight(11, '_'), title: title ?? 'Song $id', artists: [ArtistRef(artist)], durationSec: sec);

List<Item> many(String prefix, String artist, int n) => [for (var i = 0; i < n; i++) s('$prefix$i', artist)];

/// A taste profile filled by hand.
TasteProfile taste({Map<String, double> plays = const {}, Iterable<Item> known = const [], Set<String> liked = const {}, Map<String, double> artists = const {}, List<Item> recent = const []}) {
  final t = TasteProfile();
  for (final k in known) {
    t.songs[k.id] = k;
  }
  t.plays.addAll(plays);
  t.liked.addAll(liked);
  t.artist.addAll(artists);
  t.recent.addAll(recent);
  return t;
}

bool varietyOk(List<DjPick> picks, {int max = 2, int window = 10}) {
  for (var i = 0; i < picks.length; i++) {
    final w = picks.skip(i).take(window).map((p) => p.item.artists.first.name).toList();
    for (final a in w.toSet()) {
      if (w.where((x) => x == a).length > max) return false;
    }
  }
  return true;
}

Future<void> addHistoryAt(Item it, DateTime at) async {
  final box = Hive.box('history');
  await box.put(it.id, jsonEncode({'item': it.toJson(), 'at': at.millisecondsSinceEpoch}));
}

void main() {
  // ── 1. the request parser ─────────────────────────────────────────────
  group('request parser (Hinglish / Bengali / English)', () {
    final p = DjRequestParser(historyArtists: const ['Mitraz', 'Anuv Jain']);
    // phrase → chips that must be understood (kind:value)
    const cases = <String, List<String>>{
      'sad Hindi': ['mood:sad', 'language:hindi'],
      'party Bengali': ['mood:party', 'language:bengali'],
      'Arijit jaisa': ['artistLike:Arijit Singh'],
      'workout': ['activity:workout'],
      'kya sunna hai? sad hindi gaane bajao': ['mood:sad', 'language:hindi'],
      'Arijit ke gaane': ['artistBy:Arijit Singh'],
      'Arijit ke sad gaane': ['artistBy:Arijit Singh', 'mood:sad'],
      '90s ke purane romantic gaane': ['era:90s', 'mood:romantic'],
      'purane hindi gaane': ['era:old', 'language:hindi'],
      'latest tamil songs': ['era:new', 'language:tamil'],
      'kuch naya sunao': ['fresh:fresh'],
      'jo maine kal suna': ['history:yesterday'],
      "yesterday's songs": ['history:yesterday'],
      'mere liye mix': ['mix:mix'],
      'surprise me': ['mix:mix'],
      'something like Anirudh': ['artistLike:Anirudh Ravichander'],
      'songs by Taylor Swift': ['artistBy:Taylor Swift'],
      'Anupam Roy er moto gaan': ['artistLike:Anupam Roy'],
      'Kishore Kumar er gaan': ['artistBy:Kishore Kumar'],
      'অরিজিতের মতো গান': ['artistLike:Arijit Singh'],
      'মন খারাপের গান': ['mood:sad'],
      'বাংলা প্রেমের গান': ['mood:romantic', 'language:bengali'],
      'mon kharap, bangla gaan': ['mood:sad', 'language:bengali'],
      'notun bangla gaan': ['era:new', 'language:bengali'],
      'kichu notun shunao': ['fresh:fresh'],
      'rabindra sangeet': ['genre:rabindra', 'language:bengali'],
      'party songs high energy': ['mood:party', 'energy:high'],
      'slow romantic english songs': ['mood:romantic', 'language:english', 'energy:low'],
      'chill lofi for study': ['mood:chill', 'genre:lofi', 'activity:focus'],
      'neend ke liye soft gaane': ['activity:sleep', 'energy:low'],
      'long drive punjabi': ['activity:drive', 'language:punjabi'],
      'gym ke liye punjabi': ['activity:workout', 'language:punjabi'],
      'bhajan': ['mood:devotional'],
      'like the weeknd but sad': ['artistLike:The Weeknd', 'mood:sad'],
      'Atif Aslam jaise gaane but new': ['artistLike:Atif Aslam', 'era:new'],
      'नए हिंदी गाने': ['era:new', 'language:hindi'],
      'अरिजीत के गाने': ['artistBy:Arijit Singh'],
      'उदास गाने': ['mood:sad'],
      'Mitraz jaisa': ['artistLike:Mitraz'],
      'songs like Anuv Jain': ['artistLike:Anuv Jain'],
      'Raftaar ke gaane': ['artistBy:Raftaar'],
      'feel good happy hindi': ['mood:happy', 'language:hindi'],
      'dukhi wale gaane': ['mood:sad'],
      'play some Coldplay': ['artistBy:Coldplay'],
      'Prateek Kuhad type': ['artistLike:Prateek Kuhad'],
      'sad hindi, Arijit jaisa': ['mood:sad', 'language:hindi', 'artistLike:Arijit Singh'],
      'Anirudh jaisa kuch party wala': ['artistLike:Anirudh Ravichander', 'mood:party'],
      'shreya ghoshal er romantic gaan': ['artistBy:Shreya Ghoshal', 'mood:romantic'],
    };
    for (final e in cases.entries) {
      test('"${e.key}"', () {
        final r = p.parse(e.key);
        final got = r.chips.map((c) => c.toString()).toSet();
        for (final want in e.value) {
          expect(got, contains(want), reason: '${e.key} → $got');
        }
        // nothing contradictory: one era at most, one history at most
        expect(r.chips.where((c) => c.kind == DjChipKind.era).length, lessThanOrEqualTo(1));
      });
    }

    test('${cases.length} phrases are covered (30+)', () => expect(cases.length, greaterThanOrEqualTo(30)));

    test('empty or filler-only text = a mix from history', () {
      expect(p.parse('').isMix, isTrue);
      expect(p.parse('kuch bhi chalao bhai').isMix, isTrue);
    });

    test('unknown words become a plain search, not a guess', () {
      final r = p.parse('Kesariya');
      expect(r.freeText, 'kesariya');
      expect(r.queries, ['kesariya']);
    });

    test('queries for YouTube Music are built from the chips', () {
      expect(p.parse('90s sad hindi').queries, ['90s hindi sad songs']);
      expect(p.parse('Arijit ke sad gaane').queries, ['Arijit Singh sad songs']);
    });

    test('chips can be removed and swapped', () {
      final r = p.parse('sad hindi');
      final sad = r.chips.firstWhere((c) => c.kind == DjChipKind.mood);
      expect(r.without(sad).moods, isEmpty);
      final party = r.replace(sad, const DjChip(DjChipKind.mood, 'party'));
      expect(party.moods, ['party']);
      expect(party.languages, ['hindi']);
      expect(DjChatLines.alternatives(sad), contains(const DjChip(DjChipKind.mood, 'party')));
    });

    test('labels have no other app / AI names', () {
      final bad = RegExp(r'spotify|google|youtube|apple|amazon|chatgpt|openai|\bAI\b|siri|alexa', caseSensitive: false);
      for (final e in cases.keys) {
        for (final c in p.parse(e).chips) {
          expect(bad.hasMatch(c.label), isFalse);
        }
      }
    });
  });

  // ── 2. the recommender ────────────────────────────────────────────────
  group('recommender ranking', () {
    setUpAll(() async => makeServices());
    test('skips push an artist down, likes pull one up', () async {
      // two artists equally relevant; he skips "Skippy" and likes "Lovely"
      final skippy = many('sk', 'Skippy', 3), lovely = many('lv', 'Lovely', 3), other = many('ot', 'Other', 3);
      final results = [skippy[0], other[0], lovely[0], skippy[1], other[1], lovely[1], skippy[2], other[2], lovely[2]];
      final t = taste();
      t.artistSkipRate['skippy'] = 1.0;
      t.artist['lovely'] = 1.0;
      final rec = DjRecommender(source: FakeSource(fallbackSearch: results), taste: () => t);
      final m = await rec.mix(DjRequestParser().parse('sad hindi'), size: 9);
      final ids = m.picks.map((p) => p.item.id).toList();
      expect(ids.indexOf(lovely[0].id), lessThan(ids.indexOf(other[0].id)));
      expect(ids.indexOf(other[0].id), lessThan(ids.indexOf(skippy[0].id)));
    });

    test('skips and full listens come from the play log', () {
      final log = PlayLog();
      final now = DateTime(2026, 11, 2, 21);
      for (var i = 0; i < 4; i++) {
        log.add(PlayEvent(s('skp$i', 'Skippy'), now.subtract(Duration(hours: i + 1)), 6000, 200000));
        log.add(PlayEvent(s('ful$i', 'Fully'), now.subtract(Duration(hours: i + 1, minutes: 5)), 195000, 200000));
        log.add(PlayEvent(s('pal$i', 'Pal'), now.subtract(Duration(hours: i + 1, minutes: 9)), 190000, 200000));
      }
      final t = TasteProfile.build(library: Services.i.library, stats: Services.i.stats, log: log, now: now);
      expect(t.artistSkipRate['skippy'], 1.0);
      expect(t.artistSkipRate['fully'], 0.0);
      expect((t.artist['fully'] ?? 0), greaterThan(t.artist['skippy'] ?? 0));
      expect(t.skips['skp0'.padRight(11, '_')], 1);
      expect(t.completes['ful0'.padRight(11, '_')], 1);
      // played together within 30 min → co-listened
      expect(t.coArtists['fully']?['pal'], isNotNull);
      expect(t.coArtists['fully']?['skippy'], isNull); // a skip is not "played together"
    }, skip: false);

    test('variety: never more than 2 songs by one artist in any 10', () async {
      // results come grouped by artist (the worst case)
      final pool = [for (final a in ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']) ...many(a, a, 5)];
      final rec = DjRecommender(source: FakeSource(fallbackSearch: pool, playlistItems: pool), taste: () => taste());
      final m = await rec.mix(DjRequestParser().parse('party'), size: 30);
      expect(m.picks.length, greaterThanOrEqualTo(25));
      expect(varietyOk(m.picks), isTrue, reason: m.picks.map((p) => p.item.artists.first.name).join(','));
    });

    test('"X ke gaane" is all X (the artist cap does not apply)', () async {
      final arijit = many('ar', 'Arijit Singh', 12), rest = many('rs', 'Someone', 4);
      final rec = DjRecommender(source: FakeSource(searches: {'Arijit Singh songs': [...arijit, ...rest]}), taste: () => taste());
      final m = await rec.mix(DjRequestParser().parse('Arijit ke gaane'), size: 10);
      expect(m.picks.take(10).where((p) => p.item.artists.first.name == 'Arijit Singh').length, greaterThanOrEqualTo(9));
      expect(m.picks.first.reason, contains('Arijit Singh'));
    });

    test('freshness: about a quarter of the mix is new to him', () async {
      final known = [for (final a in 'ABCDEFGHIJKL'.split('')) ...many('k$a', 'K$a', 3)];
      final fresh = [for (final a in 'MNOPQRSTUVWX'.split('')) ...many('f$a', 'F$a', 3)];
      final t = taste(known: known, plays: {for (final k in known) k.id: 3});
      final mixed = [for (var i = 0; i < known.length; i++) ...[fresh[i], known[i]]];
      final rec = DjRecommender(source: FakeSource(fallbackSearch: mixed, playlistItems: mixed.reversed.toList()), taste: () => t);
      final m = await rec.mix(DjRequestParser().parse('romantic'), size: 20);
      final share = m.picks.where((p) => p.fresh).length / m.picks.length;
      expect(share, inInclusiveRange(0.2, 0.35), reason: '$share');
      // "kuch naya" turns it up
      final m2 = await rec.mix(DjRequestParser().parse('kuch naya romantic'), size: 20);
      expect(m2.picks.where((p) => p.fresh).length / m2.picks.length, greaterThan(0.5));
    });

    test('no repeats from his last plays', () async {
      final pool = [for (final a in 'ABCDEFGHIJ'.split('')) ...many(a, a, 3)];
      final recent = pool.take(8).toList();
      final t = taste(known: pool, recent: recent, plays: {for (final p in pool) p.id: 2});
      final rec = DjRecommender(source: FakeSource(fallbackSearch: pool), taste: () => t);
      final m = await rec.mix(DjRequestParser().parse('chill'), size: 20);
      final ids = m.picks.map((p) => p.item.id).toSet();
      expect(ids.intersection(recent.map((e) => e.id).toSet()), isEmpty);
    });

    test('live re-rank: after a skip that artist moves down the queue', () async {
      final pool = [for (final a in ['A', 'B', 'C', 'D', 'E', 'F']) ...many(a, a, 6)];
      final rec = DjRecommender(source: FakeSource(fallbackSearch: pool), taste: () => taste());
      final m = await rec.mix(DjRequestParser().parse('workout'), size: 20);
      final first = m.picks.first;
      final next = m.picks.skip(1).take(6).map((p) => p.item.artists.first.name).toList();
      final victim = next.first;
      expect(next.where((a) => a == victim), isNotEmpty);
      // he skipped the first song, which was by [victim]'s artist? make sure: skip a song by victim
      final victimSong = m.picks.firstWhere((p) => p.item.artists.first.name == victim).item;
      m.feedback(victimSong, DjFeedback.skip);
      final up = m.rerank([first.item, victimSong]);
      final firstVictim = up.indexWhere((p) => p.item.artists.first.name == victim);
      expect(firstVictim == -1 || firstVictim >= 4, isTrue, reason: up.map((p) => p.item.artists.first.name).join(','));
      expect(up.any((p) => p.item.id == victimSong.id), isFalse);
      // a like brings an artist forward
      final liked = up.last.item;
      m.feedback(liked, DjFeedback.like);
      final up2 = m.rerank([first.item, victimSong]);
      expect(up2.indexWhere((p) => p.item.artists.first.name == liked.artists.first.name), lessThan(up.length - 1));
    });

    test('"mere liye mix": radio of his favourites, mostly songs he loves, each with a reason', () async {
      final favs = [for (final a in 'ABCDEFGH'.split('')) ...many('m$a', 'M$a', 4)];
      final t = taste(known: favs, plays: {for (var i = 0; i < favs.length; i++) favs[i].id: 10.0 - i / 4});
      final src = FakeSource(radios: {for (final f in favs) f.id: many('r${f.id.substring(1, 3)}', 'Radio ${f.id.substring(1, 3)}', 5)});
      final rec = DjRecommender(source: src, taste: () => t);
      final m = await rec.mix(DjRequestParser().parse('mere liye mix'), size: 20);
      expect(src.calls.where((c) => c.startsWith('radio:')).length, greaterThanOrEqualTo(3));
      expect(m.picks.where((p) => !p.fresh).length, greaterThan(m.picks.length / 2));
      expect(m.picks.every((p) => p.reason.isNotEmpty), isTrue);
      final fresh = m.picks.firstWhere((p) => p.fresh);
      expect(fresh.reason, startsWith('New for you'));
      expect(varietyOk(m.picks), isTrue);
    });

    test('"like X": radio from X, reasons say "New for you, like X"', () async {
      final seed = s('arj', 'Arijit Singh', title: 'Kesariya');
      final radio = [for (final a in 'ABCDEFGHIJ'.split('')) ...many('x$a', 'X$a', 2)];
      final src = FakeSource(searches: {'Arijit Singh songs': [seed]}, radios: {seed.id: radio});
      final m = await DjRecommender(source: src, taste: () => taste()).mix(DjRequestParser().parse('Arijit jaisa'), size: 12);
      expect(src.calls, contains('radio:${seed.id}'));
      expect(m.picks.where((p) => p.reason == 'New for you, like Arijit Singh').length, greaterThan(5));
    });

    test('"jo maine kal suna": yesterday\'s songs first', () async {
      final y = many('y', 'Y', 6);
      final t = taste(known: y);
      t.yesterday.addAll(y);
      final m = await DjRecommender(source: FakeSource(), taste: () => t).mix(DjRequestParser().parse('jo maine kal suna'), size: 10);
      expect(m.picks.take(3).every((p) => p.reason == 'You played this yesterday'), isTrue);
    });

    test('offline: an empty mix, no crash', () async {
      final m = await DjRecommender(source: FakeSource(), taste: () => taste()).mix(DjRequestParser().parse('sad hindi'));
      expect(m.picks, isEmpty);
    });
  });

  // ── 3. the DJ controller: request mode, sections, voice ──────────────
  group('DJ controller (real player)', () {
    late Services sv;
    late DjController dj;
    late FakeSource src;
    final pool = [for (final a in ['A', 'B', 'C', 'D', 'E', 'F', 'G']) ...many('q$a', 'Q$a', 6)];

    setUp(() async {
      sv = await makeServices();
      sv.settings.autoplay = false;
      sv.settings.verifyStreams = false;
      sv.settings.djName = 'Apurba';
      await sv.library.clearHistory();
      fakeAudio.durationFor = (_) => const Duration(seconds: 200);
      src = FakeSource(fallbackSearch: pool);
      dj = DjController(
        player: sv.player,
        brain: DjBrain(library: sv.library, stats: sv.stats, yt: FakeYt(), rng: Random(5), now: () => DateTime(2026, 11, 2, 20)),
        settings: sv.settings,
        now: () => DateTime(2026, 11, 2, 20),
        recommender: DjRecommender(source: src, taste: () => taste()),
        library: sv.library,
      );
    });
    tearDown(() async {
      dj.stop();
      dj.dispose();
      await sv.player.stop();
    });

    Future<void> until(bool Function() ok, {int ms = 8000}) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    test('plays a request with a reason on every song', () async {
      final picks = await dj.playRequest(DjRequestParser().parse('sad hindi'));
      expect(picks, isNotEmpty);
      expect(dj.inRequest, isTrue);
      expect(sv.player.current.value!.id, picks.first.item.id);
      expect(sv.player.playingFrom.value, 'DJ · Sad Hindi');
      for (final p in dj.upcomingPicks) {
        expect(p.reason, isNotEmpty);
      }
    });

    test('a quick skip re-ranks the rest of the queue live', () async {
      await dj.playRequest(DjRequestParser().parse('party'));
      final first = sv.player.current.value!;
      final artist = first.artists.first.name;
      await sv.player.skipToNext(); // after ~0 s: a skip
      await until(() => dj.skipsLearned == 1);
      final upcoming = dj.upcomingPicks.take(4).map((p) => p.item.artists.first.name);
      expect(upcoming, isNot(contains(artist)));
      // the queue still holds the mix, no song twice
      final ids = sv.player.queueModel.playOrder.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('liking the playing song is learned', () async {
      await dj.playRequest(DjRequestParser().parse('party'));
      await sv.library.setLiked(sv.player.current.value!, true);
      await until(() => dj.likesLearned == 1);
    });

    test('playing something else ends the requested mix', () async {
      await dj.playRequest(DjRequestParser().parse('party'));
      await sv.player.playItems([song('elsewhere11', 'Not DJ')]);
      await until(() => !dj.active);
    });

    test('a chat request plays with no spoken reply and no dip (1.4.3)', () async {
      final spy = SpeechSpy()..install();
      addTearDown(spy.remove);
      await dj.playRequest(DjRequestParser().parse('chill'));
      await until(() => sv.player.playing);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(spy.calls, isEmpty);
      expect(sv.player.duckLevel, 1.0);
    });
  });

  group('sections (radio show)', () {
    late Services sv;
    final now = DateTime(2026, 11, 2, 20);
    late DjBrain brain;

    setUp(() async {
      sv = await makeServices();
      await sv.library.clearHistory();
      for (final it in sv.library.likes) {
        await sv.library.setLiked(it, false);
      }
      for (var i = 0; i < 10; i++) {
        await sv.library.setLiked(song('fv$i'.padRight(11, 'F'), 'Fav $i'), true);
      }
      for (var i = 0; i < 8; i++) {
        await addHistoryAt(song('tb$i'.padRight(11, 'T'), 'Old $i'), DateTime(2026, 3, 10 + i));
      }
      brain = DjBrain(library: sv.library, stats: sv.stats, yt: FakeYt(), rng: Random(9), now: () => now);
    });

    test('favourites → throwbacks → new for you → favourites, 4 to 6 songs each', () async {
      final used = <String>{};
      final kinds = <SegmentKind>[];
      for (var i = 0; i < 4; i++) {
        final seg = (await brain.next(exclude: used))!;
        kinds.add(seg.kind);
        expect(seg.items.length, inInclusiveRange(4, 6), reason: '${seg.kind}');
        used.addAll(seg.items.map((e) => e.id));
      }
      expect(kinds, [SegmentKind.favourites, SegmentKind.throwback, SegmentKind.discover, SegmentKind.favourites]);
    });

    test('throwbacks only come from his history, with when he played them', () async {
      final seg = (await brain.build(SegmentKind.throwback))!;
      final hist = sv.library.history.map((h) => h.item.id).toSet();
      expect(seg.items.every((i) => hist.contains(i.id)), isTrue);
      expect(seg.period, 'March');
      expect(seg.title, 'March throwbacks');
      final line = DjLinesFor.throwback(seg);
      expect(line, contains('March'));
    });

    test('no history → no throwback section (never made up from search)', () async {
      await sv.library.clearHistory();
      expect(await brain.build(SegmentKind.throwback), isNull);
    });

    test('new discoveries are songs he has never played', () async {
      final seg = (await brain.build(SegmentKind.discover))!;
      final known = brain.known();
      expect(seg.items.any((i) => known.contains(i.id)), isFalse);
    });
  });

  // ── 4. the DJ chat screen ─────────────────────────────────────────────
  group('DJ chat screen', () {
    late Services sv;

    setUpAll(() async {
      sv = await makeServices();
      sv.settings.autoplay = false;
      sv.settings.verifyStreams = false;
      sv.settings.djLanguage = 'hinglish';
      sv.settings.djName = '';
      await sv.library.clearHistory();
      final now = DateTime.now();
      for (var i = 0; i < 5; i++) {
        await addHistoryAt(song('hA$i'.padRight(11, 'A'), 'Tum Hi Ho $i', artist: 'Arijit Singh'), now.subtract(Duration(hours: i + 1)));
      }
      for (var i = 0; i < 3; i++) {
        await addHistoryAt(song('hB$i'.padRight(11, 'B'), 'Chaleya $i', artist: 'Anirudh Ravichander'), now.subtract(Duration(hours: i + 7)));
      }
    });

    Future<void> pumpChat(WidgetTester tester, {MicStatus mic = MicStatus.ready, List<String> say = const []}) async {
      tester.view.physicalSize = const Size(390, 1700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final pool = [for (final a in ['A', 'B', 'C', 'D', 'E', 'F', 'G']) ...many('w$a', 'W$a', 5)];
      sv.dj = DjController(
        player: sv.player,
        brain: DjBrain(library: sv.library, stats: sv.stats, yt: FakeYt()),
        settings: sv.settings,
        recommender: DjRecommender(source: FakeSource(fallbackSearch: pool), taste: () => TasteProfile.build(library: sv.library, stats: sv.stats)),
        library: sv.library,
      );
      sv.speech = FakeSpeech(mic, say: say);
      await tester.pumpWidget(MaterialApp(theme: ByteTheme.build(Brightness.light), home: const DjChatScreen()));
      await settle(tester);
    }

    Future<void> afterTap(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
      await settle(tester);
    }

    Future<void> done(WidgetTester tester) async {
      await tester.runAsync(() async {
        sv.dj.stop();
        await sv.player.stop();
      });
      await settle(tester);
    }

    testWidgets('greeting uses his history (top artists lately)', (tester) async {
      await pumpChat(tester);
      expect(find.textContaining('Aaj kal tum Arijit aur Anirudh zyada sun rahe ho'), findsOneWidget);
      // ideas by mood / language / artist / era / activity
      for (final k in const ['idea:Sad', 'idea:Bengali', 'idea:Arijit jaisa', 'idea:90s', 'idea:Workout']) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping an idea sends it', (tester) async {
      await pumpChat(tester);
      await tester.tap(find.byKey(const Key('idea:Arijit jaisa')));
      await afterTap(tester);
      expect(find.byKey(const Key('understood:artistLike:Arijit Singh')), findsOneWidget);
      expect(find.byKey(const Key('idea:Sad')), findsNothing); // ideas go once the chat starts
      await done(tester);
    });

    testWidgets('tapping a quick pick sends it and plays, with reasons', (tester) async {
      await pumpChat(tester);
      await tester.tap(find.byKey(const Key('quick:Sad Hindi')));
      await afterTap(tester);
      expect(find.text('sad hindi'), findsOneWidget); // his bubble
      expect(find.byKey(const Key('understood:mood:sad')), findsOneWidget);
      expect(find.byKey(const Key('understood:language:hindi')), findsOneWidget);
      expect(sv.dj.inRequest, isTrue);
      expect(find.textContaining('Yeh lo!'), findsOneWidget);
      expect(find.textContaining('New for you'), findsWidgets);
      expect(tester.takeException(), isNull);
      await done(tester);
    });

    testWidgets('a typed request shows what was understood as chips; removing one re-plans', (tester) async {
      await pumpChat(tester);
      await tester.enterText(find.byKey(const Key('djChatInput')), 'Arijit ke romantic gaane');
      await tester.tap(find.byKey(const Key('djChatSend')));
      await afterTap(tester);
      expect(find.byKey(const Key('understood:artistBy:Arijit Singh')), findsOneWidget);
      expect(find.byKey(const Key('understood:mood:romantic')), findsOneWidget);
      expect(sv.dj.request!.byArtists, ['Arijit Singh']);
      // remove the mood chip
      final chip = find.byKey(const Key('understood:mood:romantic'));
      await tester.tap(find.descendant(of: chip, matching: find.byIcon(Icons.close_rounded)));
      await afterTap(tester);
      expect(sv.dj.request!.moods, isEmpty);
      expect(sv.dj.request!.byArtists, ['Arijit Singh']);
      expect(tester.takeException(), isNull);
      await done(tester);
    });

    testWidgets('mic permission denied: a clear message and the text box to type in', (tester) async {
      await pumpChat(tester, mic: MicStatus.denied);
      await tester.tap(find.byKey(const Key('djChatMic')));
      await afterTap(tester);
      expect(find.textContaining('Mic ki permission nahi mili'), findsOneWidget);
      expect(find.text('Microphone permission is off'), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const Key('djChatInput')));
      expect(field.focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('mic not available on the phone: says so, text still works', (tester) async {
      await pumpChat(tester, mic: MicStatus.unavailable);
      await tester.tap(find.byKey(const Key('djChatMic')));
      await afterTap(tester);
      expect(find.textContaining('voice se bolna abhi kaam nahi kar raha'), findsOneWidget);
    });

    testWidgets('speaking a request: the words go in and play', (tester) async {
      await pumpChat(tester, say: const ['party', 'party bengali']);
      await tester.tap(find.byKey(const Key('djChatMic')));
      await afterTap(tester);
      expect(find.byKey(const Key('understood:mood:party')), findsOneWidget);
      expect(find.byKey(const Key('understood:language:bengali')), findsOneWidget);
      await done(tester);
    });

    testWidgets('no spoken-replies toggle any more (the DJ never speaks)', (tester) async {
      await pumpChat(tester);
      expect(find.byKey(const Key('djChatSpeak')), findsNothing);
      expect(find.text('Speaking…'), findsNothing);
    });

    testWidgets('floating DJ button: hold to talk with the mic denied explains and does nothing', (tester) async {
      await pumpChat(tester, mic: MicStatus.denied);
      await tester.pumpWidget(
        MaterialApp(
          theme: ByteTheme.build(Brightness.light),
          home: const Scaffold(body: Center(child: DjFloatingButton())),
        ),
      );
      await settle(tester);
      await tester.longPress(find.byKey(const Key('djFloatingButton')));
      await afterTap(tester);
      expect(find.textContaining('Mic ki permission nahi hai'), findsOneWidget);
      expect(sv.dj.inRequest, isFalse);
    });

    testWidgets('floating DJ button: hold to talk plays what was said', (tester) async {
      await pumpChat(tester, say: const ['sad hindi']);
      await tester.pumpWidget(
        MaterialApp(
          theme: ByteTheme.build(Brightness.light),
          home: const Scaffold(body: Center(child: DjFloatingButton())),
        ),
      );
      await settle(tester);
      final g = await tester.startGesture(tester.getCenter(find.byKey(const Key('djFloatingButton'))));
      await tester.pump(const Duration(milliseconds: 700));
      await afterTap(tester);
      await g.up();
      await afterTap(tester);
      await afterTap(tester);
      expect(sv.dj.inRequest, isTrue);
      expect(sv.dj.request!.moods, ['sad']);
      await done(tester);
    });
  });
}

/// The throwback line for a section, as the DJ would say it.
class DjLinesFor {
  static String throwback(DjSegment seg) => DjLines(rng: Random(1)).line(seg.moment, name: 'Apurba', hinglish: true, now: DateTime(2026, 11, 2, 20), period: seg.period);
}
