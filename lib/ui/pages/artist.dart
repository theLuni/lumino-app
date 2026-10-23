import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import '../actions.dart';
import '../design.dart';
import '../lazy_track_rows.dart';

class ArtistPage extends StatefulWidget {
  const ArtistPage({super.key, required this.state, required this.name});
  final AppState state;
  final String name;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  ArtistInfo _info = ArtistInfo.empty('');
  ReleaseIndex _index = ReleaseIndex();
  List<Track> _catalog = [];
  int? _color;
  bool _showAllTracks = false;
  bool _showAllAlbums = false;
  bool _showAllSingles = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = widget.state;
    final name = widget.name;
    var index = ReleaseIndex();
    try {
      final info = await state.artistInfo(name);
      if (mounted) setState(() => _info = info);
      final source = info.avatar.isNotEmpty ? info.avatar : info.banner;
      if (source.isNotEmpty) {
        final color = await state.colorFor(source);
        if (mounted && color != null) setState(() => _color = color);
      }
    } catch (_) {}
    try {
      index = await state.artistReleaseIndex(name);
      if (mounted) setState(() => _index = index);
    } catch (_) {}
    try {
      final catalog = await state.loadArtistCatalog([name]);
      if (mounted) {
        for (final track in catalog) {
          if (track.cover.isNotEmpty) continue;
          final topSong = index.songs
              .where((song) =>
                  compactKey(song.title) == compactKey(track.title) &&
                  sameArtist(
                    song.artist.isEmpty ? name : song.artist,
                    track.primary,
                  ))
              .firstOrNull;
          if (topSong?.cover.isNotEmpty == true) {
            track.cover = topSong!.cover;
            track.coverSource = 'deezer';
            continue;
          }
          final album = index.releases
              .where((release) =>
                  compactKey(release.name) == compactKey(track.album))
              .firstOrNull;
          if (album?.cover.isNotEmpty == true) {
            track.cover = album!.cover;
            track.coverSource = 'deezer';
          }
        }
        setState(() {
          _catalog = catalog;
          _loading = false;
        });
        state.retryMissingCovers(catalog.take(10));
        state.ensureCovers(catalog.take(10), priority: true);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Catalog order is kept: Dart's List.sort is not stable and the old comparator
  // (always 0 for track ids) shuffled the list randomly on each rebuild.
  List<Track> get _popular => _catalog
      .where((track) =>
          track.cover.isNotEmpty &&
          (!sameArtist(track.primary, 'FENDIGLOCK') ||
              !const {'ботанический сад', 'много дел'}
                  .contains(norm(track.title))))
      .take(5)
      .toList();

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final hue = (hashString(widget.name) % 360).toDouble();
    final fallback = HSLColor.fromAHSL(1, hue, 0.4, 0.28).toColor();
    final heroColor = _color != null ? Color(_color!) : fallback;
    final saved = state.savedArtists.containsKey(norm(widget.name));
    final popular = _popular;
    final albums = _index.releases.where((r) => r.type != 'single').toList();
    final singles = _index.releases.where((r) => r.type == 'single').toList();
    final hasReleases = albums.isNotEmpty || singles.isNotEmpty;

    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _hero(heroColor, saved),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 8, 32, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (popular.isNotEmpty) ...[
                  Row(children: [
                    const SectionTitle(title: 'Popular'),
                    const Spacer(),
                    if (_catalog.length > popular.length)
                      TextButton(
                        onPressed: () =>
                            setState(() => _showAllTracks = !_showAllTracks),
                        child: Text(_showAllTracks ? 'Show less' : 'Show all',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: ThemeScope.of(context).mutedForeground)),
                      ),
                  ]),
                  LazyTrackRows(
                    state: state,
                    tracks: _showAllTracks ? _catalog : popular,
                    rowBuilder: (context, i) {
                      final list = _showAllTracks ? _catalog : popular;
                      final track = list[i];
                      return TrackRow(
                        track: track,
                        current: state.current?.id == track.id,
                        playing: state.playing,
                        durationText: track.duration > 0
                            ? fmtDuration(track.duration)
                            : '',
                        onPlay: () =>
                            state.playIds(list.map((t) => t.id).toList(), i),
                        onArtist: (name) => state.go('artist', arg: name),
                        onMenu: (position) =>
                            openTrackMenu(context, state, track, position),
                        openArtwork: false,
                      );
                    },
                  ),
                ],
                if (hasReleases) ...[
                  const SectionTitle(title: 'Discography'),
                  if (albums.isNotEmpty) ...[
                    if (singles.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Text('Albums & EPs',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Color(0xCCFFFFFF))),
                      ),
                    CardsRow(children: [
                      for (final release
                          in (albums.length > 7 && !_showAllAlbums
                              ? albums.take(7)
                              : albums))
                        ReleaseCard(
                          release: release,
                          width: double.infinity,
                          subtitle:
                              '${release.kindLabel}${release.year.isNotEmpty ? ' · ${release.year}' : ''}',
                          onTap: () => state.go('release',
                              arg: ReleaseArg(release, artist: widget.name)),
                        ),
                    ]),
                    if (albums.length > 7) ...[
                      const SizedBox(height: 8),
                      ChipButton(
                        label: _showAllAlbums ? 'Show less' : 'Show all',
                        ghost: true,
                        onTap: () =>
                            setState(() => _showAllAlbums = !_showAllAlbums),
                      ),
                    ],
                  ],
                  if (singles.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.only(top: 22, bottom: 10),
                      child: Text('Singles',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xCCFFFFFF))),
                    ),
                    CardsRow(children: [
                      for (final release
                          in (singles.length > 7 && !_showAllSingles
                              ? singles.take(7)
                              : singles))
                        ReleaseCard(
                          release: release,
                          width: double.infinity,
                          subtitle:
                              'Single${release.year.isNotEmpty ? ' · ${release.year}' : ''}',
                          onTap: () => state.go('release',
                              arg: ReleaseArg(release, artist: widget.name)),
                        ),
                    ]),
                    if (singles.length > 7) ...[
                      const SizedBox(height: 8),
                      ChipButton(
                        label: _showAllSingles ? 'Show less' : 'Show all',
                        ghost: true,
                        onTap: () =>
                            setState(() => _showAllSingles = !_showAllSingles),
                      ),
                    ],
                  ],
                ],
                if (!hasReleases && _loading)
                  const Padding(
                    padding: EdgeInsets.only(top: 30),
                    child: Center(
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0x66FFFFFF))),
                  ),
                if (!hasReleases && !_loading && popular.isEmpty)
                  const EmptyState(
                      text: 'Nothing is playable from this artist yet.'),
                if (_info.bio.isNotEmpty) ...[
                  const SectionTitle(title: 'About'),
                  Text(_info.bio,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5,
                          color: ThemeScope.of(context).mutedForeground,
                          height: 1.55)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hero(Color color, bool saved) {
    final light = ThemeScope.of(context).light;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Container(
      constraints: BoxConstraints(minHeight: compact ? 250 : 292),
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.55, -0.95),
          radius: 1.55,
          colors: [
            Color.lerp(color, light ? Colors.white : Colors.black,
                    light ? 0.72 : 0.18)!
                .withValues(alpha: 0.92),
            light ? const Color(0xFFF1F2F5) : const Color(0xFF121214),
            light ? const Color(0xFFE6E8ED) : const Color(0xFF08080A),
          ],
          stops: const [0, 0.52, 1],
        ),
      ),
      padding: EdgeInsets.fromLTRB(
          compact ? 18 : 32, compact ? 18 : 60, compact ? 18 : 32, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Container(
              width: compact ? 104 : 148,
              height: compact ? 104 : 148,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x99000000),
                      blurRadius: 34,
                      offset: Offset(0, 14))
                ],
                color: color,
              ),
              clipBehavior: Clip.antiAlias,
              child: AvatarImage(
                key: ValueKey('artist-avatar-${_info.avatar}'),
                name: widget.name,
                url: _info.avatar,
                size: compact ? 104 : 148,
                fontSize: compact ? 38 : 54,
                fit: BoxFit.contain,
              ),
            ),
            SizedBox(width: compact ? 14 : 26),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Artist',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                        color: ThemeScope.of(context).mutedForeground,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      Flexible(
                        child: Text(displayName(widget.name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: compact ? 30 : 46,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1.4)),
                      ),
                      if (_info.verified) ...[
                        const SizedBox(width: 10),
                        const VerifiedIcon(size: 20)
                      ],
                    ]),
                  ]),
            ),
          ]),
          const SizedBox(height: 22),
          Row(children: [
            PlayButton(
              label: 'Play',
              onTap: () {
                final list = _catalog.isNotEmpty ? _catalog : _popular;
                if (list.isNotEmpty) {
                  widget.state.playIds(list.map((t) => t.id).toList());
                }
              },
            ),
            const SizedBox(width: 8),
            IconAction(
              icon: 'heart',
              size: 38,
              iconSize: 18,
              filled: saved,
              active: saved,
              tooltip: saved ? 'Remove from library' : 'Add artist to library',
              onTap: () {
                widget.state.toggleSavedArtist(widget.name);
                setState(() {});
              },
            ),
            const SizedBox(width: 6),
            IconAction(
              icon: 'share',
              size: 38,
              iconSize: 18,
              tooltip: 'Share',
              onTap: () => shareArtist(context, widget.state, widget.name),
            ),
            const SizedBox(width: 6),
            IconAction(
              icon: 'folderPlus',
              size: 38,
              iconSize: 18,
              tooltip: 'Folders',
              onTap: () => widget.state
                  .showToast('Folders are coming in a future version'),
            ),
          ]),
        ],
      ),
    );
  }
}

