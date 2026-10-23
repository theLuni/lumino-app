import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/utils.dart';
import 'design.dart';

/// Shared context-menu and playlist actions used by the whole UI.

Future<void> shareTrackInChat(
    BuildContext context, AppState state, Track track) async {
  if (!context.mounted) return;
  if (state.fullScreen) state.closeFull();
  state.go(
    'chats',
    arg: ChatShareArg(track, DateTime.now().microsecondsSinceEpoch),
  );
}

Future<void> openTrackRelease(AppState state, Track track) async {
  final release = await state.releaseForTrack(track);
  if (state.fullScreen) state.closeFull();
  if (release != null) {
    state.go(
      'release',
      arg: ReleaseArg(
        release,
        artist:
            release.artistName.isNotEmpty ? release.artistName : track.primary,
        highlightTrack: track.title,
      ),
    );
  } else if (track.primary.isNotEmpty) {
    state.go('artist', arg: track.primary);
  }
}

Future<void> openTrackMenu(
  BuildContext context,
  AppState state,
  Track track,
  Offset position, {
  String? playlistId,
}) async {
  final liked = state.liked.contains(track.key);
  final inQueue = state.queue.contains(track.id);
  final items = <LuminoMenuItem>[
    LuminoMenuItem('Play next', 'playnext', () async {
      await state.queueAdd(track.id, playNext: true);
    }),
    LuminoMenuItem(inQueue ? 'Remove from queue' : 'Add to queue', 'list',
        () async {
      if (inQueue) {
        final index = state.queue.indexOf(track.id);
        if (index >= 0) await state.queueRemove(index);
      } else {
        await state.queueAdd(track.id);
      }
    }),
    LuminoMenuItem('Add to playlist…', 'plus',
        () => showPlaylistPicker(context, state, track)),
    LuminoMenuItem(liked ? 'Remove from Liked Songs' : 'Like', 'heart', () {
      state.toggleLike(track);
    }, filled: liked),
    LuminoMenuItem('Go to artist', 'user', () {
      final artist = track.artists.isNotEmpty ? track.artists.first : '';
      if (artist.isNotEmpty) state.go('artist', arg: artist);
    }),
    LuminoMenuItem('Share', 'share', () async {
      await shareTrackInChat(context, state, track);
    }),
  ];
  if (playlistId != null) {
    items.insert(
      3,
      LuminoMenuItem('Remove from this playlist', 'close', () {
        final playlist =
            state.playlists.where((p) => p.id == playlistId).firstOrNull;
        if (playlist != null) {
          state.removeTrackFromPlaylist(playlist, track.id);
          state.showToast('Removed from ${playlist.name}');
        }
      }, danger: true),
    );
  }
  if (!context.mounted) return;
  await showLuminoMenu(context, position, items);
}

Future<bool> showPlaylistPicker(
    BuildContext context, AppState state, Track track) async {
  if (state.playlists.length == 1) {
    final playlist = state.playlists.single;
    final added = !playlist.ids.contains(track.id);
    state.addTrackToPlaylist(playlist, track.id);
    return added;
  }
  if (state.playlists.isEmpty) {
    final name = await showTextPrompt(context,
        title: 'New playlist', placeholder: 'My playlist');
    if (name == null) return false;
    if (!isPermittedPlaylistName(name)) {
      state.showToast('This name is not permitted.');
      return false;
    }
    state.createPlaylist(name, firstId: track.id);
    state.showToast('Added to $name');
    return true;
  }
  if (!context.mounted) return false;
  var createdPlaylist = false;
  final added = await showGlassDialog<bool>(
    context,
    width: 380,
    builder: (dialogContext) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Add to playlist',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('${track.artists.join(', ')} — ${track.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13, color: ThemeScope.of(context).mutedForeground)),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final playlist in state.playlists)
                  HoverBuilder(
                    builder: (context, hovered) => GestureDetector(
                      onTap: () {
                        final added = !playlist.ids.contains(track.id);
                        state.addTrackToPlaylist(playlist, track.id);
                        Navigator.of(dialogContext).pop(added);
                      },
                      child: Container(
                        height: 46,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: hovered
                              ? const Color(0x14FFFFFF)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            PlaylistCover(
                                playlist: playlist, size: 34, radius: 8),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(playlist.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500)),
                            ),
                            Text('${playlist.ids.length}',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: ThemeScope.of(context)
                                        .mutedForeground)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () async {
            Navigator.of(dialogContext).pop();
            final name = await showTextPrompt(context,
                title: 'New playlist', placeholder: 'My playlist');
            if (name == null) return;
            if (!isPermittedPlaylistName(name)) {
              state.showToast('This name is not permitted.');
              return;
            }
            state.createPlaylist(name, firstId: track.id);
            state.showToast('Added to $name');
            createdPlaylist = true;
          },
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: const [
              LIcon('plus', size: 18, color: Colors.white),
              SizedBox(width: 12),
              Text('New playlist',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ],
    ),
  );
  return added ?? createdPlaylist;
}

