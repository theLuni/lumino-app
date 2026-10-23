import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import '../design.dart';

String greetingWithName(AppState state) {
  final nick = state.profile.nickname.trim();
  return nick.isEmpty ? greetingPhrase() : '${greetingPhrase()}, $nick';
}

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final pool = state.availableTracks();
    if (pool.isEmpty) {
      return _HomeWelcome(
          state: state, artists: state.savedArtists.values.toList());
    }

    final quick = pool
        .where((t) => t.cover.isNotEmpty || !state.noCover.contains(t.id))
        .take(5)
        .toList();
    state.reg('quick', quick);
    final likedTracks = pool.where((t) => state.liked.contains(t.key)).toList();
    state.reg('liked', likedTracks);
    final mixes = state.dailyMixes();
    state.ensureCovers(
      mixes.expand((mix) => mix.tracks),
      priority: true,
    );
    final taste = state.tasteArtists();
    final topKeys = taste.take(5).map((x) => x.key).toSet();
    final mineNames = taste.take(5).map((x) => x.name).toList();
    final recNames = state.recArtists
        .take(6)
        .map((c) => (c['name'] ?? '').toString())
        .where((n) => n.isNotEmpty)
        .toList();
    final skip = <String>{...mineNames, ...recNames}.map(norm).toSet();
    final trendNames = seededShuffle(
      pool
          .map((t) => t.primary)
          .toSet()
          .where((n) => !skip.contains(norm(n)))
          .toList(),
      daySeed() + 9,
    ).take(6).toList();
    state.ensureHomeReleases([...mineNames, ...recNames, ...trendNames]);
    state.ensureCovers([...quick, ...likedTracks], priority: true);

    final usedRel = <String>{};
    final mineRel = state.pickHomeReleases(mineNames, usedRel, daySeed() + 5);
    final recRel = state.pickHomeReleases(recNames, usedRel, daySeed() + 6);
    final hotRel = state.pickHomeReleases(trendNames, usedRel, daySeed() + 7);

    final mineAll = taste.isEmpty
        ? <Track>[]
        : seededShuffle(
            pool
                .where((t) =>
                    topKeys.contains(norm(t.primary)) &&
                    (t.cover.isNotEmpty || !state.noCover.contains(t.id)))
                .toList(),
            daySeed() + 5,
          );
    final mine = mineAll.take(10).toList();
    final recTracks = state.recTracks
        .where((t) => t.cover.isNotEmpty || !state.noCover.contains(t.id))
        .toList();
    final hot = [
      ...pool.skip(5),
      ...pool.take(math.min(5, pool.length)),
    ]
        .where((t) => t.cover.isNotEmpty || !state.noCover.contains(t.id))
        .toList();
    final hotKey = state.reg('hot', hot);

    final sections = <Widget>[];
    if (mineRel.isNotEmpty) {
      sections.add(SectionTitle(
          title: 'More from your artists',
          icon: const LIcon('heart', size: 20, filled: true)));
      sections.add(CardsRow(children: [
        for (final item in mineRel)
          ReleaseCard(
            release: item.release,
            width: double.infinity,
            onTap: () => state.go('release',
                arg: ReleaseArg(item.release, artist: item.artist)),
          ),
      ]));
    } else if (mine.length >= 3) {
      final mineKey = state.reg('mine', mine);
      sections.add(SectionTitle(
          title: 'More from your artists',
          icon: const LIcon('heart', size: 20, filled: true)));
      sections.add(CardsRow(children: [
        for (final track in mine)
          TrackCard(
            track: track,
            width: double.infinity,
            current: state.current?.id == track.id,
            playing: state.playing,
            onPlay: () => state
                .playIds(state.lists[mineKey] ?? const [], mine.indexOf(track))
                .then((_) => state.go('home')),
            onArtist: (name) => state.go('artist', arg: name),
          ),
      ]));
    }

    if (recRel.isNotEmpty) {
      sections.add(SectionTitle(
          title: 'Recommended for you', icon: const LIcon('spark', size: 20)));
      sections.add(CardsRow(children: [
        for (final item in recRel)
          ReleaseCard(
            release: item.release,
            width: double.infinity,
            onTap: () => state.go('release',
                arg: ReleaseArg(item.release, artist: item.artist)),
          ),
      ]));
    } else if (recTracks.isNotEmpty) {
      final recKey = state.reg('recs', recTracks);
      sections.add(SectionTitle(
          title: 'Recommended for you', icon: const LIcon('spark', size: 20)));
      sections.add(CardsRow(children: [
        for (final track in recTracks)
          TrackCard(
            track: track,
            width: double.infinity,
            current: state.current?.id == track.id,
            playing: state.playing,
            onPlay: () => state
                .playIds(
                    state.lists[recKey] ?? const [], recTracks.indexOf(track))
                .then((_) => state.go('home')),
            onArtist: (name) => state.go('artist', arg: name),
          ),
      ]));
    }

    final genreTracks =
        state.genreRecTracks.where((track) => track.cover.isNotEmpty).toList();
    if (genreTracks.isNotEmpty) {
      final genreKey = state.reg('genre-recs', genreTracks);
      sections.add(SectionTitle(
        title: state.genreRecLabel.isEmpty
            ? 'More in this genre'
            : 'More ${state.genreRecLabel}',
        icon: const LIcon('spark', size: 20),
      ));
      sections.add(CardsRow(children: [
        for (final track in genreTracks)
          TrackCard(
            track: track,
            width: double.infinity,
            current: state.current?.id == track.id,
            playing: state.playing,
            onPlay: () => state.playIds(
                state.lists[genreKey] ?? const [], genreTracks.indexOf(track)),
            onArtist: (name) => state.go('artist', arg: name),
          ),
      ]));
    }

    sections.add(SectionTitle(
        title: 'Trending now', icon: const LIcon('flame', size: 20)));
    sections.add(CardsRow(children: [
      if (hotRel.isNotEmpty)
        for (final item in hotRel)
          ReleaseCard(
            release: item.release,
            width: double.infinity,
            onTap: () => state.go('release',
                arg: ReleaseArg(item.release, artist: item.artist)),
          )
      else
        for (final track in hot)
          TrackCard(
            track: track,
            width: double.infinity,
            current: state.current?.id == track.id,
            playing: state.playing,
            onPlay: () => state.playIds(
                state.lists[hotKey] ?? const [], hot.indexOf(track)),
            onArtist: (name) => state.go('artist', arg: name),
          ),
    ]));

    final compact = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 18 : 32, compact ? 18 : 42, compact ? 18 : 32, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(greetingWithName(state),
              style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5)),
          SectionTitle(
            title: 'Quick access',
            icon: Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                  color: Color(0xFFE9E9EF), shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const LIcon('bolt', size: 12, color: Color(0xFF111111)),
            ),
          ),
          _QuickGrid(
              state: state, tracks: quick, likedCount: likedTracks.length),
          const SectionTitle(
              title: 'Daily mixes', icon: LIcon('spark', size: 20)),
          _MixesRow(state: state, mixes: mixes),
          ...sections,
        ],
      ),
    );
  }
}