class MixPage extends StatelessWidget {
  const MixPage({super.key, required this.state, required this.listKey});
  final AppState state;
  final String listKey;

  @override
  Widget build(BuildContext context) {
    final allTracks = state.tracksForList(listKey);
    if (allTracks.isEmpty) {
      return const EmptyState(
          text:
              'This mix is no longer available. Go back to Home and open it again.');
    }
    state.ensureCovers(allTracks, priority: true);
    final tracks = allTracks.where((track) => track.cover.isNotEmpty).toList();
    if (tracks.isEmpty) {
      if (allTracks.every((track) => state.noCover.contains(track.id))) {
        return const EmptyState(
            text: 'No mix tracks have available cover art.');
      }
      return const EmptyState(text: 'Preparing daily mix covers…');
    }
    final match = cachedRe(r'mix(\d+)').firstMatch(listKey);
    final index = match == null ? 0 : int.parse(match.group(1)!);
    final title = 'Daily Mix ${index + 1}';
    final lead =
        tracks.where((t) => t.cover.isNotEmpty).firstOrNull ?? tracks.first;
    final ids = tracks.map((t) => t.id).toList();

    final compact = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 18 : 32, compact ? 18 : 60, compact ? 18 : 32, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            SizedBox(
              width: compact ? 128 : 200,
              height: compact ? 128 : 200,
              child: HoverBuilder(
                builder: (context, hovered) => MixCover(
                  index: index,
                  lead: lead,
                  seed: state.mixSeeds[listKey] ?? '',
                  artistAvatar: (name) => state.avatarOf(name),
                  collection: true,
                  colorArt: hovered,
                  showPlay: false,
                  onTap: lead.cover.isEmpty
                      ? null
                      : () => showArtwork(context, lead.cover, title),
                ),
              ),
            ),
            SizedBox(width: compact ? 14 : 24),
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
                    Text(title,
                        style: TextStyle(
                            fontSize: compact ? 28 : 40,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1)),
                    const SizedBox(height: 6),
                    Row(children: [
                      Image.asset('assets/logo.png', width: 18, height: 18),
                      const SizedBox(width: 6),
                      Text('By Lumino',
                          style: TextStyle(
                              fontSize: 12.5,
                              color: ThemeScope.of(context).mutedForeground)),
                    ]),
                    const SizedBox(height: 14),
                    PlayButton(
                        label: 'Play mix', onTap: () => state.playIds(ids)),
                  ]),
            ),
          ]),
          const SectionTitle(title: 'Tracks'),
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
                onPlay: () => state.playIds(ids, i),
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
}

