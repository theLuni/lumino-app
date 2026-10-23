// Pure-logic tests: the app's Flutter widgets depend on media_kit and
// platform channels, so these cover the model parsing and the utility
// helpers everything else builds on.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumino/core/catalog_service.dart';
import 'package:lumino/core/importer.dart';
import 'package:lumino/core/models.dart';
import 'package:lumino/core/utils.dart';

void main() {
  group('splitCredits', () {
    test('splits feat. and & credits', () {
      expect(splitCredits('lilmorty feat. augustin & n01r'),
          ['lilmorty', 'augustin', 'n01r']);
    });

    test('keeps a single artist', () {
      expect(splitCredits('lilmorty'), ['lilmorty']);
    });

    test('splits ft. and , credits', () {
      expect(splitCredits('a ft. b, c'), ['a', 'b', 'c']);
    });
  });

  group('looseKey', () {
    test('folds ё and strips case/punctuation', () {
      expect(looseKey('  Тёмный   Принц! '), 'темныйпринц');
      expect(looseKey('LilMorty'), 'lilmorty');
    });

    test('is deterministic across case', () {
      expect(looseKey('AuguSTIN'), looseKey('augustin'));
    });
  });

  group('canonicalTrackTitle', () {
    test('uses Kai Angel title aliases only in the matching albums', () {
      expect(
        canonicalTrackTitle('Kai Angel', 'naive', album: 'damage'),
        'slave to the rhythm',
      );
      expect(
        canonicalTrackTitle('Kai Angel', 'MM', album: 'MM'),
        'MARILYN MANSON',
      );
      expect(
        canonicalTrackTitle('Kai Angel', 'KYLIE', album: 'ANGEL MAY CRY'),
        'KYLIE MINOGUE',
      );
    });

    test('does not apply aliases to another artist or album', () {
      expect(
        canonicalTrackTitle('Other artist', 'naive', album: 'damage'),
        'naive',
      );
      expect(
        canonicalTrackTitle('Kai Angel', 'KYLIE', album: 'damage'),
        'KYLIE',
      );
    });
  });

  group('AppSettings', () {
    test('persists the artwork preview preference', () {
      final settings = AppSettings()..openArtwork = false;
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.openArtwork, isFalse);
      expect(AppSettings.fromJson({}).openArtwork, isTrue);
    });
  });

  group('Playlist visibility', () {
    test('playlists are private by default and retain public state', () {
      final playlist = Playlist(
        id: 'test',
        name: 'Test',
        ids: const [],
      );
      expect(playlist.isPublic, isFalse);
      final restored = Playlist.fromJson(
        playlist.copy().toJson()..['public'] = true,
      );
      expect(restored.isPublic, isTrue);
      expect(restored.copy().isPublic, isTrue);
    });
  });

  group('levenshtein', () {
    test('basic distances', () {
      expect(levenshtein('kitten', 'sitting'), 3);
      expect(levenshtein('abc', 'abc'), 0);
      expect(levenshtein('', 'abc'), 3);
    });
  });

  group('Track', () {
    test('fromRaw strips feat. and applies display names', () {
      final track = Track.fromRaw(
        {
          'id': 't1',
          'title': 'Песня',
          'artists': ['lilmorty', 'feat. augustin'],
          'duration': 180,
          'src': 'http://x/1.mp3',
        },
        0,
      );
      expect(track.title, 'Песня');
      expect(track.artists, ['LIL MORTY', 'augustin']);
      expect(track.primary, 'LIL MORTY');
      expect(track.id, 't1');
      expect(track.duration, 180);
    });

    group('Explicit lyrics detection', () {
      test('marks explicit lyrics and ignores clean text', () {
        expect(hasExplicitLyrics('This song says fuck.'), isTrue);
        expect(hasExplicitLyrics('Обычный текст песни'), isFalse);
      });
    });

    test('feat. prefix is stripped but position is kept', () {
      final track = Track.fromRaw({
        'id': 't2',
        'title': 'x',
        'artists': ['feat. b', 'a']
      }, 0);
      expect(track.artists, ['b', 'a']);
      expect(track.primary, 'b');
    });

    test('fromJson round trip', () {
      final track = Track(
          id: 'x1', title: 'Т', artists: ['a', 'b'], duration: 12, cover: 'c');
      final back = Track.fromJson(track.toJson());
      expect(back.id, 'x1');
      expect(back.title, 'Т');
      expect(back.artists, ['a', 'b']);
      expect(back.duration, 12);
      expect(back.cover, 'c');
    });
  });

  group('matchPlayableTrack', () {
    test('does not substitute a different title by the same artist', () {
      final wrong = Track(
        id: 'wrong',
        title: 'Madam 2',
        artists: ['Kai Angel'],
        album: 'Shh!',
        src: 'audio://wrong',
      );
      expect(
        matchPlayableTrack([wrong],
            title: 'does it hurt?', artist: 'Kai Angel', album: 'Shh!'),
        isNull,
      );
    });

    test('prefers the exact album when matching duplicate tracks', () {
      final otherAlbum = Track(
        id: 'other',
        title: 'naive',
        artists: ['Kai Angel'],
        album: 'other album',
        src: 'audio://other',
      );
      final correct = Track(
        id: 'correct',
        title: 'naive',
        artists: ['Kai Angel'],
        album: 'damage',
        src: 'audio://correct',
      );
      expect(
        matchPlayableTrack([otherAlbum, correct],
                title: 'naive', artist: 'Kai Angel', album: 'damage')
            ?.id,
        'correct',
      );
    });
  });

  group('ImportParser', () {
    test('parses "Artist — Title" text lines', () {
      final lists = ImportParser.parse('lilmorty — Песня\naugustin — Другая');
      expect(lists.length, 1);
      expect(lists.first.items.length, 2);
      expect(lists.first.items[0].artist, 'lilmorty');
      expect(lists.first.items[0].title, 'Песня');
    });

    test('parses CSV with headers', () {
      final lists = ImportParser.parse('Artist,Title\nlilmorty,Песня');
      expect(lists.length, 1);
      expect(lists.first.items.length, 1);
      expect(lists.first.items[0].artist, 'lilmorty');
      expect(lists.first.items[0].title, 'Песня');
    });

    test('removes duplicate tracks regardless of capitalization', () {
      final lists = ImportParser.parse(
        'Artist - Title\nartist - title',
        'playlist.txt',
      );
      expect(lists.single.items, hasLength(1));
    });

    test('empty input gives no lists', () {
      expect(ImportParser.parse(''), isEmpty);
    });

    test('splitArtistTitle handles em dash and missing artist', () {
      expect(ImportParser.splitArtistTitle('lilmorty — Песня'),
          (artist: 'lilmorty', title: 'Песня'));
      expect(ImportParser.splitArtistTitle('Песня без артиста'),
          (artist: '', title: 'Песня без артиста'));
    });
  });
}
