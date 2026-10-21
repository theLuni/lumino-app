import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'app_log.dart';
import 'catalog_service.dart';
import 'models.dart';
import 'node_service.dart';
import 'utils.dart';

/// Artwork and artist metadata from Deezer and Apple Music.
class MetaService {
  MetaService(this._client, {this.node});

  final http.Client _client;

  /// Обложки идут через сервер Lumino (/api/cover), а не напрямую к Deezer/iTunes.
  final NodeService? node;
  static const String _ua = 'Lumino/0.3 (desktop music player)';

  final Map<String, Future<ArtistInfo>> _artistCache = {};
  final Map<String, Future<String>> _avatarCache = {};
  final Map<String, Future<ReleaseIndex>> _releaseCache = {};
  final Map<String, Future<Release?>> _releaseForTrackCache = {};
  final Map<String, Future<Release>> _albumCache = {};
  final Map<String, Future<({String genre, List<String> artists})?>>
      _genreRecommendations = {};
  final Map<String, ({int at, String cover})> _coverCache = {};
  final Map<String, Future<int?>> _colorCache = {};

  Future<http.Response> _get(String url,
      {Duration timeout = const Duration(seconds: 12)}) async {
    final sw = Stopwatch()..start();
    final target = AppLog.shortUrl(url);
    try {
      final response = await _client.get(Uri.parse(url), headers: {
        'User-Agent': _ua,
        'Accept': 'application/json,text/plain,*/*',
      }).timeout(timeout);
      AppLog.instance.log(LogLevel.debug, 'meta',
          'GET $target ${response.statusCode} ${sw.elapsedMilliseconds}ms');
      return response;
    } catch (error) {
      AppLog.instance.log(LogLevel.warn, 'meta',
          'GET $target failed after ${sw.elapsedMilliseconds}ms',
          error: error);
      rethrow;
    }
  }

