import 'dart:convert';

import 'models.dart';
import 'utils.dart';

/// Parser for playlist exports from other music services: CSV / TSV
/// (Exportify, TuneMyMusic, Soundiiz, Apple Music, Yandex Music), Spotify
/// account JSON, M3U / M3U8 and plain "Artist - Title" text.
class ImportParser {
  static final RegExp likedRe = cachedRe(
    r'liked|favou?rite|loved|saved tracks|your ?library|избранн|понрав|нравит|любим|мне нравится',
    caseSensitive: false,
  );

  static const Map<String, List<String>> headers = {
    'title': [
      'track name', 'trackname', 'track_name', 'song name', 'songname', 'track title',
      'title', 'track', 'song', 'name', 'название трека', 'название', 'трек', 'песня', 'композиция',
    ],
    'artist': [
      'artist name(s)', 'artist names', 'artist name', 'artistname', 'artist_name', 'artists',
      'artist', 'performer', 'author', 'исполнитель', 'исполнители', 'артист', 'артисты', 'автор',
    ],
    'album': ['album name', 'albumname', 'album_name', 'album', 'альбом'],
    'playlist': ['playlist name', 'playlistname', 'playlist', 'плейлист'],
    'type': ['type', 'тип'],
  };

  static String clean(Object? value) =>
      (value ?? '').toString().replaceAll(cachedRe(r'\s+'), ' ').trim();

  static String fold(Object? value) => clean(value).toLowerCase();

  static String baseName(String? fileName) {
    var name = clean((fileName ?? '').split(cachedRe(r'[\\/]')).last);
    name = name.replaceFirst(cachedRe(r'\.[a-z0-9]{1,6}$', caseSensitive: false), '');
    return name.isEmpty ? 'Imported playlist' : name;
  }

  static List<PlaylistImportList> parse(String text, [String fileName = '']) {
    final source = text.replaceFirst('\ufeff', '');
    final trimmed = source.trimLeft();
    List<PlaylistImportList> lists;
    if (cachedRe(r'\.json$', caseSensitive: false).hasMatch(fileName) ||
        trimmed.startsWith('{') ||
        trimmed.startsWith('[')) {
      lists = _fromJson(source, fileName);
    } else if (cachedRe(r'\.(csv|tsv)$', caseSensitive: false).hasMatch(fileName)) {
      lists = _fromCsv(source, fileName);
    } else if (cachedRe(r'\.(m3u8?|txt)$', caseSensitive: false).hasMatch(fileName) || fileName.isEmpty) {
      final firstLine = source.split(cachedRe(r'\r?\n')).first;
      final csv = cachedRe(r'[,;\t]').hasMatch(firstLine) ? _fromCsv(source, fileName) : <PlaylistImportList>[];
      lists = csv.isNotEmpty ? csv : _fromText(source, fileName);
    } else {
      final csv = _fromCsv(source, fileName);
      lists = csv.isNotEmpty ? csv : _fromText(source, fileName);
    }

    final result = <PlaylistImportList>[];
    for (final list in lists) {
      final seen = <String>{};
      final items = <PlaylistImportItem>[];
      for (final item in list.items) {
        final key = '${fold(item.artist)}|${fold(item.title)}';
        if (item.title.trim().isEmpty || seen.contains(key)) continue;
        seen.add(key);
        items.add(item);
      }
      if (items.isEmpty) continue;
      final kind = likedRe.hasMatch(list.name) || (likedRe.hasMatch(baseName(fileName)) && lists.length == 1)
          ? 'liked'
          : 'playlist';
      result.add(PlaylistImportList(name: list.name, kind: kind, items: items));
    }
    return result;
  }

  // ------------------------------------------------------------------ CSV

  static String _detectDelimiter(String head) {
    final line = head.split(cachedRe(r'\r?\n')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    var best = ',';
    var bestCount = 0;
    for (final delimiter in [',', ';', '\t']) {
      final count = line.split(delimiter).length - 1;
      if (count > bestCount) {
        best = delimiter;
        bestCount = count;
      }
    }
    return best;
  }

  static List<List<String>> parseCsv(String text) {
    final delimiter = _detectDelimiter(text.length > 4000 ? text.substring(0, 4000) : text);
    final rows = <List<String>>[];
    var row = <String>[];
    var cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (quoted) {
        if (char == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(char);
        }
      } else if (char == '"') {
        quoted = true;
      } else if (char == delimiter) {
        row.add(cell.toString());
        cell.clear();
      } else if (char == '\n' || char == '\r') {
        if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(cell.toString());
        cell.clear();
        if (row.any((value) => value.isNotEmpty)) rows.add(row);
        row = <String>[];
      } else {
        cell.write(char);
      }
    }
    row.add(cell.toString());
    if (row.any((value) => value.isNotEmpty)) rows.add(row);
    return rows;
  }

