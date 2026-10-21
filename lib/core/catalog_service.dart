import 'dart:async';

import 'app_log.dart';
import 'models.dart';
import 'node_service.dart';
import 'utils.dart';

/// Search + playable-track matching. All audio links are resolved by the
/// Lumino server node, which parses the catalog and proxies the audio file.
class CatalogService {
  CatalogService(this.node);
  final NodeService node;

  final Map<String, ({int at, List<Track> tracks})> _cache = {};
  final Map<String, Future<List<Track>>> _inflight = {};
  bool _down = false;
  String _lastError = '';

  ({bool unavailable, String error}) get searchStatus => (unavailable: _down, error: _lastError);

  Future<List<Track>> search(String query, {Duration timeout = const Duration(seconds: 60)}) async {
    final q = query.trim();
    if (q.length < 2) return [];
    final key = q.toLowerCase();
    final hit = _cache[key];
    if (hit != null && DateTime.now().millisecondsSinceEpoch - hit.at < 45000) return hit.tracks;
    if (_inflight.containsKey(key)) return _inflight[key]!;
    final future = _searchImpl(q, timeout);
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<List<Track>> searchFresh(String query) async {
    _cache.remove(query.trim().toLowerCase());
    return search(query);
  }

  Future<List<Track>> _searchImpl(String q, Duration timeout) async {
    dynamic payload;
    try {
      final result = await node.request('/api/search', params: {'q': q, 'limit': 50}, timeout: timeout);
      payload = result.data;
    } catch (error) {
      _down = true;
      _lastError = 'server node unavailable: $error';
      AppLog.instance.log(LogLevel.warn, 'catalog', 'search "${AppLog.clip(q, 60)}" unavailable', error: error);
      return [];
    }
    final data = asMap(payload);
    final tracks = asList(data['tracks'])
        .map(asMap)
        .where((raw) => asString(raw['src']).isNotEmpty)
        .map(Track.fromCatalogJson)
        .toList();
    AppLog.instance.log(LogLevel.info, 'catalog', 'search "${AppLog.clip(q, 60)}" -> ${tracks.length} playable');
    if (tracks.isNotEmpty) {
      _down = false;
      _lastError = '';
      if (_cache.length > 200) _cache.clear();
      _cache[q.toLowerCase()] = (at: DateTime.now().millisecondsSinceEpoch, tracks: tracks);
      return tracks;
    }
    _lastError = asString(data['error']);
    if (_lastError.isNotEmpty) {
      AppLog.instance.log(LogLevel.warn, 'catalog', 'search "${AppLog.clip(q, 60)}" returned error: ${AppLog.clip(_lastError, 200)}');
      try {
        final status = await node.request('/api/search/status', timeout: const Duration(seconds: 10));
        _down = asBool(asMap(status.data)['unavailable']);
      } catch (_) {
        _down = true;
      }
    } else {
      _down = false;
    }
    return [];
  }

  Future<({List<Track> tracks, bool reliable})> artistTracks(List<String> names) async {
    final aliases = <String>[];
    for (final name in names) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty && !aliases.contains(trimmed)) aliases.add(trimmed);
    }
    final limited = aliases.take(4).toList();
    final keys = limited.map(looseKey).where((k) => k.isNotEmpty).toSet();
    final byId = <String, Track>{};
    var reliable = true;
    for (final alias in limited) {
      List<Track> list;
      try {
        list = await search(alias);
      } catch (_) {
        list = [];
      }
      if (searchStatus.unavailable) reliable = false;
      for (final track in list) {
        if (!track.playable || !artistMatches(track, keys)) continue;
        byId.putIfAbsent(track.id, () => track);
      }
    }
    return (tracks: byId.values.toList(), reliable: reliable);
  }
}

final RegExp _creditSplit = cachedRe(
  r'\s*(?:,|;|/|&|\+|×|\bx\b|\bfeat\.?|\bft\.?|\bfeaturing\b|\bvs\.?|\bи\b)\s*',
  caseSensitive: false,
);

