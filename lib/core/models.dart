import 'utils.dart';

Map<String, dynamic> asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return <String, dynamic>{};
}

List<dynamic> asList(Object? value) => value is List ? value : const [];

String asString(Object? value) => value == null ? '' : value.toString();

int asInt(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool asBool(Object? value) => value == true || value == 'true' || value == 1;

bool hasExplicitLyrics(String text) {
  return RegExp(
    r'(?<![A-Za-zА-Яа-яЁё])(?:fuck\w*|shit\w*|bitch\w*|motherfucker\w*|'
    r'хуй\w*|пизд\w*|бляд\w*|еба\w*|ебу\w*|ёб\w*|сука\w*)(?![A-Za-zА-Яа-яЁё])',
    caseSensitive: false,
  ).hasMatch(text);
}

String clipText(String value, int max) =>
    value.length > max ? value.substring(0, max) : value;

class Track {
  Track({
    required this.id,
    required this.title,
    required this.artists,
    this.album = '',
    this.src = '',
    this.cover = '',
    this.coverSource = '',
    this.duration = 0,
    this.explicit = false,
    this.releaseType = '',
    this.source = '',
  })  : primary = artists.isNotEmpty ? artists.first : 'Unknown artist',
        key = norm(
            '${artists.isNotEmpty ? artists.first : 'Unknown artist'} - $title');

  final String id;
  String title;
  List<String> artists;
  String album;
  String src;
  String cover;
  String coverSource;
  int duration;
  bool explicit;
  String releaseType;
  String source;
  String primary;
  String key;

  factory Track.empty() => Track(id: 'none', title: '', artists: const ['']);

  bool get playable => src.isNotEmpty;

  factory Track.fromRaw(Map raw, int index) {
    final rawArtists = <String>[];
    final artistsField = raw['artists'];
    if (artistsField is List) {
      for (final item in artistsField) {
        if (item is Map) {
          final name = item['name'];
          if (name != null) rawArtists.add(name.toString());
        } else if (item != null) {
          rawArtists.add(item.toString());
        }
      }
    }
    if (rawArtists.isEmpty && raw['artist'] != null) {
      rawArtists.add(raw['artist'].toString());
    }

    var title = asString(raw['title']).trim();
    final credits = <String>[];
    for (final item in rawArtists) {
      credits.addAll(splitCredits(item));
    }

    final feat = cachedRe(
      r'[\(\[]\s*(?:feat\.?|ft\.?|featuring|при уч\.?)\s+([^\)\]]+)[\)\]]',
      caseSensitive: false,
    ).firstMatch(title);
    if (feat != null) {
      title = title
          .replaceFirst(feat.group(0)!, '')
          .replaceAll(cachedRe(r'\s{2,}'), ' ')
          .trim();
      credits.addAll(splitCredits(feat.group(1)!));
    }

    final seen = <String>{};
    final artists = <String>[];
    for (final credit in credits) {
      final name = displayName(credit.trim());
      final key = norm(name);
      if (name.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      artists.add(name);
    }
    if (artists.isEmpty) artists.add('Unknown artist');

    final id = asString(raw['id']).isNotEmpty
        ? asString(raw['id'])
        : 't${index}_${hashString(title + artists.join())}';
    return Track(
      id: id,
      title: title.isEmpty ? asString(raw['title']) : title,
      artists: artists,
      album: asString(raw['album']),
      src: asString(raw['src']),
      cover: asString(raw['cover'] ?? raw['coverUrl']),
      coverSource: asString(raw['coverSource']),
      duration: asInt(raw['duration']),
      explicit: asBool(raw['explicit']) ||
          cachedRe(r'\bexplicit\b|\[e\]', caseSensitive: false).hasMatch(title),
      releaseType: asString(raw['releaseType']),
      source: asString(raw['source']),
    );
  }

  factory Track.fromCatalogJson(Map raw) {
    final track = Track.fromRaw({
      ...raw,
      'source': 'catalog',
      'cover': '',
      'coverSource': '',
    }, hashString(raw['id'] ?? raw['title']));
    if (track.releaseType.isEmpty) {
      track.releaseType = classifyRelease(track.title, track.album);
    }
    return track;
  }

  factory Track.fromJson(Map raw) => Track.fromRaw(raw, 0);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artists': artists,
        'primary': primary,
        'album': album,
        'src': src,
        'cover': cover,
        'coverSource': coverSource,
        'duration': duration,
        'explicit': explicit,
        'releaseType': releaseType,
        'source': source,
      };

  Track copy() => Track(
        id: id,
        title: title,
        artists: List<String>.from(artists),
        album: album,
        src: src,
        cover: cover,
        coverSource: coverSource,
        duration: duration,
        explicit: explicit,
        releaseType: releaseType,
        source: source,
      );
}

String classifyRelease(String title, String album, [int count = 0]) {
  final text = '${title.toLowerCase()} ${album.toLowerCase()}';
  if (cachedRe(r'\b(ep|мини[- ]?альбом|mini[- ]?album)\b').hasMatch(text)) {
    return 'ep';
  }
  if (cachedRe(r'\b(single|сингл)\b').hasMatch(text)) return 'single';
  if (cachedRe(r'\b(album|альбом|lp|long play)\b').hasMatch(text)) {
    return 'album';
  }
  if (count == 1) return 'single';
  if (count >= 4 && count <= 7) return 'ep';
  return '';
}

class ReleaseSong {
  ReleaseSong({
    required this.title,
    this.artist = '',
    this.album = '',
    this.cover = '',
    this.duration = 0,
    this.catalog,
    this.number = 0,
  });

  final String title;
  final String artist;
  final String album;
  final String cover;
  final int duration;
  Track? catalog;
  int number;

  factory ReleaseSong.fromJson(Map raw, [String fallbackArtist = '']) =>
      ReleaseSong(
        title: asString(raw['title']).trim(),
        artist: asString(raw['artist']).trim().isEmpty
            ? fallbackArtist
            : asString(raw['artist']).trim(),
        album: asString(raw['album']),
        cover: asString(raw['cover']),
        duration: asInt(raw['duration']),
        catalog: raw['catalog'] is Map
            ? Track.fromJson(asMap(raw['catalog']))
            : null,
        number: asInt(raw['number']),
      );

  ReleaseSong copy() => ReleaseSong(
        title: title,
        artist: artist,
        album: album,
        cover: cover,
        duration: duration,
        catalog: catalog,
        number: number,
      );
}

class Release {
  Release({
    required this.name,
    this.artistName = '',
    this.cover = '',
    this.type = '',
    this.year = '',
    this.tracks = const [],
    this.deezerId = '',
    this.trackCount = 0,
  });

  final String name;
  String artistName;
  String cover;
  String type;
  String year;
  List<ReleaseSong> tracks;
  final String deezerId;
  int trackCount;

  String get kindLabel {
    switch (type) {
      case 'album':
        return 'Album';
      case 'ep':
        return 'EP';
      case 'single':
        return 'Single';
      default:
        return 'Release';
    }
  }

  factory Release.fromJson(Map raw) => Release(
        name: asString(raw['name']),
        artistName: asString(raw['artistName'] ?? raw['artist']),
        cover: asString(raw['cover']),
        type: asString(raw['type']),
        year: asString(raw['year']),
        tracks: asList(raw['tracks'])
            .map((t) =>
                ReleaseSong.fromJson(asMap(t), asString(raw['artistName'])))
            .toList(),
        deezerId: asString(raw['deezerId']),
        trackCount: asInt(raw['trackCount']),
      );

  Release copyWith({List<ReleaseSong>? tracks, int? trackCount}) => Release(
        name: name,
        artistName: artistName,
        cover: cover,
        type: type,
        year: year,
        tracks: tracks ?? this.tracks,
        deezerId: deezerId,
        trackCount: trackCount ?? this.trackCount,
      );
}

class ReleaseArg {
  const ReleaseArg(this.release, {this.artist = '', this.highlightTrack = ''});
  final Release release;
  final String artist;
  final String highlightTrack;
}

class ReleaseIndex {
  ReleaseIndex(
      {this.releases = const [], this.songs = const [], this.noTracks = false});
  final List<Release> releases;
  final List<ReleaseSong> songs;
  final bool noTracks;
}

class ChatShareArg {
  const ChatShareArg(this.track, this.nonce);

  final Track track;
  final int nonce;
}

class ArtistInfo {
  ArtistInfo({
    required this.name,
    this.avatar = '',
    this.banner = '',
    this.bio = '',
    this.followers = 0,
    this.verified = false,
    this.url = '',
  });

  final String name;
  final String avatar;
  final String banner;
  final String bio;
  final int followers;
  final bool verified;
  final String url;

  static ArtistInfo empty(String name) => ArtistInfo(name: name);
}

class ArtistAlias {
  const ArtistAlias(this.name, this.names);
  final String name;
  final List<String> names;

  Map<String, dynamic> toJson() => {'name': name, 'names': names};
}

const List<ArtistAlias> knownArtists = [
  ArtistAlias('Тёмный принц',
      ['Тёмный принц', 'Темный принц', 'Darkprinceee', 'Dark Prince']),
  ArtistAlias('Kai Angel', ['Kai Angel']),
  ArtistAlias('madk1d', ['madk1d', 'Madkid']),
  ArtistAlias('Дора', ['Дора', 'Dora']),
  ArtistAlias('Тимати', ['Тимати', 'Timati']),
  ArtistAlias('AUGUST', ['AUGUST', 'August']),
  ArtistAlias('Anonymous Ember', ['Anonymous Ember']),
  ArtistAlias('Molly Santana', ['Molly Santana']),
  ArtistAlias('shadowraze', ['shadowraze', 'Shadowraze']),
  ArtistAlias('tewiq', ['tewiq', 'Tewiq']),
  ArtistAlias('fallen777angel', ['fallen777angel', 'Fallen777angel']),
  ArtistAlias('elyaplugg!', ['elyaplugg!', 'Elyaplugg', 'elyaplugg']),
  ArtistAlias('FENDIGLOCK', ['FENDIGLOCK', 'Fendiglock']),
  ArtistAlias('@ФакШиза', ['@ФакШиза', 'ФакШиза', 'Fckshizy']),
  ArtistAlias('Егор Крид', ['Егор Крид', 'Egor Kreed']),
  ArtistAlias('Heronwater', ['Heronwater']),
  ArtistAlias('Scally Milano', ['Scally Milano', 'Scally Millano']),
  ArtistAlias('9mice', ['9mice', '9 mice']),
];

ArtistAlias? knownArtist(String? name) {
  final key = looseKey(name);
  if (key.isEmpty) return null;
  for (final artist in knownArtists) {
    if (artist.names.any((alias) => looseKey(alias) == key)) return artist;
  }
  return null;
}

class Playlist {
  Playlist({
    required this.id,
    required this.name,
    required this.ids,
    this.cover = '',
    this.created = 0,
    this.isPublic = false,
  });

  final String id;
  String name;
  List<String> ids;
  String cover;
  int created;
  bool isPublic;

  factory Playlist.fromJson(Map raw) => Playlist(
        id: asString(raw['id']),
        name:
            asString(raw['name']).isEmpty ? 'Playlist' : asString(raw['name']),
        ids: asList(raw['ids']).map((e) => e.toString()).toList(),
        cover: asString(raw['cover']),
        created: asInt(raw['created']),
        isPublic: raw['public'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ids': ids,
        'cover': cover,
        'created': created,
        'public': isPublic,
      };

  Playlist copy() => Playlist(
      id: id,
      name: name,
      ids: List<String>.from(ids),
      cover: cover,
      created: created,
      isPublic: isPublic);
}

class PlayEntry {
  PlayEntry({required this.name, this.count = 0, this.last = 0});
  String name;
  double count;
  int last;

  factory PlayEntry.fromJson(Map raw) => PlayEntry(
      name: asString(raw['name']),
      count: (raw['count'] as num?)?.toDouble() ?? 0,
      last: asInt(raw['last']));

  Map<String, dynamic> toJson() => {'name': name, 'count': count, 'last': last};
}

class EqPreset {
  const EqPreset(this.name, this.bands, {this.custom = false});
  final String name;
  final List<double> bands;
  final bool custom;
}

class EqSettings {
  bool enabled = false;
  String preset = 'Flat';
  List<double> bands = List<double>.filled(10, 0);
  List<EqPreset> custom = [];

  EqSettings();

  factory EqSettings.fromJson(Map raw) {
    final eq = EqSettings();
    eq.enabled = asBool(raw['enabled']);
    final bands = asList(raw['bands']);
    if (bands.length == 10) {
      eq.bands = bands
          .map((v) => clampDouble((v as num?)?.toDouble() ?? 0, -12, 12))
          .toList();
    }
    for (final item in asList(raw['custom'])) {
      final map = asMap(item);
      final values = asList(map['bands']);
      if (values.length == 10) {
        eq.custom.add(EqPreset(
          asString(map['name']).isEmpty
              ? 'Preset'
              : clipText(asString(map['name']), 24),
          values
              .map((v) => clampDouble((v as num?)?.toDouble() ?? 0, -12, 12))
              .toList(),
          custom: true,
        ));
      }
    }
    return eq;
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'preset': preset,
        'bands': bands,
        'custom':
            custom.map((p) => {'name': p.name, 'bands': p.bands}).toList(),
      };

  EqSettings copy() {
    final eq = EqSettings();
    eq.enabled = enabled;
    eq.preset = preset;
    eq.bands = List<double>.from(bands);
    eq.custom = custom
        .map((p) => EqPreset(p.name, List<double>.from(p.bands), custom: true))
        .toList();
    return eq;
  }
}

class AppSettings {
  String theme = 'dark';
  String quality = 'normal';
  bool openArtwork = true;
  bool blurFullscreenArtwork = true;
  bool showFullscreenArtwork = true;
  bool windowsEfficiencyMode = false;
  EqSettings eq = EqSettings();

  AppSettings();

  factory AppSettings.fromJson(Map raw) {
    final settings = AppSettings();
    if (['dark', 'light', 'black'].contains(asString(raw['theme']))) {
      settings.theme = asString(raw['theme']);
    }
    if (['low', 'normal', 'high'].contains(asString(raw['quality']))) {
      settings.quality = asString(raw['quality']);
    }
    if (raw['openArtwork'] is bool) {
      settings.openArtwork = raw['openArtwork'] as bool;
    }
    if (raw['blurFullscreenArtwork'] is bool) {
      settings.blurFullscreenArtwork = raw['blurFullscreenArtwork'] as bool;
    }
    if (raw['showFullscreenArtwork'] is bool) {
      settings.showFullscreenArtwork = raw['showFullscreenArtwork'] as bool;
    }
    if (raw['windowsEfficiencyMode'] is bool) {
      settings.windowsEfficiencyMode = raw['windowsEfficiencyMode'] as bool;
    }
    settings.eq = EqSettings.fromJson(asMap(raw['eq']));
    return settings;
  }

  Map<String, dynamic> toJson() => {
        'theme': theme,
        'quality': quality,
        'openArtwork': openArtwork,
        'blurFullscreenArtwork': blurFullscreenArtwork,
        'showFullscreenArtwork': showFullscreenArtwork,
        'windowsEfficiencyMode': windowsEfficiencyMode,
        'eq': eq.toJson()
      };

  AppSettings copy() {
    final settings = AppSettings()
      ..theme = theme
      ..quality = quality
      ..openArtwork = openArtwork
      ..blurFullscreenArtwork = blurFullscreenArtwork
      ..showFullscreenArtwork = showFullscreenArtwork
      ..windowsEfficiencyMode = windowsEfficiencyMode
      ..eq = eq.copy();
    return settings;
  }
}

class Profile {
  String nickname = '';
  String avatar = '';

  Profile();

  factory Profile.fromJson(Map raw) => Profile()
    ..nickname = asString(raw['nickname']).length > 30
        ? asString(raw['nickname']).substring(0, 30)
        : asString(raw['nickname'])
    ..avatar = asString(raw['avatar']);

  Map<String, dynamic> toJson() => {'nickname': nickname, 'avatar': avatar};
}

class SetupState {
  bool done = false;
  String profile = '';
  SetupState();

  factory SetupState.fromJson(Map raw) => SetupState()
    ..done = asBool(raw['done'])
    ..profile = asString(raw['profile']);

  Map<String, dynamic> toJson() => {'done': done, 'profile': profile};
}

class NodeInfo {
  NodeInfo({
    required this.id,
    required this.label,
    this.active = false,
    this.ok,
    this.ms = 0,
  });

  final String id;
  final String label;
  final bool active;
  final bool? ok;
  final int ms;

  String statusLabel() {
    if (ok == null) return 'checking…';
    return ok == true ? '$ms ms' : 'unavailable';
  }

  factory NodeInfo.fromJson(Map raw) => NodeInfo(
        id: asString(raw['id']),
        label: asString(raw['label']),
        active: asBool(raw['active']),
        ok: raw.containsKey('ok') && raw['ok'] != null
            ? asBool(raw['ok'])
            : null,
        ms: asInt(raw['ms']),
      );
}

class NodeState {
  NodeState(
      {this.active = '',
      this.auto = true,
      this.base = '',
      this.nodes = const []});

  final String active;
  final bool auto;
  final String base;
  final List<NodeInfo> nodes;

  factory NodeState.fromJson(Map raw) => NodeState(
        active: asString(raw['active']),
        auto: raw.containsKey('auto') ? asBool(raw['auto']) : true,
        base: asString(raw['base']),
        nodes: asList(raw['nodes'])
            .map((n) => NodeInfo.fromJson(asMap(n)))
            .toList(),
      );

  String labelFor(String id) {
    for (final node in nodes) {
      if (node.id == id) return node.label;
    }
    return id;
  }
}

class LyricLine {
  LyricLine({this.t, required this.text});
  final double? t;
  final String text;
}

class LyricVariant {
  LyricVariant(
      {required this.label, required this.synced, required this.lines});
  final String label;
  final bool synced;
  final List<LyricLine> lines;
}

class LyricsResult {
  LyricsResult({this.variants = const [], this.failed = false});
  final List<LyricVariant> variants;
  final bool failed;
}

class PlaylistImportItem {
  PlaylistImportItem({required this.title, this.artist = '', this.album = ''});
  final String title;
  final String artist;
  final String album;
}

class PlaylistImportList {
  PlaylistImportList(
      {required this.name, required this.kind, required this.items});
  String name;
  final String kind; // playlist | liked
  final List<PlaylistImportItem> items;
}