  static int _pickColumn(List<String> header, List<String> names) {
    for (final name in names) {
      final index = header.indexOf(name);
      if (index >= 0) return index;
    }
    return -1;
  }

  static List<PlaylistImportList> _fromCsv(String text, String fileName) {
    final rows = parseCsv(text);
    if (rows.length < 2) return [];
    final header = rows.first
        .map((value) => fold(value).replaceFirst(cachedRe(r'^\ufeff'), ''))
        .toList();
    final titleIndex = _pickColumn(header, headers['title']!);
    final artistIndex = _pickColumn(header, headers['artist']!);
    if (titleIndex < 0) return [];
    final albumIndex = _pickColumn(header, headers['album']!);
    final playlistIndex = _pickColumn(header, headers['playlist']!);
    final typeIndex = _pickColumn(header, headers['type']!);
    final groups = <String, List<PlaylistImportItem>>{};
    for (final row in rows.skip(1)) {
      final title = clean(titleIndex < row.length ? row[titleIndex] : '');
      if (title.isEmpty) continue;
      final artist = artistIndex >= 0 && artistIndex < row.length
          ? clean(row[artistIndex].replaceAll(cachedRe(r'\s*;\s*'), ', '))
          : '';
      final type = typeIndex >= 0 && typeIndex < row.length ? fold(row[typeIndex]) : '';
      var name = playlistIndex >= 0 && playlistIndex < row.length ? clean(row[playlistIndex]) : '';
      if (name.isEmpty) name = type.isNotEmpty && likedRe.hasMatch(type) ? 'Liked Songs' : baseName(fileName);
      if (type.isNotEmpty && likedRe.hasMatch(type) && name.isEmpty) name = 'Liked Songs';
      groups.putIfAbsent(name, () => []).add(PlaylistImportItem(
            title: title,
            artist: artist,
            album: albumIndex >= 0 && albumIndex < row.length ? clean(row[albumIndex]) : '',
          ));
    }
    return groups.entries
        .map((entry) => PlaylistImportList(name: entry.key, kind: 'playlist', items: entry.value))
        .toList();
  }

  // ------------------------------------------------------------------ JSON

  static String _artistOf(Map object) {
    dynamic value = object['artistName'] ??
        object['artist_name'] ??
        object['artists'] ??
        object['artist'] ??
        object['author'] ??
        object['performer'] ??
        object['grandparentTitle'];
    if (value == null) return '';
    if (value is String) return clean(value);
    if (value is List) {
      return clean(value
          .map((item) => item is String ? item : asMap(item)['name'] ?? asMap(item)['title'])
          .where((item) => item != null)
          .join(', '));
    }
    final map = asMap(value);
    return clean(map['name'] ?? map['title']);
  }

  static PlaylistImportItem? _toItem(dynamic node) {
    if (node is! Map) return null;
    final object = asMap(node);
    if (object['track'] is Map) {
      final nested = _toItem(object['track']);
      if (nested != null) return nested;
    }
    if (object['item'] is Map) {
      final nested = _toItem(object['item']);
      if (nested != null) return nested;
    }
    final artist = _artistOf(object);
    if (artist.isEmpty) return null;
    dynamic title = object['trackName'] ??
        object['track_name'] ??
        object['songName'] ??
        (object['track'] is String ? object['track'] : null) ??
        object['title'] ??
        object['song'] ??
        object['name'];
    if (title is Map) title = title['name'] ?? title['title'];
    title = clean(title);
    if (title.isEmpty) return null;
    dynamic album = object['albumName'] ?? object['album_name'] ?? object['album'];
    if (album is Map) album = album['name'] ?? album['title'];
    return PlaylistImportItem(title: title.toString(), artist: artist, album: clean(album));
  }

