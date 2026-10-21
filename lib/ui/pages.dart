import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'design.dart';
import 'pages/artist.dart';
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
      'profile'
    }.contains(name);

String pageIdentity(AppState state) {
  final arg = state.pageArg;
  if (arg is String) return '${state.pageName}:$arg';
  if (arg is ReleaseArg)
    return '${state.pageName}:${arg.release.name}:${arg.artist}';
  return state.pageName;
}

Widget buildPage(AppState state, {required Future<void> Function() onSignOut}) {
  switch (state.pageName) {
    case 'home':
      return HomePage(key: const ValueKey('home'), state: state);
    case 'search':
      return SearchPage(key: const ValueKey('search'), state: state);
    case 'library':
      return LibraryPage(key: const ValueKey('library'), state: state);
    case 'settings':
      return SettingsPage(
          key: const ValueKey('settings'), state: state, onSignOut: onSignOut);
    case 'liked':
      return LikedPage(key: const ValueKey('liked'), state: state);
    case 'profile':
      return ProfilePage(key: const ValueKey('profile'), state: state);
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
            'release:${arg.release.deezerId}:${arg.release.name}:${arg.artist}'),
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