class _QuickGrid extends StatelessWidget {
  const _QuickGrid(
      {required this.state, required this.tracks, required this.likedCount});
  final AppState state;
  final List<Track> tracks;
  final int likedCount;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final tiles = <Widget>[
      _LikedTile(state: state, count: likedCount),
      for (final track in tracks)
        _QuickTile(
          track: track,
          onTap: () => _openSingle(track),
        ),
    ];
    final rows = <Widget>[];
    final columns = compact ? 2 : 3;
    for (var i = 0; i < tiles.length; i += columns) {
      final slice = tiles.sublist(i, math.min(i + columns, tiles.length));
      rows.add(Row(children: [
        for (var j = 0; j < columns; j++) ...[
          if (j > 0) const SizedBox(width: 10),
          Expanded(child: j < slice.length ? slice[j] : const SizedBox()),
        ],
      ]));
      if (i + columns < tiles.length) rows.add(const SizedBox(height: 10));
    }
    return Column(children: rows);
  }

  Future<void> _openSingle(Track track) async {
    final found = await state.releaseForTrack(track);
    final release = Release(
      name: track.title,
      artistName: track.primary,
      cover: found?.cover.isNotEmpty == true ? found!.cover : track.cover,
      type: 'single',
      tracks: [
        ReleaseSong(
          title: track.title,
          artist: track.primary,
          album: track.album,
          cover: found?.cover.isNotEmpty == true ? found!.cover : track.cover,
          duration: track.duration,
          catalog: track,
        ),
      ],
    );
    state.go('release', arg: ReleaseArg(release, artist: track.primary));
  }
}