Future<void> createPlaylistFlow(BuildContext context, AppState state) async {
  final name = await showTextPrompt(context,
      title: 'New playlist', placeholder: 'My playlist');
  if (name == null) return;
  if (!isPermittedPlaylistName(name)) {
    state.showToast('This name is not permitted.');
    return;
  }
  state.createPlaylist(name);
  state.showToast('Playlist created');
}

Future<void> renamePlaylistFlow(
    BuildContext context, AppState state, Playlist playlist) async {
  final name = await showTextPrompt(
    context,
    title: 'Rename playlist',
    value: playlist.name,
    okLabel: 'Save',
  );
  if (name == null) return;
  if (!isPermittedPlaylistName(name)) {
    state.showToast('This name is not permitted.');
    return;
  }
  playlist.name = name;
  state.save();
  state.refresh();
  state.showToast('Playlist renamed');
}

Future<void> deletePlaylistFlow(
    BuildContext context, AppState state, Playlist playlist) async {
  final ok = await confirmDialog(
    context,
    title: 'Delete playlist?',
    message:
        '“${playlist.name}” will be removed from your library. This cannot be undone.',
    confirmLabel: 'Delete',
    danger: true,
  );
  if (!ok) return;
  state.deletePlaylist(playlist);
  if (state.pageName == 'playlist') state.go('library', push: false);
  state.showToast('Playlist deleted');
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool danger = false,
}) async {
  final result = await showGlassDialog<bool>(
    context,
    width: 400,
    builder: (dialogContext) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(message,
            style: TextStyle(
                fontSize: 13.5,
                color: ThemeScope.of(context).mutedForeground,
                height: 1.45)),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(
            child: GhostButton(
              label: 'Cancel',
              height: 40,
              padding: 0,
              onTap: () => Navigator.of(dialogContext).pop(false),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: HoverBuilder(
              builder: (context, hovered) => GestureDetector(
                onTap: () => Navigator.of(dialogContext).pop(true),
                child: Container(
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: danger
                        ? (hovered
                            ? const Color(0xFFFF8E8E)
                            : const Color(0xFFFF6F6F))
                        : (hovered ? const Color(0xFFE8E8EE) : Colors.white),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    confirmLabel,
                    style: TextStyle(
                      color: danger
                          ? const Color(0xFF1A0505)
                          : const Color(0xFF111111),
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ],
    ),
  );
  return result ?? false;
}

Future<void> shareArtist(
    BuildContext context, AppState state, String name) async {
  await copyToClipboard('${displayName(name)} — artist on Lumino');
  state.showToast('Artist link copied to clipboard');
}

/// A 34px square playlist cover that matches the renderer's `plArt` look.
class PlaylistCover extends StatelessWidget {
  const PlaylistCover(
      {super.key, required this.playlist, this.size = 34, this.radius = 8});
  final Playlist playlist;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final initial = playlist.name.isEmpty
        ? '?'
        : playlist.name.characters.first.toUpperCase();
    if (playlist.cover.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          width: size,
          height: size,
          child: imageWidget(playlist.cover),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3A3A44), Color(0xFF16161A)],
          ),
        ),
        alignment: Alignment.center,
        child: Text(initial,
            style: TextStyle(
                fontSize: size * 0.42,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
      ),
    );
  }
}
