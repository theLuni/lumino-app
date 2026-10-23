import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import '../actions.dart';
import '../design.dart';
import '../importer_dialog.dart';
import '../lazy_track_rows.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final liked = state
        .availableTracks()
        .where((t) => state.liked.contains(t.key))
        .toList();
    final likedKey = state.reg('liked', liked);
    final artists = state.savedArtists.values.toList();
    final shown = liked;
    state.ensureCovers(liked.take(12), priority: true);

    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 18 : 32, compact ? 14 : 24, compact ? 18 : 32, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              const Text('Library',
                  style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6)),
              ChipButton(
                  label: 'New playlist',
                  icon: 'plus',
                  onTap: () => createPlaylistFlow(context, state)),
              ChipButton(
                  label: 'Import',
                  ghost: true,
                  onTap: () => showImporter(context, state)),
            ],
          ),
          _LibSectionHead(title: 'Playlists', count: state.playlists.length),
          if (state.playlists.isEmpty)
            const EmptyState(
              text:
                  'No playlists yet. Create one or import yours from another service.',
              left: true,
            )
          else
            LayoutBuilder(builder: (context, constraints) {
              const gap = 16.0;
              final columns = ((constraints.maxWidth + gap) / (150 + gap))
                  .floor()
                  .clamp(2, 8)
                  .toInt();
              final rows = <Widget>[];
              for (var i = 0; i < state.playlists.length; i += columns) {
                final slice = state.playlists.sublist(
                    i, (i + columns).clamp(0, state.playlists.length).toInt());
                rows.add(Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var j = 0; j < columns; j++) ...[
                      if (j > 0) const SizedBox(width: gap),
                      Expanded(
                        child: j < slice.length
                            ? _PlaylistTile(state: state, playlist: slice[j])
                            : const SizedBox(),
                      ),
                    ],
                  ],
                ));
                if (i + columns < state.playlists.length) {
                  rows.add(const SizedBox(height: 18));
                }
              }
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: rows);
            }),
          _LibSectionHead(title: 'Artists', count: artists.length),
          if (artists.isEmpty)
            const EmptyState(
              text:
                  'Add artists from their pages with the “+” button — they will appear here.',
              left: true,
            )
          else
            Wrap(
              spacing: 22,
              runSpacing: 22,
              children: [
                for (final name in artists)
                  SizedBox(
                    width: 118,
                    child: _LibArtist(state: state, name: name),
                  ),
              ],
            ),
          _LibSectionHead(
              title: 'Liked Songs', count: 0, hideTitle: liked.isNotEmpty),
          if (liked.isEmpty)
            const EmptyState(
              text: 'Tap the heart in the player to collect your liked songs.',
              left: true,
            )
          else ...[
            _LikedSummary(state: state, count: liked.length, listKey: likedKey),
            const SizedBox(height: 10),
            LazyTrackRows(
              state: state,
              tracks: shown,
              rowBuilder: (context, i) {
                final track = shown[i];
                return TrackRow(
                  track: track,
                  current: state.current?.id == track.id,
                  playing: state.playing,
                  durationText:
                      track.duration > 0 ? fmtDuration(track.duration) : '',
                  onPlay: () =>
                      state.playIds(state.lists[likedKey] ?? const [], i),
                  onArtist: (name) => state.go('artist', arg: name),
                  onMenu: (position) =>
                      openTrackMenu(context, state, track, position),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _LibSectionHead extends StatelessWidget {
  const _LibSectionHead(
      {required this.title, required this.count, this.hideTitle = false});
  final String title;
  final int count;
  final bool hideTitle;

  @override
  Widget build(BuildContext context) {
    if (hideTitle) return const SizedBox(height: 26);
    return Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 14),
      child: Row(children: [
        Text(title,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        if (count > 0) ...[
          const SizedBox(width: 8),
          Text('$count',
              style: TextStyle(
                  fontSize: 13, color: ThemeScope.of(context).mutedForeground)),
        ],
      ]),
    );
  }
}

class _PlaylistTile extends StatefulWidget {
  const _PlaylistTile({required this.state, required this.playlist});
  final AppState state;
  final Playlist playlist;

  @override
  State<_PlaylistTile> createState() => _PlaylistTileState();
}

class _PlaylistTileState extends State<_PlaylistTile> {
  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;
    final tracks = playlist.ids
        .map((id) => widget.state.byId[id])
        .whereType<Track>()
        .toList();
    final cover = playlist.cover.isNotEmpty
        ? playlist.cover
        : (tracks
            .map((track) => track.cover)
            .firstWhere((c) => c.isNotEmpty, orElse: () => ''));
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        onTap: () => widget.state.go('playlist', arg: playlist.id),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            transform: Matrix4.translationValues(0, hovered ? -2 : 0, 0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: hovered
                  ? const [
                      BoxShadow(
                          color: Color(0x73000000),
                          blurRadius: 30,
                          offset: Offset(0, 12))
                    ]
                  : const [],
            ),
            child: CoverArt(
              url: cover,
              seed: playlist.name,
              letter: playlist.name.isEmpty
                  ? '?'
                  : playlist.name.characters.first.toUpperCase(),
              square: true,
              radius: 12,
            ),
          ),
          const SizedBox(height: 10),
          Text(playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('${tracks.length} ${plural(tracks.length, 'track', 'tracks')}',
              style: TextStyle(
                  fontSize: 12.5,
                  color: ThemeScope.of(context).mutedForeground)),
        ]),
      ),
    );
  }
}

