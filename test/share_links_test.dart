import 'package:flutter_test/flutter_test.dart';
import 'package:lumino/core/models.dart';
import 'package:lumino/core/share_links.dart';

void main() {
  test('track link round trips safe track metadata only', () {
    final track = Track(
      id: 'track-42',
      title: 'A song',
      artists: const ['An artist'],
      src: 'https://example.invalid/audio.mp3',
      cover: 'https://example.invalid/cover.jpg',
      album: 'An album',
      duration: 123,
    );

    final target = parseShareUri(trackShareUri(track));

    expect(trackShareUri(track).scheme, 'https');
    expect(trackShareUri(track).host, shareLinkHost);
    expect(target?.kind, 'track');
    expect(target?.track?.id, track.id);
    expect(target?.track?.title, track.title);
    expect(target?.track?.src, isEmpty);
    expect(target?.track?.duration, track.duration);
  });

  test('profile and playlist links parse their identifiers', () {
    final profile = parseShareUri(profileShareUri('user.name'));
    final playlist = parseShareUri(
      publicPlaylistShareUri('user.name', 'playlist_42'),
    );

    expect(profile?.kind, 'profile');
    expect(profile?.username, 'user.name');
    expect(playlist?.kind, 'playlist');
    expect(playlist?.username, 'user.name');
    expect(playlist?.playlistId, 'playlist_42');
  });

  test('private playlist token remains an opaque bearer capability', () {
    final target = parseShareUri(privatePlaylistShareUri('Abcd_1234' * 4));

    expect(privatePlaylistShareUri('Abcd_1234' * 4).scheme, 'https');
    expect(target?.kind, 'private-playlist');
    expect(target?.token, 'Abcd_1234' * 4);
  });

  test('invalid and unrelated links are rejected', () {
    expect(parseShareUri(Uri.parse('https://lumino/track')), isNull);
    expect(
      parseShareUri(
        Uri.parse(
            'https://fascind.theluni.ru/not-share?type=profile&username=abc'),
      ),
      isNull,
    );
    expect(parseShareUri(Uri.parse('lumino://profile?username=x')), isNull);
    expect(
      parseShareUri(Uri.parse('lumino://track?data=not-base64!')),
      isNull,
    );
  });

  test('short track URLs and app links parse a compact code', () {
    final https = Uri(
      scheme: 'https',
      host: shareLinkHost,
      path: '/s/Abcd_1234567',
    );
    final app = Uri.parse('lumino://share/Abcd_1234567');

    expect(parseShareUri(https)?.kind, 'short-track');
    expect(parseShareUri(https)?.shareCode, 'Abcd_1234567');
    expect(parseShareUri(app)?.kind, 'short-track');
    expect(parseShareUri(app)?.shareCode, 'Abcd_1234567');
    expect(
      parseShareUri(Uri.parse('https://$shareLinkHost/s/short')),
      isNull,
    );
  });
}
