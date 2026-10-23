import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'design.dart';
import 'pages/artist.dart';
import 'pages/chats.dart';
import 'pages/home.dart';
import 'pages/library.dart';
import 'pages/profile.dart';
import 'pages/search.dart';
import 'pages/settings.dart';

bool pageHasBack(String name) => const {
      'artist',
      'mix',
      'liked',
      'playlist',
      'release',
      'profile',
      'user-profile',
      'chats',
    }.contains(name);

String pageIdentity(AppState state) {
  final arg = state.pageArg;
  if (arg is String) return '${state.pageName}:$arg';
  if (arg is ReleaseArg) {
    return '${state.pageName}:${arg.release.name}:${arg.artist}:${arg.highlightTrack}';
  }
  if (arg is ChatShareArg) return 'chats:${arg.nonce}';
  if (arg is Map) return '${state.pageName}:${arg['username'] ?? ''}';
  return state.pageName;
}

Widget buildPage(AppState state, {required Future<void> Function() onSignOut}) {
  switch (state.pageName) {
    case 'home':
      return HomePage(key: const ValueKey('home'), state: state);
    case 'search':
      return SearchPage(key: const ValueKey('search'), state: state);
    case 'chats':
      final shared =
          state.pageArg is ChatShareArg ? state.pageArg as ChatShareArg : null;
      return ChatsPage(
        key: ValueKey('chats:${shared?.nonce ?? 'inbox'}'),
        state: state,
        sharedTrack: shared,
      );
    case 'library':
      return LibraryPage(key: const ValueKey('library'), state: state);
    case 'settings':
      return SettingsPage(
          key: const ValueKey('settings'), state: state, onSignOut: onSignOut);
    case 'liked':
      return LikedPage(key: const ValueKey('liked'), state: state);
    case 'profile':
      return ProfilePage(key: const ValueKey('profile'), state: state);
    case 'user-profile':
      final user = state.pageArg is Map
          ? (state.pageArg as Map)
              .map((key, value) => MapEntry(key.toString(), value))
          : <String, dynamic>{};
      return PublicUserProfilePage(
          key: ValueKey('user-profile:${user['username'] ?? ''}'),
          state: state,
          user: user);
    case 'artist':
      final name = state.pageArg is String ? state.pageArg as String : '';
      return ArtistPage(
          key: ValueKey('artist:$name'), state: state, name: name);
    case 'mix':
      final key = state.pageArg is String ? state.pageArg as String : '';
      return MixPage(key: ValueKey('mix:$key'), state: state, listKey: key);
    case 'release':
      final arg =
          state.pageArg is ReleaseArg ? state.pageArg as ReleaseArg : null;
      if (arg == null) {
        return const PagePadding(
          child: EmptyState(text: 'This release is no longer available.'),
        );
      }
      return ReleasePage(
        key: ValueKey(
            'release:${arg.release.deezerId}:${arg.release.name}:${arg.artist}:${arg.highlightTrack}'),
        state: state,
        arg: arg,
      );
    case 'playlist':
      final id = state.pageArg is String ? state.pageArg as String : '';
      if (!state.playlists.any((item) => item.id == id)) {
        return const PagePadding(
          child: EmptyState(text: 'This playlist no longer exists.'),
        );
      }
      return PlaylistPage(
          key: ValueKey('playlist:$id'), state: state, playlistId: id);
    default:
      return const PagePadding(child: EmptyState(text: 'Page not found'));
  }
}