class _LibArtist extends StatefulWidget {
  const _LibArtist({required this.state, required this.name});
  final AppState state;
  final String name;

  @override
  State<_LibArtist> createState() => _LibArtistState();
}

class _LibArtistState extends State<_LibArtist> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(clipBehavior: Clip.none, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.state.go('artist', arg: widget.name),
          child: Column(children: [
            AvatarFromUrl(
                name: widget.name,
                url: () => widget.state.avatarOf(widget.name),
                size: 112,
                fontSize: 40),
            const SizedBox(height: 9),
            Text(displayName(widget.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('Artist',
                style: TextStyle(
                    fontSize: 12,
                    color: ThemeScope.of(context).mutedForeground)),
          ]),
        ),
        if (_hovered)
          Positioned(
            right: 0,
            top: 0,
            child: GestureDetector(
              onTap: () {
                widget.state.removeSavedArtist(widget.name);
                widget.state.showToast(
                    'Removed ${displayName(widget.name)} from library');
              },
              child: Container(
                width: 26,
                height: 26,
                decoration: const BoxDecoration(
                    color: Color(0xD90A0A0C), shape: BoxShape.circle),
                alignment: Alignment.center,
                child: const LIcon('close', size: 13, color: Colors.white),
              ),
            ),
          ),
      ]),
    );
  }
}

class _LikedSummary extends StatelessWidget {
  const _LikedSummary(
      {required this.state, required this.count, required this.listKey});
  final AppState state;
  final int count;
  final String listKey;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Row(children: [
      GestureDetector(
        onTap: () => state.go('liked'),
        child: Container(
          width: compact ? 108 : 152,
          height: compact ? 108 : 152,
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF5468D8), Color(0xFF8155CB), Color(0xFFC65391)],
            ),
          ),
          alignment: Alignment.center,
          child:
              const LIcon('heart', size: 40, color: Colors.white, filled: true),
        ),
      ),
      SizedBox(width: compact ? 12 : 20),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          onTap: () => state.go('liked'),
          child: const Text('Liked Songs',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 5),
        Text('Playlist · $count ${plural(count, 'song', 'songs')}',
            style: TextStyle(
                fontSize: 13, color: ThemeScope.of(context).mutedForeground)),
        const SizedBox(height: 12),
        Row(children: [
          PlayButton(
              label: 'Play',
              onTap: () => state.playIds(state.lists[listKey] ?? const [])),
          if (count > 0) ...[
            const SizedBox(width: 8),
            GhostButton(label: 'Show all', onTap: () => state.go('liked')),
          ],
        ]),
      ]),
    ]);
  }
}