  dynamic _json(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- artwork

  final Map<String, Future<String>> _coverInFlight = {};

  Future<String> coverFor({
    required String title,
    required List<String> artists,
    String album = '',
  }) {
    final key =
        '${looseKey(artists.join(','))}|${looseKey(title)}|${looseKey(album)}';
    final hit = _coverCache[key];
    if (hit != null &&
        DateTime.now().millisecondsSinceEpoch - hit.at < 12 * 3600 * 1000) {
      return Future.value(hit.cover);
    }
    // Одна и та же обложка может запрашиваться из нескольких списков сразу: делаем один запрос.
    return _coverInFlight.putIfAbsent(key, () async {
      try {
        final cover =
            await _serverCover(title: title, artists: artists, album: album);
        if (cover.isNotEmpty) {
          _coverCache[key] =
              (at: DateTime.now().millisecondsSinceEpoch, cover: cover);
        }
        return cover;
      } finally {
        _coverInFlight.remove(key);
      }
    });
  }

  Future<String> _serverCover({
    required String title,
    required List<String> artists,
    required String album,
  }) async {
    final svc = node;
    if (svc == null) return '';
    final result = await svc.request(
      '/api/cover',
      params: {
        'artist': artists.isNotEmpty ? artists.first : '',
        'title': title,
        'album': album,
      },
      timeout: const Duration(seconds: 20),
    );
    final path = asString(asMap(result.data)['cover']);
    if (path.isEmpty) return '';
    return path.startsWith('http') ? path : '${svc.base}$path';
  }

  // ---------------------------------------------------------------- artists

  Future<ArtistInfo> getArtist(String name) {
    final key = norm(name);
    return _artistCache.putIfAbsent(key, () => _loadArtist(name));
  }

  Future<ArtistInfo> _loadArtist(String name) async {
    var deezer = ArtistInfo.empty(name);
    var apple = ArtistInfo.empty(name);
    try {
      deezer = await _deezerArtist(name);
    } catch (_) {}
    try {
      apple = await _itunesArtist(name);
    } catch (_) {}
    final info = ArtistInfo(
      name: deezer.name.isNotEmpty ? deezer.name : name,
      avatar: _viaServer(apple.avatar),
      banner: _viaServer(apple.banner),
      bio: deezer.bio,
      followers: deezer.followers,
      verified: deezer.verified,
      url: deezer.url.isNotEmpty ? deezer.url : apple.url,
    );
    if (info.avatar.isEmpty && info.banner.isEmpty) {
      // Empty metadata is not cached forever: a later view may succeed.
      Timer(const Duration(seconds: 50), () => _artistCache.remove(norm(name)));
    }
    return info;
  }

  /// Apple Music artwork is the only source used for artist avatars.
  Future<ArtistInfo> _itunesArtist(String name) async {
    try {
      final response = await _get(
        'https://itunes.apple.com/search?entity=musicArtist&limit=10&term=${Uri.encodeQueryComponent(name)}',
        timeout: const Duration(seconds: 9),
      );
      if (response.statusCode != 200) return ArtistInfo.empty(name);
      Map<String, dynamic>? hit;
      for (final raw in asList(asMap(_json(response))['results'])) {
        final item = asMap(raw);
        final candidate = asString(item['artistName']);
        if (norm(candidate) == norm(name) ||
            looseKey(candidate) == looseKey(name)) {
          hit = item.map((k, v) => MapEntry(k.toString(), v));
          break;
        }
      }
      if (hit == null) return ArtistInfo.empty(name);
      final id = asInt(hit['artistId']);
      final appleLink = asString(hit['artistLinkUrl'])
          .replaceFirst('itunes.apple.com', 'music.apple.com');
      final artistUrl = appleLink.isNotEmpty
          ? appleLink
          : id > 0
              ? 'https://music.apple.com/us/artist/${Uri.encodeComponent(asString(hit['artistName']))}/$id'
              : '';
      var artwork = '';
      if (artistUrl.isNotEmpty) {
        final page = await _get(
          artistUrl,
          timeout: const Duration(seconds: 10),
        );
        if (page.statusCode == 200) {
          final ldJson = RegExp(
            r'<script[^>]*type="application/ld\+json"[^>]*>(.*?)</script>',
            caseSensitive: false,
            dotAll: true,
          ).firstMatch(page.body);
          if (ldJson != null) {
            try {
              final data = jsonDecode(ldJson.group(1)!);
              final image = data is Map ? asString(data['image']) : '';
              if (image.startsWith('https://')) artwork = image;
            } on FormatException {
              AppLog.instance.log(
                  LogLevel.warn, 'meta', 'Apple artist metadata was malformed');
            }
          }
        }
      }
      return ArtistInfo(
        name: asString(hit['artistName']),
        avatar: artwork,
        banner: artwork,
        url: _https(artistUrl),
      );
    } catch (_) {
      return ArtistInfo.empty(name);
    }
  }

  Future<ArtistInfo> _deezerArtist(String name) async {
    final hit = await _deezerArtistHit(name);
    if (hit == null) return ArtistInfo.empty(name);
    return ArtistInfo(
      name: asString(hit['name']),
      followers: asInt(hit['nb_fan']),
      url: _https(asString(hit['link'])),
    );
  }

  Future<Map<String, dynamic>?> _deezerArtistHit(String name) async {
    try {
      final knownIds = _knownDeezerArtistIds(name);
      if (knownIds.isNotEmpty) {
        final response = await _get(
          'https://api.deezer.com/artist/${knownIds.first}',
          timeout: const Duration(seconds: 9),
        );
        if (response.statusCode != 200) return null;
        return asMap(_json(response));
      }
      final response = await _get(
        'https://api.deezer.com/search/artist?q=${Uri.encodeQueryComponent(name)}&limit=10',
        timeout: const Duration(seconds: 9),
      );
      if (response.statusCode != 200) return null;
      final list = asList(asMap(_json(response))['data']);
      Map? best;
      var bestScore = 0.0;
      for (final raw in list) {
        final item = asMap(raw);
        final candidate = asString(item['name']);
        var score = 0.0;
        if (norm(candidate) == norm(name)) {
          score = 3;
        } else if (looseKey(candidate) == looseKey(name)) {
          score = 2.5;
        } else if (looseKey(candidate).contains(looseKey(name)) ||
            looseKey(name).contains(looseKey(candidate))) {
          score = 1;
        }
        if (score > bestScore) {
          bestScore = score;
          best = item;
        }
      }
      if (best == null || bestScore < 1) return null;
      return best.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  Future<int> deezerArtistId(String name) async {
    final hit = await _deezerArtistHit(name);
    return hit == null ? 0 : asInt(hit['id']);
  }

  List<int> _knownDeezerArtistIds(String name) {
    final key = norm(name);
    if (key == norm('урал гайсин') || key == norm('ural gaysin')) {
      return [245170922];
    }
    if (key == norm('юпи')) return [110652182, 268532872];
    return const [];
  }

  Future<String> getAvatar(String name) {
    final key = norm(name);
    return _avatarCache.putIfAbsent(
        key, () async => _viaServer((await _itunesArtist(name)).avatar));
  }

  Future<({String genre, List<String> artists})?> genreArtistsForTrack(
      Track track) {
    final future = _genreRecommendations.putIfAbsent(track.key, () async {
      try {
        final query =
            Uri.encodeQueryComponent('${track.primary} ${track.title}'.trim());
        final search = await _get(
          'https://api.deezer.com/search/track?q=$query&limit=12',
          timeout: const Duration(seconds: 10),
        );
        if (search.statusCode != 200) return null;
        final wantTitle = looseKey(track.title);
        final wantArtists = track.artists.map(looseKey).toSet();
        final match = asList(asMap(_json(search))['data'])
            .map(asMap)
            .where((item) => looseKey(asString(item['title'])) == wantTitle)
            .where((item) => wantArtists
                .contains(looseKey(asString(asMap(item['artist'])['name']))))
            .firstOrNull;
        if (match == null) return null;
        final albumId = asInt(asMap(match['album'])['id']);
        if (albumId <= 0) return null;
        final albumResponse = await _get(
          'https://api.deezer.com/album/$albumId',
          timeout: const Duration(seconds: 10),
        );
        if (albumResponse.statusCode != 200) return null;
        final album = asMap(_json(albumResponse));
        final genres = asList(asMap(album['genres'])['data'])
            .map(asMap)
            .where((genre) => asInt(genre['id']) > 0)
            .toList();
        if (genres.isEmpty) return null;
        for (final genre in genres.take(2)) {
          final genreId = asInt(genre['id']);
          final response = await _get(
            'https://api.deezer.com/genre/$genreId/artists?limit=30',
            timeout: const Duration(seconds: 10),
          );
          if (response.statusCode != 200) continue;
          final names = <String>[];
          final seen = <String>{};
          for (final raw in asList(asMap(_json(response))['data'])) {
            final name = asString(asMap(raw)['name']).trim();
            final key = norm(name);
            if (name.isNotEmpty && seen.add(key)) names.add(name);
          }
          if (names.isNotEmpty) {
            return (
              genre: asString(genre['name']),
              artists: names,
            );
          }
        }
      } catch (error, stack) {
        AppLog.instance.log(
          LogLevel.warn,
          'meta',
          'genre recommendations failed for "${AppLog.clip(track.title, 60)}"',
          error: error,
          stack: stack,
        );
      }
      return null;
    });
    return future.then((result) {
      if (result == null) _genreRecommendations.remove(track.key);
      return result;
    });
  }

  // ---------------------------------------------------------------- releases

  Future<ReleaseIndex> getArtistReleaseIndex(String name) {
    final key = norm(name);
    return _releaseCache.putIfAbsent(key, () async {
      final ids = _knownDeezerArtistIds(name);
      final artistIds = ids.isNotEmpty ? ids : [await deezerArtistId(name)];
      if (artistIds.every((id) => id <= 0)) return ReleaseIndex();
      final releases = <Release>[];
      final allowedTypes = {'album', 'ep', 'single'};
      for (final id in artistIds.where((id) => id > 0)) {
        for (var index = 0; index < 5; index++) {
          final response = await _get(
            'https://api.deezer.com/artist/$id/albums?limit=100&index=${index * 100}',
            timeout: const Duration(seconds: 12),
          );
          if (response.statusCode != 200) break;
          final data = asMap(_json(response));
          final items = asList(data['data']);
          for (final raw in items) {
            final item = asMap(raw);
            var type = asString(item['record_type']);
            if (type == 'compile') type = 'album';
            if (!allowedTypes.contains(type)) continue;
            final cover = _viaServer(_https(
                asString(item['cover_xl']).isNotEmpty
                    ? asString(item['cover_xl'])
                    : asString(item['cover_big'])));
            final date = asString(item['release_date']);
            releases.add(Release(
              name: asString(item['title']),
              artistName: name,
              cover: cover,
              type: type,
              year: date.length >= 4 ? date.substring(0, 4) : '',
              deezerId: asString(item['id']),
              trackCount: asInt(item['nb_tracks']),
            ));
          }
          if (items.length < 100) break;
        }
      }
      final songs = <ReleaseSong>[];
      for (final id in artistIds.where((id) => id > 0)) {
        try {
          final topResponse = await _get(
              'https://api.deezer.com/artist/$id/top?limit=30',
              timeout: const Duration(seconds: 12));
          if (topResponse.statusCode == 200) {
            for (final raw in asList(asMap(_json(topResponse))['data'])) {
              final item = asMap(raw);
              songs.add(ReleaseSong(
                title: asString(item['title']),
                artist: name,
                album: asString(asMap(item['album'])['title']),
                cover: _viaServer(
                    _https(asString(asMap(item['album'])['cover_xl']))),
                duration: asInt(item['duration']),
              ));
            }
          }
        } catch (_) {}
      }
      if (releases.isEmpty && songs.isEmpty) {
        Timer(const Duration(seconds: 60), () => _releaseCache.remove(key));
      }
      return ReleaseIndex(releases: releases, songs: songs);
    });
  }

  /// Loads a release's tracklist from Deezer and returns an enriched copy.
  Future<Release> fillRelease(Release release) {
    if (release.tracks.isNotEmpty || release.deezerId.isEmpty) {
      return Future.value(release);
    }
    return _albumCache.putIfAbsent(release.deezerId, () async {
      var filled = release;
      try {
        final albumResponse = await _get(
            'https://api.deezer.com/album/${release.deezerId}',
            timeout: const Duration(seconds: 12));
        if (albumResponse.statusCode == 200) {
          final album = asMap(_json(albumResponse));
          final artistName = asString(asMap(album['artist'])['name']);
          final type = asString(album['record_type']);
          final date = asString(album['release_date']);
          final cover = _viaServer(_https(asString(album['cover_xl']).isNotEmpty
              ? asString(album['cover_xl'])
              : release.cover));
          final tracks = <ReleaseSong>[];
          for (final raw in asList(asMap(album['tracks'])['data'])) {
            final item = asMap(raw);
            final trackArtist =
                asString(asMap(item['artist'])['name']).isNotEmpty
                    ? asString(asMap(item['artist'])['name'])
                    : artistName;
            final title = canonicalTrackTitle(
              trackArtist,
              asString(item['title']).trim(),
              album: asString(album['title']),
            );
            if (title.isEmpty) continue;
            tracks.add(ReleaseSong(
              title: title,
              artist: trackArtist,
              album: asString(album['title']),
              cover: cover,
              duration: asInt(item['duration']),
              number: asInt(item['track_position']),
            ));
          }
          filled = Release(
            name: asString(album['title']).isNotEmpty
                ? asString(album['title'])
                : release.name,
            artistName: artistName.isNotEmpty ? artistName : release.artistName,
            cover: cover,
            type: type.isNotEmpty ? type : release.type,
            year: date.length >= 4 ? date.substring(0, 4) : release.year,
            tracks: tracks,
            deezerId: release.deezerId,
            trackCount: asInt(album['nb_tracks']),
          );
        }
      } catch (_) {}
      try {
        final completeTracks = <ReleaseSong>[];
        final seen = <String>{};
        for (var page = 0; page < 20; page++) {
          final tracksResponse = await _get(
            'https://api.deezer.com/album/${release.deezerId}/tracks?limit=100&index=${page * 100}',
            timeout: const Duration(seconds: 12),
          );
          if (tracksResponse.statusCode != 200) break;
          final items = asList(asMap(_json(tracksResponse))['data']);
          for (final raw in items) {
            final item = asMap(raw);
            final artist = asString(asMap(item['artist'])['name']).isNotEmpty
                ? asString(asMap(item['artist'])['name'])
                : filled.artistName;
            final title = canonicalTrackTitle(
              artist,
              asString(item['title']).trim(),
              album: filled.name,
            );
            if (title.isEmpty || !seen.add('${norm(title)}|${norm(artist)}')) {
              continue;
            }
            completeTracks.add(ReleaseSong(
              title: title,
              artist: artist,
              album: filled.name,
              cover: filled.cover,
              duration: asInt(item['duration']),
              number: asInt(item['track_position']),
            ));
          }
          if (items.length < 100) break;
        }
        if (completeTracks.isNotEmpty) {
          filled = filled.copyWith(
            tracks: completeTracks,
            trackCount: math.max(filled.trackCount, completeTracks.length),
          );
        }
      } catch (_) {
        // Keep the embedded album track page when pagination is unavailable.
      }
      return filled;
    });
  }

  Future<Release?> releaseForTrack(String title, List<String> artists) {
    final key = '${looseKey(artists.join(','))}|${looseKey(title)}';
    return _releaseForTrackCache.putIfAbsent(key, () async {
      try {
        final query = Uri.encodeQueryComponent(
            '${artists.isNotEmpty ? artists.first : ''} $title'.trim());
        final response = await _get(
            'https://api.deezer.com/search/track?q=$query&limit=10',
            timeout: const Duration(seconds: 9));
        if (response.statusCode != 200) return null;
        Map? best;
        var bestScore = 0.0;
        for (final raw in asList(asMap(_json(response))['data'])) {
          final item = asMap(raw);
          final ts = importTitleScore(title, asString(item['title']));
          if (ts < 0.8) continue;
          final artistName = asString(asMap(item['artist'])['name']);
          final score = ts * 2 +
              importArtistScore(
                  artists.isNotEmpty ? artists.first : '', [artistName]);
          if (score > bestScore) {
            bestScore = score;
            best = item;
          }
        }
        if (best == null || bestScore < 2.1) return null;
        final album = asMap(best['album']);
        final id = asString(album['id']);
        if (id.isEmpty) return null;
        return Release(
          name: asString(album['title']),
          artistName: artists.isNotEmpty ? artists.first : '',
          cover: _viaServer(_https(asString(album['cover_xl']))),
          type: 'album',
          deezerId: id,
        );
      } catch (_) {
        return null;
      }
    });
  }

  /// Dominant colour of a cover/portrait, used for the ambient tint.
  Future<int?> dominantColor(String url) {
    if (url.isEmpty) return Future.value(null);
    return _colorCache.putIfAbsent(url, () async {
      try {
        final uri = Uri.tryParse(url);
        final bytes = uri?.data != null
            ? uri!.data!.contentAsBytes()
            : await _fetchColorImage(url);
        if (bytes == null) return null;
        return await Isolate.run(() => _dominantColorOf(bytes));
      } catch (_) {
        return null;
      }
    });
  }

  Future<Uint8List?> _fetchColorImage(String url) async {
    final response = await _client
        .get(Uri.parse(url), headers: {'User-Agent': _ua}).timeout(
      const Duration(seconds: 9),
    );
    if (response.statusCode != 200) {
      AppLog.instance.log(LogLevel.debug, 'meta',
          'colour: HTTP ${response.statusCode} for ${AppLog.shortUrl(url)}');
      return null;
    }
    return response.bodyBytes;
  }

  void clearMemory() {
    _artistCache.clear();
    _avatarCache.clear();
    _releaseCache.clear();
    _releaseForTrackCache.clear();
    _albumCache.clear();
    _genreRecommendations.clear();
    _coverCache.clear();
    _colorCache.clear();
  }

  /// Deezer and Apple images are fetched through Lumino's image proxy.
  String _viaServer(String url) {
    final svc = node;
    if (svc == null || url.isEmpty) return url;
    final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
    if (host == 'mzstatic.com' || host.endsWith('.mzstatic.com')) return url;
    if (!(host.endsWith('dzcdn.net') ||
        host.endsWith('deezer.com') ||
        host.endsWith('apple.com'))) {
      return url;
    }
    return '${svc.base}/api/image?url=${Uri.encodeQueryComponent(url)}';
  }

  static String _https(String url) {
    if (url.startsWith('//')) return 'https:$url';
    return url;
  }
}

/// Samples the dominant colour of an image. Runs in a background isolate because
/// decoding a full-size cover on the UI thread drops frames.
int? _dominantColorOf(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final small = img.copyResize(decoded, width: 24, height: 24);
  var sumR = 0.0, sumG = 0.0, sumB = 0.0, count = 0.0;
  final buckets = List.generate(12, (_) => [0.0, 0.0, 0.0, 0.0]);
  for (final pixel in small) {
    final r = pixel.r.toDouble(),
        g = pixel.g.toDouble(),
        b = pixel.b.toDouble();
    sumR += r;
    sumG += g;
    sumB += b;
    count++;
    final maxV = math.max(r, math.max(g, b));
    final minV = math.min(r, math.min(g, b));
    final delta = maxV - minV;
    if (delta == 0) continue;
    final lightness = (maxV + minV) / 510;
    final saturation = delta / (255 - (maxV + minV - 255).abs() + 1);
    double hue;
    if (maxV == r) {
      hue = (g - b) / delta + (g < b ? 6 : 0);
    } else if (maxV == g) {
      hue = (b - r) / delta + 2;
    } else {
      hue = (r - g) / delta + 4;
    }
    final bucket = (((hue * 60) % 360) / 30).floor();
    final weight = saturation *
        (1 - (lightness - 0.5).abs() * 1.6) *
        math.max(0.1, 1 - (lightness - 0.5).abs());
    if (weight <= 0.02) continue;
    final entry = buckets[clampInt(bucket, 0, 11)];
    entry[0] += weight;
    entry[1] += r * weight;
    entry[2] += g * weight;
    entry[3] += b * weight;
  }
  buckets.sort((a, b) => b[0].compareTo(a[0]));
  final best = buckets.first;
  double r, g, b;
  if (best[0] > 0.8) {
    r = best[1] / best[0];
    g = best[2] / best[0];
    b = best[3] / best[0];
  } else {
    r = sumR / math.max(1, count);
    g = sumG / math.max(1, count);
    b = sumB / math.max(1, count);
  }
  int channel(double v) => v.round().clamp(0, 255).toInt();
  return (channel(r) << 16) | (channel(g) << 8) | channel(b);
}