class _LikedTile extends StatefulWidget {
  const _LikedTile({required this.state, required this.count});
  final AppState state;
  final int count;

  @override
  State<_LikedTile> createState() => _LikedTileState();
}

class _LikedTileState extends State<_LikedTile> {
  @override
  Widget build(BuildContext context) {
    return _QuickShell(
      onTap: () => widget.state.go('liked'),
      leading: Container(
        width: 50,
        height: 50,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF5468D8), Color(0xFF8155CB), Color(0xFFC65391)],
          ),
        ),
        alignment: Alignment.center,
        child:
            const LIcon('heart', size: 20, color: Colors.white, filled: true),
      ),
      title: 'Liked Songs',
      subtitle: '${widget.count} ${plural(widget.count, 'song', 'songs')}',
    );
  }
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({required this.track, required this.onTap});
  final Track track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _QuickShell(
      onTap: onTap,
      leading: CoverArt(track: track, radius: 0, openArtwork: false),
      title: track.title,
      subtitle: track.artists.join(', '),
    );
  }
}

class _QuickShell extends StatefulWidget {
  const _QuickShell({
    required this.onTap,
    required this.leading,
    required this.title,
    required this.subtitle,
  });
  final VoidCallback onTap;
  final Widget leading;
  final String title;
  final String subtitle;

  @override
  State<_QuickShell> createState() => _QuickShellState();
}

class _QuickShellState extends State<_QuickShell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 56,
          decoration: BoxDecoration(
            color: _hovered ? const Color(0x1FFFFFFF) : const Color(0x12FFFFFF),
            borderRadius: BorderRadius.circular(10),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(children: [
            SizedBox(
                width: 50, height: 56, child: ClipRect(child: widget.leading)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color: ThemeScope.of(context).mutedForeground)),
                ],
              ),
            ),
            const SizedBox(width: 10),
          ]),
        ),
      ),
    );
  }
}

class _MixesRow extends StatelessWidget {
  const _MixesRow({required this.state, required this.mixes});
  final AppState state;
  final List<DailyMix> mixes;

  @override
  Widget build(BuildContext context) {
    if (mixes.isEmpty) {
      return const EmptyState(
          text:
              'Mixes need a few played tracks. Start listening and they will appear here.');
    }
    final usedCovers = <String>{};
    final cards = <Widget>[];
    for (var i = 0; i < mixes.length; i++) {
      final mix = mixes[i];
      final covered = mix.tracks.where((t) => t.cover.isNotEmpty).toList();
      final lead =
          covered.where((t) => !usedCovers.contains(t.cover)).firstOrNull ??
              (covered.isNotEmpty ? covered.first : mix.tracks.first);
      if (lead.cover.isNotEmpty) usedCovers.add(lead.cover);
      final ids = mix.tracks.map((t) => t.id).toList();
      final key = state.reg('mix$i', mix.tracks);
      state.mixSeeds[key] = mix.seed;
      cards.add(_MixCard(
        state: state,
        index: i,
        lead: lead,
        seed: mix.seed,
        ids: ids,
        keyId: key,
        playingMix: state.queueIsList(ids),
      ));
    }
    return CardsRow(children: cards);
  }
}