class LikedPage extends StatelessWidget {
  const LikedPage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final tracks = state
        .availableTracks()
        .where((t) => state.liked.contains(t.key))
        .toList();
    final listKey = state.reg('liked-open', tracks);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF292B3A),
                  Color(0xFF181820),
                  Color(0xFF111113),
                ],
              ),
            ),
            child: Row(children: [
              _likedCover(),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Liked Songs',
                          style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.6)),
                      const SizedBox(height: 4),
                      Text(
                          'Playlist · ${tracks.length} ${plural(tracks.length, 'song', 'songs')}',
                          style: TextStyle(
                              fontSize: 13,
                              color: ThemeScope.of(context).mutedForeground)),
                      if (tracks.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        PlayButton(
                            label: 'Play',
                            onTap: () => state
                                .playIds(state.lists[listKey] ?? const [])),
                      ],
                    ]),
              ),
            ]),
          ),
          const SizedBox(height: 18),
          const SectionTitle(title: 'Tracks'),
          if (tracks.isEmpty)
            const EmptyState(
                text:
                    'No liked songs yet. Tap the + on the cover in the full-screen player to like a track.')
          else
            LazyTrackRows(
              state: state,
              tracks: tracks,
              rowBuilder: (context, i) {
                final track = tracks[i];
                return TrackRow(
                  track: track,
                  current: state.current?.id == track.id,
                  playing: state.playing,
                  durationText:
                      track.duration > 0 ? fmtDuration(track.duration) : '',
                  onPlay: () =>
                      state.playIds(state.lists[listKey] ?? const [], i),
                  onArtist: (name) => state.go('artist', arg: name),
                  onMenu: (position) =>
                      openTrackMenu(context, state, track, position),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _likedCover() {
    return Container(
      width: 112,
      height: 112,
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF5B5B6E), Color(0xFF2A2A34), Color(0xFF17171C)],
        ),
      ),
      alignment: Alignment.center,
      child: const LIcon('heart', size: 64, color: Colors.white, filled: true),
    );
  }
}

class _PlaylistNameEditor extends StatefulWidget {
  const _PlaylistNameEditor({
    super.key,
    required this.state,
    required this.playlist,
    required this.onChanged,
  });

  final AppState state;
  final Playlist playlist;
  final VoidCallback onChanged;

  @override
  State<_PlaylistNameEditor> createState() => _PlaylistNameEditorState();
}

class _PlaylistNameEditorState extends State<_PlaylistNameEditor> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.playlist.name);
  Timer? _saveTimer;

  @override
  void dispose() {
    _saveTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _save(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      _controller.value = TextEditingValue(
        text: widget.playlist.name,
        selection: TextSelection.collapsed(offset: widget.playlist.name.length),
      );
      return;
    }
    if (!isPermittedPlaylistName(name)) {
      widget.state.showToast('This name is not permitted.');
      _controller.value = TextEditingValue(
        text: widget.playlist.name,
        selection: TextSelection.collapsed(offset: widget.playlist.name.length),
      );
      return;
    }
    widget.playlist.name = name;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), widget.onChanged);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      onChanged: (value) {
        if (!isPermittedPlaylistName(value)) {
          _saveTimer?.cancel();
          widget.state.showToast('This name is not permitted.');
          _controller.value = TextEditingValue(
            text: widget.playlist.name,
            selection:
                TextSelection.collapsed(offset: widget.playlist.name.length),
          );
          return;
        }
        widget.playlist.name = value;
        _saveTimer?.cancel();
        _saveTimer = Timer(
          const Duration(milliseconds: 350),
          () => _save(_controller.text),
        );
      },
      onSubmitted: _save,
      onEditingComplete: () => _save(_controller.text),
      maxLines: 1,
      style: const TextStyle(
          fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: -1),
      cursorColor: ThemeScope.of(context).foreground,
      decoration: const InputDecoration(
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        isDense: true,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }
}

class PlaylistPage extends StatelessWidget {
  const PlaylistPage(
      {super.key, required this.state, required this.playlistId});
  final AppState state;
  final String playlistId;

