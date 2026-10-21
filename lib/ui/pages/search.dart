import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import '../actions.dart';
import '../design.dart';
import '../lazy_track_rows.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.state});
  final AppState state;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _timer;
  int _queryToken = 0;
  String _query = '';
  List<Track> _found = [];
  bool _searching = false;
  String _error = '';
  bool _browsing = true;
  List<String> _browseNames = [];
  final Map<String, String> _tileImages = {};
  bool _tilesStarted = false;

  @override
  void initState() {
    super.initState();
    _browse();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final query = value.trim();
    _timer?.cancel();
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _browsing = true;
        _found = [];
        _searching = false;
        _error = '';
      });
      _browse();
      return;
    }
    setState(() {
      _query = query;
      _browsing = false;
      _searching = true;
    });
    _timer = Timer(const Duration(milliseconds: 300), () => _run(query));
  }

  void _browse() {
    final names = <String>[];
    final seen = <String>{};
    void add(String raw) {
      final key = looseKey(raw);
      if (key.isEmpty || seen.contains(key)) return;
      if (AppState.browseHidden.contains(key)) return;
      if (!widget.state.isKnownPlayable(raw)) return;
      seen.add(key);
      names.add(displayName(raw));
    }

    for (final name in widget.state.savedArtists.values) {
      add(name);
    }
    for (final taste in widget.state.tasteArtists()) {
      add(taste.name);
    }
    for (final track in widget.state.availableTracks()) {
      add(track.primary);
    }
    _browseNames = names.take(80).toList();
    if (!_tilesStarted) {
      _tilesStarted = true;
      _loadTiles();
    }
  }

  Future<void> _loadTiles() async {
    var next = 0;
    Future<void> worker() async {
      while (next < _browseNames.length) {
        final name = _browseNames[next++];
        if (!mounted) return;
        if (_tileImages.containsKey(name)) continue;
        String url = '';
        try {
          final info = await widget.state.artistInfo(name);
          url = info.banner.isNotEmpty ? info.banner : info.avatar;
          if (url.isEmpty) url = await widget.state.avatarOf(name);
        } catch (_) {
          url = '';
        }
        if (url.isNotEmpty && mounted) {
          setState(() => _tileImages[name] = url);
        }
      }
    }

    await Future.wait([worker(), worker(), worker()]);
  }

  void _tileImageFailed(String name) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tileImages.containsKey(name)) return;
      setState(() => _tileImages.remove(name));
    });
  }

  Future<void> _run(String query) async {
    final token = ++_queryToken;
    final state = widget.state;
    final key = norm(query);
    final local = state.availableTracks().where((t) {
      if (t.src.isEmpty) return false;
      return norm(t.title).contains(key) ||
          t.artists.any((a) => norm(a).contains(key));
    }).toList();
    if (mounted && token == _queryToken) {
      setState(() {
        _found = local;
        _searching = true;
        _error = '';
      });
    }
    List<Track> remote = [];
    try {
      remote = await state.searchRemote(query);
    } catch (_) {
      remote = [];
    }
    if (!mounted || token != _queryToken) return;
    final unique = <String, Track>{};
    final semantic = <String, String>{};
    String normPart(String value) =>
        norm(value).replaceAll(cachedRe(r'[^\p{L}\p{N}]', unicode: true), '');
    for (final raw in [...local, ...remote.map(_withoutCover)]) {
      final track = state.registerTrack(raw);
      final artist = track.artists
              .where((a) => !cachedRe(r'unknown artist|неизвестный исполнитель',
                      caseSensitive: false)
                  .hasMatch(a))
              .firstOrNull ??
          '';
      final semanticKey = '${normPart(artist)}|${normPart(track.title)}';
      final existingId = semantic[semanticKey];
      if (existingId != null && unique.containsKey(existingId)) {
        final existing = unique[existingId]!;
        if (existing.cover.isEmpty && track.cover.isNotEmpty) {
          existing.cover = track.cover;
        }
        if (existing.src.isEmpty && track.src.isNotEmpty) {
          existing.src = track.src;
        }
        if ((existing.album.isEmpty || existing.album == existing.title) &&
            track.album.isNotEmpty &&
            track.album != track.title) {
          existing.album = track.album;
        }
        if (existing.duration == 0 && track.duration > 0) {
          existing.duration = track.duration;
        }
        if (existing.releaseType.isEmpty && track.releaseType.isNotEmpty) {
          existing.releaseType = track.releaseType;
        }
        continue;
      }
      unique.putIfAbsent(track.id, () => track);
      semantic[semanticKey] = track.id;
    }
    var error = '';
    if (remote.isEmpty) {
      try {
        error = await state.searchErrorMessage();
      } catch (_) {
        error = '';
      }
    }
    if (!mounted || token != _queryToken) return;
    setState(() {
      _found = unique.values.toList(growable: false);
      _searching = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 18 : 32, compact ? 14 : 56, compact ? 18 : 32, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _searchBox(),
          const SizedBox(height: 8),
          if (_browsing) _browseGrid() else _results(),
        ],
      ),
    );
  }

  Widget _searchBox() {
    final light = ThemeScope.of(context).light;
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: light ? const Color(0x0D000000) : const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: light ? const Color(0x1F17181C) : const Color(0x14FFFFFF)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        LIcon(
          'search',
          size: 18,
          color: light ? const Color(0xFF686B73) : const Color(0x8CFFFFFF),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            onChanged: _onChanged,
            style: TextStyle(
                fontSize: 15, color: ThemeScope.of(context).foreground),
            cursorColor: ThemeScope.of(context).foreground,
            decoration: InputDecoration(
              hintText: 'Artist or track title',
              hintStyle: TextStyle(
                color:
                    light ? const Color(0xFF777A82) : const Color(0x73FFFFFF),
                fontSize: 15,
              ),
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
        if (_controller.text.isNotEmpty)
          GestureDetector(
            onTap: () {
              _controller.clear();
              _onChanged('');
              _focus.requestFocus();
            },
            child: const Padding(
              padding: EdgeInsets.only(left: 8),
              child: LIcon('close', size: 16, color: Color(0x73FFFFFF)),
            ),
          ),
      ]),
    );
  }

  Widget _browseGrid() {
    final names = _browseNames.where(_tileImages.containsKey).toList();
    if (names.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Center(
          child: Text('Start typing a track title or artist name',
              style: TextStyle(
                  fontSize: 14, color: ThemeScope.of(context).mutedForeground),
              textAlign: TextAlign.center),
        ),
      );
    }
    if (!mounted) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle(title: 'Browse artists'),
        LayoutBuilder(builder: (context, constraints) {
          final columns = ((constraints.maxWidth + 16) / (250 + 16))
              .floor()
              .clamp(1, 8)
              .toInt();
          final complete = names.length <= columns
              ? names.length
              : (names.length ~/ columns) * columns;
          final shown = names.take(complete).toList();
          final rows = <Widget>[];
          for (var i = 0; i < shown.length; i += columns) {
            final rowNames =
                shown.sublist(i, (i + columns).clamp(0, shown.length).toInt());
            rows.add(Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var j = 0; j < columns; j++) ...[
                  if (j > 0) const SizedBox(width: 16),
                  Expanded(
                    child: j < rowNames.length
                        ? _ArtistBrowseTile(
                            name: rowNames[j],
                            url: _tileImages[rowNames[j]] ?? '',
                            onImageError: () => _tileImageFailed(rowNames[j]),
                            onTap: () =>
                                widget.state.go('artist', arg: rowNames[j]),
                          )
                        : const SizedBox(),
                  ),
                ],
              ],
            ));
            if (i + columns < shown.length) {
              rows.add(const SizedBox(height: 16));
            }
          }
          return Column(children: rows);
        }),
      ],
    );
  }

  Widget _results() {
    final query = _query;
    final found = _found;
    final key = norm(query);
    final queryKey = looseKey(query);
    final artists = <String>[];
    final seen = <String>{};
    void addArtist(String name) {
      final id = looseKey(name);
      if (id.isEmpty || seen.contains(id)) return;
      seen.add(id);
      artists.add(name);
    }

    for (final track in found) {
      for (final artist in track.artists) {
        if (norm(artist).contains(key) ||
            (queryKey.length >= 2 && looseKey(artist).contains(queryKey))) {
          addArtist(artist);
        }
      }
    }
    final listKey = widget.state.reg('search', found);
    final groups = [
      ('album', 'Albums'),
      ('ep', 'EP'),
      ('single', 'Singles'),
    ];
    final categorizedAny =
        groups.any((g) => found.any((t) => t.releaseType == g.$1));
    final uncategorized = found
        .where((t) => !['album', 'ep', 'single'].contains(t.releaseType))
        .toList();
    final rows = <Widget>[];
    for (final group in groups) {
      final items = found.where((t) => t.releaseType == group.$1).toList();
      if (items.isEmpty) continue;
      rows.add(SectionTitle(title: group.$2));
      rows.add(
          _TrackRows(state: widget.state, tracks: items, listKey: listKey));
    }
    if (uncategorized.isNotEmpty) {
      rows.add(SectionTitle(title: categorizedAny ? 'Other tracks' : 'Tracks'));
      rows.add(_TrackRows(
          state: widget.state, tracks: uncategorized, listKey: listKey));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (artists.isNotEmpty) ...[
          const SectionTitle(title: 'Artists'),
          Wrap(
            runSpacing: 10,
            spacing: 10,
            children: [
              for (final artist in artists.take(8))
                _ArtistChip(
                  name: displayName(artist),
                  avatarUrl: () => widget.state.avatarOf(artist),
                  onTap: () => widget.state.go('artist', arg: artist),
                ),
            ],
          ),
        ],
        ...rows,
        if (found.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 34),
            child: Center(
              child: Text(
                _searching
                    ? 'Searching for tracks…'
                    : (_error.isNotEmpty ? _error : 'Nothing found'),
                style: TextStyle(
                    fontSize: 14,
                    color: ThemeScope.of(context).mutedForeground),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        if (_searching && found.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 18),
            child: Text('Looking for more tracks in the catalog…',
                style: TextStyle(fontSize: 12.5, color: Color(0x66FFFFFF))),
          ),
        if (!_searching && _error.isNotEmpty && found.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text(_error,
                style:
                    const TextStyle(fontSize: 12.5, color: Color(0x66FFFFFF))),
          ),
      ],
    );
  }
}