class _MixCard extends StatelessWidget {
  const _MixCard({
    required this.state,
    required this.index,
    required this.lead,
    required this.seed,
    required this.ids,
    required this.keyId,
    required this.playingMix,
  });
  final AppState state;
  final int index;
  final Track lead;
  final String seed;
  final List<String> ids;
  final String keyId;
  final bool playingMix;

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        onTap: () => state.go('mix', arg: keyId),
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
            child: Stack(children: [
              MixCover(
                index: index,
                lead: lead,
                seed: seed,
                artistAvatar: (name) => state.avatarOf(name),
                showPlay: hovered || playingMix,
                playing: playingMix && state.playing,
                colorArt: hovered,
                onPlay: () => state.playIds(ids),
              ),
              if (hovered || playingMix)
                Positioned(
                  right: 8,
                  top: 8,
                  child: PlayFab(
                    playing: playingMix && state.playing,
                    visible: true,
                    onTap: () =>
                        playingMix ? state.togglePlay() : state.playIds(ids),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 10),
          Text('Daily Mix ${index + 1}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Row(children: [
            Image.asset('assets/logo.png', width: 16, height: 16),
            const SizedBox(width: 5),
            Text('By Lumino',
                style: TextStyle(
                    fontSize: 12.5,
                    color: ThemeScope.of(context).mutedForeground)),
          ]),
        ]),
      ),
    );
  }
}

class _HomeWelcome extends StatelessWidget {
  const _HomeWelcome({required this.state, required this.artists});
  final AppState state;
  final List<String> artists;

  @override
  Widget build(BuildContext context) {
    final loading = artists.isNotEmpty && !state.recsDone;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 18 : 32, compact ? 18 : 42, compact ? 18 : 32, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(greetingWithName(state),
              style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5)),
          if (artists.isNotEmpty) ...[
            const SectionTitle(
                title: 'Your artists',
                icon: LIcon('heart', size: 20, filled: true)),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final name in artists.take(14))
                  SizedBox(
                    width: compact ? 104 : 132,
                    child: GestureDetector(
                      onTap: () => state.go('artist', arg: name),
                      child: Column(children: [
                        AvatarFromUrl(
                            name: name,
                            url: () => state.avatarOf(name),
                            size: compact ? 104 : 132,
                            fontSize: compact ? 36 : 44),
                        const SizedBox(height: 9),
                        Text(displayName(name),
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
                  ),
              ],
            ),
          ],
          if (loading) ...[
            const SectionTitle(
                title: 'Preparing your mixes', icon: LIcon('spark', size: 20)),
            Row(children: [
              for (var i = 0; i < 6; i++) ...[
                if (i > 0) const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AspectRatio(
                            aspectRatio: 1, child: ShimmerBox(radius: 12)),
                        SizedBox(height: 10),
                        ShimmerBox(radius: 4, height: 10),
                        SizedBox(height: 6),
                        FractionallySizedBox(
                            widthFactor: 0.6,
                            child: ShimmerBox(radius: 4, height: 10)),
                      ]),
                ),
              ],
            ]),
            Padding(
              padding: EdgeInsets.only(top: 20),
              child: Row(children: [
                SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0x8CFFFFFF))),
                SizedBox(width: 10),
                Text('Finding tracks from your artists…',
                    style: TextStyle(
                        fontSize: 13,
                        color: ThemeScope.of(context).mutedForeground)),
              ]),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: GlassPanel(
                radius: 18,
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        artists.isNotEmpty
                            ? "We couldn't load music right now"
                            : 'Find something to play',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      artists.isNotEmpty
                          ? 'The catalog may be unreachable. Check your connection and try again, or search for a track yourself.'
                          : 'Search the catalog by track title or artist name.',
                      style: TextStyle(
                          fontSize: 13.5,
                          color: ThemeScope.of(context).mutedForeground,
                          height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    Row(children: [
                      if (artists.isNotEmpty) ...[
                        PlayButton(
                            label: 'Try again', onTap: () => state.buildRecs()),
                        const SizedBox(width: 10),
                      ],
                      artists.isNotEmpty
                          ? GhostButton(
                              label: 'Open search',
                              onTap: () => state.go('search'))
                          : PlayButton(
                              label: 'Open search',
                              onTap: () => state.go('search')),
                    ]),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