  Future<void> _pickCover(BuildContext context, Playlist playlist) async {
    try {
      final dataUrl = await pickImageAsDataUrl(size: 640, quality: 90);
      if (dataUrl.isEmpty || !context.mounted) return;
      playlist.cover = dataUrl;
      state.save();
      state.refresh();
    } catch (error) {
      if (context.mounted) {
        state.showToast('Could not set playlist cover: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlist =
        state.playlists.where((p) => p.id == playlistId).firstOrNull;
    if (playlist == null) {
      return const EmptyState(text: 'This playlist is no longer available.');
    }
    final tracks =
        playlist.ids.map((id) => state.byId[id]).whereType<Track>().toList();
    final listKey = state.reg('playlist-$playlistId', tracks);
    final cover = playlist.cover.isNotEmpty
        ? playlist.cover
        : (tracks.map((t) => t.cover).where((c) => c.isNotEmpty).firstOrNull ??
            '');
    state.ensureCovers(tracks.take(10), priority: true);

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 60, 32, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 200,
                height: 200,
                child: CoverArt(
                  url: cover,
                  onTap: () => _pickCover(context, playlist),
                  seed: playlist.name,
                  letter: playlist.name.isEmpty
                      ? '?'
                      : playlist.name.characters.first.toUpperCase(),
                  square: true,
                  radius: 16,
                  child: playlist.cover.isNotEmpty
                      ? Positioned(
                          top: 8,
                          right: 8,
                          child: IconAction(
                            icon: 'close',
                            size: 28,
                            iconSize: 12,
                            color: Colors.white,
                            tooltip: 'Remove cover',
                            onTap: () {
                              playlist.cover = '';
                              state.save();
                              state.refresh();
                            },
                          ),
                        )
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('PLAYLIST',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4,
                            color: ThemeScope.of(context).mutedForeground)),
                    const SizedBox(height: 8),
                    _PlaylistNameEditor(
                      key: ValueKey('playlist-name-${playlist.id}'),
                      state: state,
                      playlist: playlist,
                      onChanged: () {
                        state.save();
                        state.refresh();
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                        '${tracks.length} ${plural(tracks.length, 'track', 'tracks')}',
                        style: TextStyle(
                            fontSize: 13,
                            color: ThemeScope.of(context).mutedForeground)),
                    const SizedBox(height: 16),
                    Row(children: [
                      if (tracks.isNotEmpty)
                        PlayButton(
                            label: 'Play',
                            onTap: () => state
                                .playIds(state.lists[listKey] ?? const [])),
                      const SizedBox(width: 8),
                      ChipButton(
                        label:
                            playlist.isPublic ? 'Make Private' : 'Make Public',
                        icon: playlist.isPublic ? 'lock' : 'eye',
                        ghost: true,
                        onTap: () {
                          playlist.isPublic = !playlist.isPublic;
                          state.save();
                          state.refresh();
                          state.showToast(playlist.isPublic
                              ? 'Playlist is public'
                              : 'Playlist is private');
                        },
                      ),
                      const SizedBox(width: 8),
                      IconAction(
                        icon: 'close',
                        size: 36,
                        iconSize: 16,
                        tooltip: 'Delete playlist',
                        onTap: () =>
                            deletePlaylistFlow(context, state, playlist),
                      ),
                    ]),
                  ]),
            ),
          ]),
          const SectionTitle(title: 'Tracks'),
          if (tracks.isEmpty)
            const EmptyState(
                text: 'This playlist is empty. Add tracks from the ··· menu.')
          else
            LazyTrackRows(
              state: state,
              tracks: tracks,
              rowBuilder: (context, i) {
                final track = tracks[i];
                return TrackRow(
                  track: track,
                  current: state.current?.id == track.id,
                  playing: state.playing,
                  durationText:
                      track.duration > 0 ? fmtDuration(track.duration) : '',
                  onPlay: () =>
                      state.playIds(state.lists[listKey] ?? const [], i),
                  onArtist: (name) => state.go('artist', arg: name),
                  onMenu: (position) => openTrackMenu(
                      context, state, track, position,
                      playlistId: playlist.id),
                );
              },
            ),
        ],
      ),
    );
  }
}
