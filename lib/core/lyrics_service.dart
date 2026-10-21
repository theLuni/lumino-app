import 'app_log.dart';
import 'models.dart';
import 'node_service.dart';

class LyricsService {
  LyricsService(this.node);
  final NodeService node;

  /// Accepts a numeric timestamp in whatever shape the node sends it
  /// (`num`, a numeric string, or occasionally `null`) so a synced variant
  /// doesn't silently lose its timing just because a value arrived as text.
  static double? _asSeconds(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  /// Synced and plain lyrics come from the Lumino node (lrclib lookup, aliases
  /// and retries happen server-side).
  Future<LyricsResult> getLyrics(Track track) async {
    final artist = track.artists.isNotEmpty ? track.artists.first : '';
    if (artist.trim().isEmpty || track.title.trim().isEmpty) {
      return LyricsResult();
    }
    try {
      final result = await node.request(
        '/api/lyrics',
        params: {
          'artist': artist,
          'title': track.title,
          'artists': track.artists.join(','),
          'album': track.album,
          'duration': track.duration,
        },
        timeout: const Duration(seconds: 30),
      );
      final data = asMap(result.data);
      final variants = <LyricVariant>[];
      for (final raw in asList(data['variants'])) {
        final variant = asMap(raw);
        final lines = <LyricLine>[];
        for (final rawLine in asList(variant['lines'])) {
          final line = asMap(rawLine);
          lines.add(LyricLine(
            t: _asSeconds(line['t']),
            text: asString(line['text']),
          ));
        }
        variants.add(LyricVariant(
          label: asString(variant['label']),
          synced: asBool(variant['synced']),
          lines: lines,
        ));
      }
      if (result.status == 200) {
        return LyricsResult(variants: variants, failed: asBool(data['failed']));
      }
      AppLog.instance.log(LogLevel.info, 'lyrics', 'no lyrics for "${AppLog.clip(track.title, 60)}" (HTTP ${result.status})');
      return LyricsResult(variants: const [], failed: result.status >= 500);
    } catch (error, stack) {
      AppLog.instance.log(LogLevel.warn, 'lyrics', 'request failed for "${AppLog.clip(track.title, 60)}"', error: error, stack: stack);
      return LyricsResult(failed: true);
    }
  }

  /// Similar artists are served by the node (Deezer related artists, cached
  /// there), exactly like in the Electron build.
  Future<Map<String, List<String>>> similarArtists(List<String> names) async {
    final unique = <String>[];
    for (final name in names) {
      final trimmed = name.trim();
      if (trimmed.isNotEmpty && !unique.contains(trimmed)) unique.add(trimmed);
      if (unique.length >= 8) break;
    }
    final out = <String, List<String>>{for (final name in unique) name: []};
    if (unique.isEmpty) return out;
    try {
      final result = await node.request(
        '/api/similar',
        params: {'names': unique.join('|')},
        timeout: const Duration(seconds: 30),
      );
      final data = asMap(result.data);
      for (final name in unique) {
        out[name] = asList(data[name]).map((v) => v.toString()).toList();
      }
    } catch (error) {
      // Offline: no recommendations.
      AppLog.instance.log(LogLevel.warn, 'lyrics', 'similar artists request failed', error: error);
    }
    return out;
  }
}