  static List<PlaylistImportList> _fromJson(String text, String fileName) {
    dynamic data;
    try {
      data = jsonDecode(text.replaceFirst('\ufeff', ''));
    } catch (_) {
      return [];
    }
    final found = <String, List<PlaylistImportItem>>{};
    final base = baseName(fileName);

    void walk(dynamic node, String name, int depth) {
      if (depth > 7 || node == null) return;
      if (node is List) {
        final items = node.map(_toItem).whereType<PlaylistImportItem>().toList();
        if (items.isNotEmpty && items.length >= node.length / 2) {
          found.putIfAbsent(name, () => []).addAll(items);
          return;
        }
        for (final child in node) {
          walk(child, name, depth + 1);
        }
        return;
      }
      if (node is! Map) return;
      final single = _toItem(node);
      if (single != null) {
        found.putIfAbsent(name, () => []).add(single);
        return;
      }
      final object = asMap(node);
      final own = clean(object['name'] ??
          object['playlistName'] ??
          object['playlist_name'] ??
          (object['title'] is String ? object['title'] : ''));
      final nextName = own.isEmpty ? name : own;
      for (final entry in object.entries) {
        if (entry.value is Map || entry.value is List) {
          walk(entry.value, nextName, depth + 1);
        }
      }
    }

    walk(data, base, 0);
    var out = found.entries
        .map((entry) => PlaylistImportList(name: entry.key, kind: 'playlist', items: entry.value))
        .toList();
    if (cachedRe(r'yourlibrary', caseSensitive: false).hasMatch(fileName) && out.isNotEmpty) {
      out = out.map((list) => PlaylistImportList(name: 'Liked Songs', kind: 'liked', items: list.items)).toList();
    }
    return out;
  }

  // ------------------------------------------------------------------ text

  static ({String artist, String title}) splitArtistTitle(String line) {
    var value = clean(line);
    value = value.replaceFirst(cachedRe(r'^\s*(?:\d{1,4}\s*[.)\]]|[-*•]|#\d+)\s+'), '');
    var match = cachedRe(r'^(.+?)\s+[-–—−]\s+(.+)$').firstMatch(value);
    match ??= cachedRe(r'^(.+?)\s*[–—]\s*(.+)$').firstMatch(value);
    if (match != null) {
      return (artist: clean(match.group(1)), title: clean(match.group(2)));
    }
    return (artist: '', title: value);
  }

  static List<PlaylistImportList> _fromText(String text, String fileName) {
    final lines = text.replaceFirst('\ufeff', '').split(cachedRe(r'\r?\n'));
    final items = <PlaylistImportItem>[];
    final isM3u = lines.isNotEmpty && cachedRe(r'^#EXTM3U', caseSensitive: false).hasMatch(lines.first) ||
        lines.any((line) => cachedRe(r'^#EXTINF', caseSensitive: false).hasMatch(line));
    if (isM3u) {
      for (final line in lines) {
        final match = cachedRe(r'^#EXTINF:[^,]*,(.*)$', caseSensitive: false).firstMatch(line);
        if (match == null) continue;
        final split = splitArtistTitle(match.group(1) ?? '');
        if (split.title.isNotEmpty) {
          items.add(PlaylistImportItem(title: split.title, artist: split.artist));
        }
      }
      if (items.isEmpty) {
        for (final line in lines) {
          if (line.trim().isEmpty || line.startsWith('#')) continue;
          final file = line.split(cachedRe(r'[\\/]')).last.replaceFirst(cachedRe(r'\.[a-z0-9]{2,5}$', caseSensitive: false), '');
          final split = splitArtistTitle(file);
          if (split.title.isNotEmpty) {
            items.add(PlaylistImportItem(title: split.title, artist: split.artist));
          }
        }
      }
    } else {
      for (final line in lines) {
        if (clean(line).isEmpty || cachedRe(r'^\s*(#|//)').hasMatch(line)) continue;
        final split = splitArtistTitle(line);
        if (split.title.isNotEmpty && split.title.length < 220) {
          items.add(PlaylistImportItem(title: split.title, artist: split.artist));
        }
      }
    }
    return items.isEmpty ? [] : [PlaylistImportList(name: baseName(fileName), kind: 'playlist', items: items)];
  }
}