class ReleasePage extends StatefulWidget {
  const ReleasePage({super.key, required this.state, required this.arg});
  final AppState state;
  final ReleaseArg arg;

  @override
  State<ReleasePage> createState() => _ReleasePageState();
}

class _ReleasePageState extends State<ReleasePage> {
  // The tracklist is fetched into a new Release object; keep it here, otherwise
  // the page keeps showing the empty original and never displays the tracks.
  Release? _filled;
  int? _color;
  bool _fillDone = false;
  Timer? _highlightTimer;
  bool _highlightActive = false;
  Release get _release => _filled ?? widget.arg.release;

  @override
  void initState() {
    super.initState();
    _highlightActive = widget.arg.highlightTrack.isNotEmpty;
    if (_highlightActive && widget.arg.release.type == 'single') {
      _scheduleSingleHighlightTimeout();
    }
    _loadColor();
    if (_release.tracks.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final release = await widget.state.fillRelease(_release);
          if (mounted && release.tracks.isNotEmpty) {
            setState(() => _filled = release);
            _ensureCovers();
            if (_highlightActive && release.type == 'single') {
              _scheduleSingleHighlightTimeout();
            }
          }
        } catch (_) {}
        if (mounted) setState(() => _fillDone = true);
      });
    } else {
      _fillDone = true;
      _ensureCovers();
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _scheduleSingleHighlightTimeout() {
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightActive = false);
    });
  }

  Future<void> _loadColor() async {
    final color = await widget.state.colorFor(_release.cover);
    if (mounted && color != null) setState(() => _color = color);
  }

  void _ensureCovers() {
    widget.state.ensureCovers(
      _release.tracks
          .where((s) => s.catalog != null)
          .map((s) => s.catalog!)
          .take(8),
      priority: true,
    );
  }

  bool _isCurrent(ReleaseSong song) {
    final current = widget.state.current;
    if (current == null) return false;
    final artist = song.artist.isNotEmpty ? song.artist : _release.artistName;
    return norm(current.title) == norm(song.title) &&
        (sameArtist(current.primary, artist) ||
            current.artists.any((a) => sameArtist(a, artist)));
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final artist = _release.artistName.isNotEmpty
        ? _release.artistName
        : widget.arg.artist;
    final year = cachedRe(r'\d{4}').firstMatch(_release.year)?.group(0) ?? '';
    final cover = _release.cover;
    final type = _release.kindLabel.toUpperCase();
    final isSingle = _release.type == 'single';
    final compact = MediaQuery.sizeOf(context).width < 600;
    final heroColor = _color == null ? null : Color(_color!);

    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 18 : 32, compact ? 18 : 60, compact ? 18 : 32, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.only(bottom: 16),
            decoration: heroColor == null
                ? null
                : BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-0.55, -0.95),
                      radius: 1.55,
                      colors: [
                        heroColor.withValues(alpha: 0.38),
                        Colors.transparent,
                      ],
                    ),
                  ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              SizedBox(
                width: compact ? 112 : 186,
                height: compact ? 112 : 186,
                child: CoverArt(
                  url: cover,
                  onTap: () => showArtwork(context, cover, _release.name),
                  seed: _release.name,
                  letter: _release.name.isEmpty
                      ? '?'
                      : _release.name.characters.first.toUpperCase(),
                  square: true,
                  radius: 14,
                ),
              ),
              SizedBox(width: compact ? 14 : 26),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(type,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.4,
                              color: ThemeScope.of(context).mutedForeground)),
                      const SizedBox(height: 6),
                      Text(_release.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: compact ? 27 : 38,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1.2)),
                      if (artist.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        GestureDetector(
                          onTap: () => state.go('artist', arg: artist),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              AvatarFromUrl(
                                key: ValueKey('release-artist-$artist'),
                                name: artist,
                                url: () => state.avatarOf(artist),
                                size: 26,
                                fontSize: 12,
                              ),
                              const SizedBox(width: 9),
                              Text(displayName(artist),
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                            ]),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        [
                          year,
                          if (_release.tracks.isNotEmpty)
                            '${_release.tracks.length} ${plural(_release.tracks.length, 'track', 'tracks')}'
                        ].where((s) => s.isNotEmpty).join(' · '),
                        style: TextStyle(
                            fontSize: 13,
                            color: ThemeScope.of(context).mutedForeground),
                      ),
                      const SizedBox(height: 16),
                      Row(children: [
                        PlayButton(
                          label: 'Play',
                          onTap: () => state.playRelease(_release, artist),
                        ),
                        const SizedBox(width: 8),
                        IconAction(
                          icon: 'share',
                          size: 38,
                          iconSize: 18,
                          tooltip: 'Share',
                          onTap: () async {
                            await copyToClipboard(
                                '${_release.name} — ${displayName(artist)}');
                            state.showToast('Link copied to clipboard');
                          },
                        ),
                      ]),
                    ]),
              ),
            ]),
          ),
          const SectionTitle(title: 'Tracks'),
          if (_release.tracks.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Center(
                child: _loadingTracks
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('Track list is unavailable for this release.',
                        style: TextStyle(
                            fontSize: 14,
                            color: ThemeScope.of(context).mutedForeground)),
              ),
            )
          else
            for (var i = 0; i < _release.tracks.length; i++)
              _ReleaseRow(
                state: state,
                number: i + 1,
                single: isSingle,
                song: _release.tracks[i],
                album: _release.name,
                fallbackArtist: artist,
                current: _isCurrent(_release.tracks[i]),
                highlighted: _highlightActive &&
                    compactKey(_release.tracks[i].title) ==
                        compactKey(widget.arg.highlightTrack),
                playing: state.playing,
                onPlay: () => state.playRelease(_release, artist,
                    start: i, strictStart: true),
                onArtist: (name) => state.go('artist', arg: name),
                onMenu: (position, track) =>
                    openTrackMenu(context, state, track, position),
              ),
        ],
      ),
    );
  }

  bool get _loadingTracks => _release.deezerId.isNotEmpty && !_fillDone;
}