/// Does a catalog track belong to the artist? Credits are written as
/// "A, B", "A & B", "A feat. B" and similar.
bool artistMatches(Track track, Set<String> keys) {
  for (final credit in track.artists) {
    final whole = looseKey(credit);
    if (keys.contains(whole)) return true;
    for (final part in credit.split(_creditSplit)) {
      if (keys.contains(looseKey(part))) return true;
    }
    for (final key in keys) {
      if (key.length >= 7 && whole.contains(key)) return true;
    }
  }
  return false;
}

Track? matchPlayableTrack(
  Iterable<Track> tracks, {
  required String title,
  required String artist,
  String album = '',
}) {
  final wantedTitle = compactKey(title);
  final wantedAlbum = compactKey(album);
  if (wantedTitle.isEmpty || artist.trim().isEmpty) return null;

  Track? best;
  var bestAlbumMatch = false;
  for (final track in tracks) {
    if (!track.playable ||
        compactKey(track.title) != wantedTitle ||
        !track.artists.any((credit) => sameArtist(credit, artist))) {
      continue;
    }
    final albumMatch =
        wantedAlbum.isNotEmpty && compactKey(track.album) == wantedAlbum;
    if (best == null || (albumMatch && !bestAlbumMatch)) {
      best = track;
      bestAlbumMatch = albumMatch;
    }
  }
  return best;
}

String coreTitle(String title) {
  return title
      .replaceAll(cachedRe(r'\([^)]*\)|\[[^\]]*\]'), ' ')
      .replaceAll(cachedRe(r'\b(?:feat|ft|prod|reprod|ft\.|feat\.)\b.*$', caseSensitive: false), ' ')
      .replaceAll(cachedRe(r'\s+'), ' ')
      .trim();
}

const Map<String, String> _leet = {
  '0': 'o',
  '1': 'i',
  '3': 'e',
  '4': 'a',
  '5': 's',
  '7': 't',
  r'$': 's',
  '@': 'a',
};

String deleet(String title) {
  final base = coreTitle(title).toLowerCase();
  final buffer = StringBuffer();
  for (final char in base.split('')) {
    buffer.write(_leet[char] ?? char);
  }
  return buffer
      .toString()
      .replaceAll(cachedRe(r'[*•]'), '')
      .replaceAll(cachedRe(r'\s+'), ' ')
      .trim();
}

String leetKey(String title) =>
    compactKey(deleet(title)).replaceAllMapped(cachedRe(r'(.)\1+'), (m) => m.group(1)!);

String coreKey(String title) => compactKey(coreTitle(title));

/// Returns a function that maps a release/song title to a playable catalog
/// track: exact title first, then the title without "(Remix)"-style tails, then
/// a close spelling (>= 88 %, titles of 6+ letters).
Track? Function(String title) makeMatcher(List<Track> tracks) {
  final full = <String, Track>{};
  final core = <String, Track>{};
  for (final track in tracks) {
    final f = compactKey(track.title);
    final c = coreKey(track.title);
    if (f.isNotEmpty) full.putIfAbsent(f, () => track);
    if (c.isNotEmpty) core.putIfAbsent(c, () => track);
  }
  return (String title) {
    final f = compactKey(title);
    final c = coreKey(title);
    final exact = full[f] ?? full[c] ?? core[c];
    if (exact != null) return exact;
    if (c.length < 6) return null;
    Track? best;
    var bestScore = 0.88;
    for (final entry in core.entries) {
      if ((entry.key.length - c.length).abs() > 3) continue;
      final score = 1 - levenshtein(entry.key, c) / (entry.key.length > c.length ? entry.key.length : c.length);
      if (score >= bestScore) {
        best = entry.value;
        bestScore = score;
      }
    }
    return best;
  };
}

/// Normalizes a title/artist pair for loose comparison in importers.
String compactTitleKey(String value) => compactKey(value);

/// Score used by the importer: 1 exact, 0.92 without "(Remix)" tails, 0.7 for
/// a containment match, and up to 0.8 * 0.86.. for a close spelling.
String importCore(String value) => value
    .replaceAll(cachedRe(r'\([^)]*\)|\[[^\]]*\]'), ' ')
    .replaceAll(cachedRe(r'\b(?:feat|ft)\.?\s.*$', caseSensitive: false), ' ')
    .replaceAll(cachedRe(r'\s[-–—]\s.*(?:remaster|version|edit|mix).*$', caseSensitive: false), ' ')
    .replaceAll(cachedRe(r'\s+'), ' ')
    .trim();

