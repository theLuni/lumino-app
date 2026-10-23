import 'dart:convert';

import 'app_state.dart';
import 'models.dart';

const String luminoLinkScheme = 'lumino';
const String shareLinkHost = 'fascind.theluni.ru';

class ShareLinkTarget {
  const ShareLinkTarget.track(this.track)
      : kind = 'track',
        username = '',
        playlistId = '',
        token = '',
        shareCode = '';

  const ShareLinkTarget.profile(this.username)
      : kind = 'profile',
        track = null,
        playlistId = '',
        token = '',
        shareCode = '';

  const ShareLinkTarget.playlist({
    required this.username,
    required this.playlistId,
  })  : kind = 'playlist',
        track = null,
        token = '',
        shareCode = '';

  const ShareLinkTarget.privatePlaylist(this.token)
      : kind = 'private-playlist',
        track = null,
        username = '',
        playlistId = '',
        shareCode = '';

  const ShareLinkTarget.shortTrack(this.shareCode)
      : kind = 'short-track',
        track = null,
        username = '',
        playlistId = '',
        token = '';

  final String kind;
  final Track? track;
  final String username;
  final String playlistId;
  final String token;
  final String shareCode;
}

Uri trackShareUri(Track track) {
  final data = jsonEncode({
    'id': track.id,
    'title': track.title,
    'artists': track.artists,
    'album': track.album,
    'cover': track.cover,
    'duration': track.duration,
    'releaseType': track.releaseType,
  });
  final encoded = base64Url.encode(utf8.encode(data)).replaceAll('=', '');
  return Uri(
      scheme: 'https',
      host: shareLinkHost,
      path: '/share',
      queryParameters: {
        'type': 'track',
        'data': encoded,
      });
}

Uri profileShareUri(String username) =>
    Uri(scheme: 'https', host: shareLinkHost, path: '/share', queryParameters: {
      'type': 'profile',
      'username': username,
    });

Uri publicPlaylistShareUri(String username, String playlistId) =>
    Uri(scheme: 'https', host: shareLinkHost, path: '/share', queryParameters: {
      'type': 'playlist',
      'username': username,
      'id': playlistId,
    });

Uri privatePlaylistShareUri(String token) =>
    Uri(scheme: 'https', host: shareLinkHost, path: '/share', queryParameters: {
      'type': 'playlist',
      'token': token,
    });

ShareLinkTarget? parseShareUri(Uri uri) {
  var link = uri;
  if (uri.scheme.toLowerCase() == 'https') {
    if (uri.host.toLowerCase() != shareLinkHost) {
      return null;
    }
    final shortPath =
        RegExp(r'^/s/([A-Za-z0-9_-]{10,16})$').firstMatch(uri.path);
    if (shortPath != null && uri.queryParameters.isEmpty) {
      return ShareLinkTarget.shortTrack(shortPath.group(1)!);
    }
    if (uri.path != '/share') return null;
    final type = uri.queryParameters['type'];
    if (!const {'track', 'profile', 'playlist'}.contains(type)) return null;
    final parameters = Map<String, String>.from(uri.queryParameters)
      ..remove('type');
    link = Uri(
      scheme: luminoLinkScheme,
      host: type,
      queryParameters: parameters,
    );
  } else if (uri.scheme.toLowerCase() != luminoLinkScheme) {
    return null;
  } else if (uri.host.toLowerCase() == 'share') {
    final shortPath = RegExp(r'^/([A-Za-z0-9_-]{10,16})$').firstMatch(uri.path);
    if (shortPath == null || uri.queryParameters.isNotEmpty) return null;
    return ShareLinkTarget.shortTrack(shortPath.group(1)!);
  }
  switch (link.host.toLowerCase()) {
    case 'track':
      final encoded = link.queryParameters['data'];
      if (encoded == null || encoded.length > 12000) return null;
      try {
        final normalized = base64Url.normalize(encoded);
        final decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
        if (decoded is! Map) return null;
        final track = Track.fromJson(decoded);
        if (track.title.trim().isEmpty || track.artists.isEmpty) return null;
        return ShareLinkTarget.track(track);
      } on FormatException {
        return null;
      }
    case 'share':
      return null;
    case 'profile':
      final username = link.queryParameters['username']?.trim() ?? '';
      if (!_validUsername(username)) return null;
      return ShareLinkTarget.profile(username);
    case 'playlist':
      final token = link.queryParameters['token']?.trim() ?? '';
      if (token.isNotEmpty) {
        if (!RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(token)) return null;
        return ShareLinkTarget.privatePlaylist(token);
      }
      final username = link.queryParameters['username']?.trim() ?? '';
      final id = link.queryParameters['id']?.trim() ?? '';
      if (!_validUsername(username) ||
          id.isEmpty ||
          id.length > 128 ||
          !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
        return null;
      }
      return ShareLinkTarget.playlist(username: username, playlistId: id);
    default:
      return null;
  }
}

Future<void> openShareLinkTarget(AppState state, ShareLinkTarget target) async {
  state.closeFull();
  switch (target.kind) {
    case 'track':
      state.go('home');
      await state.playSharedTrack(target.track!);
      break;
    case 'profile':
      final profile = await state.auth.publicUserProfile(target.username);
      state.go('user-profile', arg: profile);
      break;
    case 'playlist':
      final profile = await state.auth.publicUserProfile(target.username);
      final playlists = profile['public_playlists'];
      final matches = playlists is List
          ? playlists.whereType<Map>().where(
              (item) => (item['id'] ?? '').toString() == target.playlistId)
          : const <Map>[];
      final playlist = matches.isEmpty ? null : matches.first;
      if (playlist == null) {
        throw StateError('Public playlist is unavailable.');
      }
      state.go('public-playlist', arg: {
        ...playlist.map((key, value) => MapEntry(key.toString(), value)),
        'username': target.username,
        'owner': profile['display_name'] ?? target.username,
      });
      break;
    case 'private-playlist':
      final playlist = await state.auth.privatePlaylistShare(target.token);
      state.go('public-playlist', arg: playlist);
      break;
    case 'short-track':
      state.go('home');
      final track = await state.auth.sharedTrack(target.shareCode);
      await state.playSharedTrack(track);
      break;
  }
}

bool _validUsername(String username) =>
    username.length >= 3 &&
    username.length <= 32 &&
    RegExp(r'^[\w.@+\- ]+$').hasMatch(username);