class _ReleaseRow extends StatefulWidget {
  const _ReleaseRow({
    required this.state,
    required this.number,
    required this.single,
    required this.song,
    required this.album,
    required this.fallbackArtist,
    required this.current,
    required this.highlighted,
    required this.playing,
    required this.onPlay,
    required this.onArtist,
    required this.onMenu,
  });

  final AppState state;
  final int number;
  final bool single;
  final ReleaseSong song;
  final String album;
  final String fallbackArtist;
  final bool current;
  final bool highlighted;
  final bool playing;
  final VoidCallback onPlay;
  final ValueChanged<String> onArtist;
  final void Function(Offset position, Track track) onMenu;

  @override
  State<_ReleaseRow> createState() => _ReleaseRowState();
}

class _ReleaseRowState extends State<_ReleaseRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final artist = song.artist.isNotEmpty ? song.artist : widget.fallbackArtist;
    final duration = song.catalog?.duration ?? song.duration;
    final track = song.catalog ??
        Track(
          id: 'release-${hashString('${widget.album}|${song.title}|$artist')}',
          title: song.title,
          artists: [artist],
          album: song.album.isNotEmpty ? song.album : widget.album,
          cover: song.cover,
          duration: song.duration,
          releaseType: 'single',
          source: 'catalog',
        );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPlay,
        onSecondaryTapDown: (details) {
          final registered = widget.state.registerTrack(track);
          widget.onMenu(details.globalPosition, registered);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: widget.highlighted
                ? const Color(0x2EFFFFFF)
                : _hovered
                    ? const Color(0x0FFFFFFF)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            SizedBox(
              width: 38,
              child: Center(
                child: widget.current
                    ? (_hovered
                        ? Container(
                            width: 28,
                            height: 28,
                            decoration: const BoxDecoration(
                              color: Color(0xB3000000),
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: LIcon(
                              widget.playing ? 'pause' : 'play',
                              size: 14,
                              color: Colors.white,
                            ),
                          )
                        : Text('${widget.number}',
                            style: const TextStyle(
                                fontSize: 13,
                                color: Color(0x66FFFFFF),
                                fontFeatures: [
                                  ui.FontFeature.tabularFigures()
                                ])))
                    : (_hovered
                        ? const LIcon('play', size: 14, color: Colors.white)
                        : Text('${widget.number}',
                            style: const TextStyle(
                                fontSize: 13,
                                color: Color(0x66FFFFFF),
                                fontFeatures: [
                                  ui.FontFeature.tabularFigures()
                                ]))),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                        color: widget.current
                            ? Colors.white
                            : const Color(0xE6FFFFFF),
                      )),
                  const SizedBox(height: 2),
                  GestureDetector(
                    onTap:
                        artist.isEmpty ? null : () => widget.onArtist(artist),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Text(displayName(artist),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12.5,
                              color: ThemeScope.of(context).mutedForeground)),
                    ),
                  ),
                ],
              ),
            ),
            if (duration > 0)
              Text(fmtDuration(duration),
                  style: const TextStyle(
                      fontSize: 13,
                      color: Color(0x80FFFFFF),
                      fontFeatures: [ui.FontFeature.tabularFigures()])),
            const SizedBox(width: 8),
            AnimatedBuilder(
              animation: widget.state,
              builder: (context, _) {
                final liked = widget.state.liked.contains(track.key);
                return IconAction(
                  icon: 'heart',
                  size: 34,
                  iconSize: 17,
                  tooltip: liked ? 'Unlike' : 'Like',
                  active: liked,
                  filled: liked,
                  color:
                      liked ? const Color(0xFFFF5C78) : const Color(0x80FFFFFF),
                  hoverColor: const Color(0xFFFF5C78),
                  onTap: () => widget.state
                      .toggleLike(widget.state.registerTrack(track)),
                );
              },
            ),
            if (_hovered)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  final registered = widget.state.registerTrack(track);
                  widget.onMenu(details.globalPosition, registered);
                },
                child: const SizedBox(
                  width: 30,
                  height: 36,
                  child: Center(
                      child:
                          LIcon('kebab', size: 16, color: Color(0xB3FFFFFF))),
                ),
              ),
            const SizedBox(width: 8),
          ]),
        ),
      ),
    );
  }
}