Track _withoutCover(Track track) => Track(
      id: track.id,
      title: track.title,
      artists: track.artists,
      album: track.album,
      src: track.src,
      duration: track.duration,
      explicit: track.explicit,
      releaseType: track.releaseType,
      source: track.source,
    );

class _TrackRows extends StatelessWidget {
  const _TrackRows(
      {required this.state, required this.tracks, required this.listKey});
  final AppState state;
  final List<Track> tracks;
  final String listKey;

  @override
  Widget build(BuildContext context) {
    final ids = tracks.map((t) => t.id).toList();
    return LazyTrackRows(
      state: state,
      tracks: tracks,
      rowBuilder: (context, i) {
        final track = tracks[i];
        return TrackRow(
          track: track,
          current: state.current?.id == track.id,
          playing: state.playing,
          durationText: track.duration > 0 ? fmtDuration(track.duration) : '',
          onPlay: () => state.playIds([...ids], i),
          onArtist: (name) => state.go('artist', arg: name),
          onMenu: (position) => openTrackMenu(context, state, track, position),
        );
      },
    );
  }
}

class _ArtistChip extends StatefulWidget {
  const _ArtistChip(
      {required this.name, required this.avatarUrl, required this.onTap});
  final String name;
  final Future<String> Function() avatarUrl;
  final VoidCallback onTap;