double importTitleScore(String want, String have) {
  final fa = looseKey(want);
  final fb = looseKey(have);
  if (fa.isEmpty || fb.isEmpty) return 0;
  if (fa == fb) return 1;
  final ca = looseKey(importCore(want));
  final cb = looseKey(importCore(have));
  if (ca.isNotEmpty && ca == cb) return 0.92;
  if (ca.length >= 5 && cb.length >= 5 && (cb.contains(ca) || ca.contains(cb))) return 0.7;
  if (ca.length >= 6 && (ca.length - cb.length).abs() <= 3) {
    final score = 1 - levenshtein(ca, cb) / (ca.length > cb.length ? ca.length : cb.length);
    if (score >= 0.86) return score * 0.8;
  }
  return 0;
}

double importArtistScore(String want, List<String> candidateArtists) {
  final splitter = cachedRe(
    r'\s*(?:,|;|&|×|\bfeat\.?|\bft\.?|\bx\b|\band\b|\bи\b)\s*',
    caseSensitive: false,
  );
  final keys = want.split(splitter).map(looseKey).where((s) => s.isNotEmpty).toList();
  if (keys.isEmpty) return 0.5;
  final have = <String>[];
  for (final artist in candidateArtists) {
    final whole = looseKey(artist);
    if (whole.isNotEmpty) have.add(whole);
    for (final part in artist.split(splitter)) {
      final key = looseKey(part);
      if (key.isNotEmpty) have.add(key);
    }
  }
  for (final key in keys) {
    for (final value in have) {
      if (key == value) return 1;
      if (key.length >= 4 && value.length >= 4 && (value.contains(key) || key.contains(value))) return 1;
    }
  }
  return 0;
}

final RegExp _variantRe = cachedRe(
  r'remix|slowed|sped ?up|nightcore|karaoke|instrumental|cover|live|acoustic|8d|bass ?boost|reverb|ремикс|кавер|караоке',
  caseSensitive: false,
);

Track? importPick({required String title, required String artist, required List<Track> candidates}) {
  Track? best;
  var bestScore = 0.0;
  final wantTitle = title;
  final wantArtist = artist;
  for (final candidate in candidates) {
    if (!candidate.playable) continue;
    final artists = candidate.artists;
    var ts = importTitleScore(wantTitle, candidate.title);
    var artistScore = importArtistScore(wantArtist, artists);
    if (wantArtist.isNotEmpty) {
      final ts2 = importTitleScore(wantArtist, candidate.title);
      final as2 = importArtistScore(wantTitle, artists);
      if (ts2 * 2 + as2 > ts * 2 + artistScore && as2 > 0) {
        ts = ts2;
        artistScore = as2;
      }
    }
    if (ts < 0.7 || (wantArtist.isNotEmpty && artistScore < 1)) continue;
    var score = ts * 2 + artistScore;
    if (_variantRe.hasMatch(candidate.title) && !_variantRe.hasMatch(wantTitle)) score -= 0.5;
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best;
}

class ImportSearchCache {
  final Map<String, Track?> _cache = {};
  int _seq = 0;

  Future<Track?> find(CatalogService catalog, PlaylistImportItem item) async {
    final key = '${looseKey(item.artist)}|${looseKey(item.title)}';
    if (_cache.containsKey(key)) return _cache[key];
    final first = item.artist.split(cachedRe(r'\s*(?:,|;|&)\s*')).first.trim();
    final core = importCore(item.title).isNotEmpty ? importCore(item.title) : item.title;
    Track? found;
    for (final query in <String>['$first $core'.trim(), core]) {
      if (found != null || query.isEmpty) continue;
      final list = await catalog.search(query);
      if (list.isEmpty && catalog.searchStatus.unavailable) {
        throw Exception('catalog unavailable');
      }
      found = importPick(title: item.title, artist: item.artist, candidates: list);
    }
    _cache[key] = found;
    _seq++;
    return found;
  }
}