  @override
  State<_ArtistChip> createState() => _ArtistChipState();
}

class _ArtistChipState extends State<_ArtistChip> {
  String _url = '';

  @override
  void initState() {
    super.initState();
    widget.avatarUrl().then((url) {
      if (mounted && url.isNotEmpty) setState(() => _url = url);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 44,
          padding: const EdgeInsets.only(left: 4, right: 16),
          decoration: BoxDecoration(
            color: hovered ? const Color(0x1FFFFFFF) : const Color(0x12FFFFFF),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0x12FFFFFF)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AvatarFromUrl(
              name: widget.name,
              url: () async => _url,
              size: 34,
              fontSize: 14,
            ),
            const SizedBox(width: 10),
            Text(widget.name,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

class _ArtistBrowseTile extends StatefulWidget {
  const _ArtistBrowseTile(
      {required this.name,
      required this.url,
      required this.onTap,
      required this.onImageError});
  final String name;
  final String url;
  final VoidCallback onTap;
  final VoidCallback onImageError;

  @override
  State<_ArtistBrowseTile> createState() => _ArtistBrowseTileState();
}

class _ArtistBrowseTileState extends State<_ArtistBrowseTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hovered ? 1.025 : 1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            transform: Matrix4.translationValues(0, _hovered ? -3 : 0, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 8 / 5,
                child: Stack(fit: StackFit.expand, children: [
                  if (widget.url.isNotEmpty)
                    Stack(fit: StackFit.expand, children: [
                      ColorFiltered(
                        colorFilter: const ColorFilter.matrix([
                          0.2126,
                          0.7152,
                          0.0722,
                          0,
                          0,
                          0.2126,
                          0.7152,
                          0.0722,
                          0,
                          0,
                          0.2126,
                          0.7152,
                          0.0722,
                          0,
                          0,
                          0,
                          0,
                          0,
                          1,
                          0,
                        ]),
                        child: Image.network(
                          widget.url,
                          fit: BoxFit.cover,
                          alignment: const Alignment(0, -0.2),
                          errorBuilder: (context, error, stack) {
                            widget.onImageError();
                            return const SizedBox.expand();
                          },
                        ),
                      ),
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeOut,
                        opacity: _hovered ? 1 : 0,
                        child: Image.network(
                          widget.url,
                          fit: BoxFit.cover,
                          alignment: const Alignment(0, -0.2),
                          errorBuilder: (context, error, stack) {
                            widget.onImageError();
                            return const SizedBox.expand();
                          },
                        ),
                      ),
                    ]),
                  if (widget.url.isEmpty)
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            HSLColor.fromAHSL(
                                    1,
                                    (hashString(widget.name) % 360).toDouble(),
                                    0.4,
                                    0.26)
                                .toColor(),
                            const Color(0xFF0E0E10),
                          ],
                        ),
                      ),
                    ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          const Color(0x99000000),
                          _hovered
                              ? const Color(0xE6000000)
                              : const Color(0xB3000000),
                        ],
                        stops: const [0.35, 0.8, 1],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    bottom: 12,
                    right: 14,
                    child: Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: Colors.white),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
