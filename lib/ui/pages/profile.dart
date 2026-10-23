import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import '../actions.dart';
import '../design.dart';

class PublicUserProfilePage extends StatefulWidget {
  const PublicUserProfilePage(
      {super.key, required this.state, required this.user});

  final AppState state;
  final Map<String, dynamic> user;

  @override
  State<PublicUserProfilePage> createState() => _PublicUserProfilePageState();
}

class _PublicUserProfilePageState extends State<PublicUserProfilePage> {
  late Map<String, dynamic> _profile = widget.user;
  List<Track> _likedTracks = [];
  List<Map<String, dynamic>> _publicPlaylists = [];
  int? _avatarColor;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final username = (widget.user['username'] ?? '').toString();
    if (username.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Профиль пользователя недоступен';
      });
      return;
    }
    try {
      final profile = await widget.state.auth.publicUserProfile(username);
      final tracks = asList(profile['liked_tracks'])
          .map((raw) => Track.fromJson(asMap(raw)))
          .toList();
      final publicPlaylists = asList(profile['public_playlists'])
          .whereType<Map>()
          .map(
              (raw) => raw.map((key, value) => MapEntry(key.toString(), value)))
          .toList();
      if (!mounted) return;
      setState(() {
        _profile = {...widget.user, ...profile};
        _likedTracks = tracks;
        _publicPlaylists = publicPlaylists;
        _loading = false;
      });
      widget.state.ensureCovers(tracks, priority: true);
      final avatar = (profile['avatar'] ?? '').toString();
      if (avatar.isNotEmpty) {
        final color = await widget.state.colorFor(avatar);
        if (mounted) setState(() => _avatarColor = color);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось загрузить профиль: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final display =
        (_profile['display_name'] ?? _profile['username'] ?? 'User').toString();
    final username = (_profile['username'] ?? '').toString();
    final avatar = (_profile['avatar'] ?? '').toString();
    final hue =
        (hashString(username.isEmpty ? 'user' : username) % 360).toDouble();
    final accent = _avatarColor == null
        ? HSLColor.fromAHSL(1, hue, 0.38, 0.34).toColor()
        : Color(_avatarColor!);
    final groups = <String, _LikedGroup>{};
    for (final track in _likedTracks) {
      final name =
          track.album.trim().isEmpty ? track.title : track.album.trim();
      final key = '${norm(name)}|${norm(track.primary)}';
      final group = groups.putIfAbsent(key, () => _LikedGroup(name, track));
      group.count++;
    }
    final compact = MediaQuery.sizeOf(context).width < 600;
    final size = compact ? 100.0 : 150.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 18 : 32, compact ? 18 : 60, compact ? 18 : 32, 28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(compact ? 20 : 32),
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.55, -0.95),
              radius: 1.55,
              colors: [
                Color.lerp(
                        accent,
                        ThemeScope.of(context).light
                            ? Colors.white
                            : Colors.black,
                        ThemeScope.of(context).light ? 0.72 : 0.18)!
                    .withValues(alpha: 0.92),
                ThemeScope.of(context).light
                    ? const Color(0xFFF1F2F5)
                    : const Color(0xFF121214),
                ThemeScope.of(context).light
                    ? const Color(0xFFE6E8ED)
                    : const Color(0xFF08080A),
              ],
              stops: const [0, 0.52, 1],
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent,
              ),
              clipBehavior: Clip.antiAlias,
              child: avatar.isNotEmpty
                  ? imageWidget(avatar, fit: BoxFit.cover)
                  : const Center(
                      child: LIcon('user', size: 52, color: Colors.white),
                    ),
            ),
            const SizedBox(width: 22),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Пользователь',
                        style: TextStyle(
                            fontSize: 12,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(display,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: compact ? 26 : 38,
                            fontWeight: FontWeight.w800)),
                    if (username.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('@$username',
                          style: TextStyle(
                              fontSize: 14,
                              color: ThemeScope.of(context).mutedForeground)),
                    ],
                  ]),
            ),
          ]),
        ),
        const SizedBox(height: 24),
        if (username.isNotEmpty) ...[
          ChipButton(
            label: 'Share profile',
            icon: 'share',
            ghost: true,
            onTap: () => shareProfile(context, widget.state, username),
          ),
          const SizedBox(height: 24),
        ],
        if (_publicPlaylists.isNotEmpty) ...[
          const Text('Playlists',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final playlist in _publicPlaylists)
                SizedBox(
                  width: 166,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PublicPlaylistCard(
                        playlist: playlist,
                        onTap: () => widget.state.go(
                          'public-playlist',
                          arg: {
                            ...playlist,
                            'username': username,
                            'owner': display,
                          },
                        ),
                      ),
                      const SizedBox(height: 6),
                      ChipButton(
                        label: 'Share',
                        icon: 'share',
                        ghost: true,
                        onTap: () => sharePublicPlaylist(
                          context,
                          widget.state,
                          username: username,
                          playlistId: (playlist['id'] ?? '').toString(),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],
        const Text('Liked releases',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        if (_loading)
          const Center(
              child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(strokeWidth: 2),
          ))
        else if (_error != null)
          EmptyState(text: _error!, left: true)
        else if (groups.isEmpty)
          const EmptyState(
              text: 'This user has not liked any releases yet.', left: true)
        else
          LayoutBuilder(builder: (context, constraints) {
            const gap = 16.0;
            final columns = ((constraints.maxWidth + gap) / (160 + gap))
                .floor()
                .clamp(2, 7)
                .toInt();
            final items = groups.values.toList();
            final preview = items.take(5).toList();
            final rows = <Widget>[];
            for (var i = 0; i < preview.length; i += columns) {
              final slice =
                  preview.sublist(i, (i + columns).clamp(0, preview.length));
              rows.add(Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var j = 0; j < columns; j++) ...[
                    if (j > 0) const SizedBox(width: gap),
                    Expanded(
                      child: j < slice.length
                          ? _LikedReleaseCard(
                              state: widget.state, group: slice[j])
                          : const SizedBox(),
                    ),
                  ],
                ],
              ));
              if (i + columns < preview.length) {
                rows.add(const SizedBox(height: 18));
              }
            }
            return Column(children: [
              ...rows,
              if (items.length > 5) ...[
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GhostButton(
                    label: 'Show More',
                    onTap: () =>
                        widget.state.go('liked-releases', arg: _profile),
                  ),
                ),
              ],
            ]);
          }),
      ]),
    );
  }
}

class LikedReleasesPage extends StatefulWidget {
  const LikedReleasesPage({super.key, required this.state, required this.user});

  final AppState state;
  final Map<String, dynamic> user;

  @override
  State<LikedReleasesPage> createState() => _LikedReleasesPageState();
}

class _LikedReleasesPageState extends State<LikedReleasesPage> {
  List<_LikedGroup> _groups = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final username = (widget.user['username'] ?? '').toString();
    try {
      final profile = await widget.state.auth.publicUserProfile(username);
      final grouped = <String, _LikedGroup>{};
      for (final raw in asList(profile['liked_tracks'])) {
        final track = Track.fromJson(asMap(raw));
        final name = track.album.trim().isEmpty ? track.title : track.album;
        final key = '${norm(name)}|${norm(track.primary)}';
        grouped.putIfAbsent(key, () => _LikedGroup(name, track)).count++;
      }
      if (!mounted) return;
      setState(() {
        _groups = grouped.values.toList();
        _loading = false;
      });
      widget.state.ensureCovers(_groups.map((group) => group.first).toList(),
          priority: true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load liked releases: $error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final display =
        (widget.user['display_name'] ?? widget.user['username'] ?? 'User')
            .toString();
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 18 : 32, compact ? 18 : 60, compact ? 18 : 32, 28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("$display's liked releases",
            style: TextStyle(
                fontSize: compact ? 26 : 34, fontWeight: FontWeight.w800)),
        const SizedBox(height: 20),
        if (_loading)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else if (_error != null)
          EmptyState(text: _error!, left: true)
        else if (_groups.isEmpty)
          const EmptyState(text: 'No liked releases yet.', left: true)
        else
          _LikedReleaseGrid(state: widget.state, groups: _groups),
      ]),
    );
  }
}

class _LikedReleaseGrid extends StatelessWidget {
  const _LikedReleaseGrid({required this.state, required this.groups});
  final AppState state;
  final List<_LikedGroup> groups;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          const gap = 16.0;
          final columns = ((constraints.maxWidth + gap) / (160 + gap))
              .floor()
              .clamp(2, 7)
              .toInt();
          final rows = <Widget>[];
          for (var i = 0; i < groups.length; i += columns) {
            final slice =
                groups.sublist(i, (i + columns).clamp(0, groups.length));
            rows.add(Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var j = 0; j < columns; j++) ...[
                  if (j > 0) const SizedBox(width: gap),
                  Expanded(
                    child: j < slice.length
                        ? _LikedReleaseCard(state: state, group: slice[j])
                        : const SizedBox(),
                  ),
                ],
              ],
            ));
            if (i + columns < groups.length) {
              rows.add(const SizedBox(height: 18));
            }
          }
          return Column(children: rows);
        },
      );
}

class _PublicPlaylistCard extends StatelessWidget {
  const _PublicPlaylistCard({required this.playlist, required this.onTap});
  final Map<String, dynamic> playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = (playlist['name'] ?? 'Playlist').toString();
    final cover = (playlist['cover'] ?? '').toString();
    return SizedBox(
      width: 166,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 1,
              child: cover.isEmpty
                  ? const ColoredBox(
                      color: Color(0xFF202024),
                      child: Center(
                          child: LIcon('note', size: 34, color: Colors.white)),
                    )
                  : imageWidget(cover, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 8),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class PublicPlaylistPage extends StatelessWidget {
  const PublicPlaylistPage(
      {super.key, required this.state, required this.playlist});

  final AppState state;
  final Map<String, dynamic> playlist;

  @override
  Widget build(BuildContext context) {
    final name = (playlist['name'] ?? 'Playlist').toString();
    final owner =
        (playlist['owner'] ?? playlist['username'] ?? 'User').toString();
    final cover = (playlist['cover'] ?? '').toString();
    final tracks = asList(playlist['tracks'])
        .whereType<Map>()
        .map((raw) => Track.fromJson(asMap(raw)))
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 60, 32, 28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 180,
              height: 180,
              child: cover.isEmpty
                  ? const ColoredBox(
                      color: Color(0xFF202024),
                      child: Center(
                          child: LIcon('note', size: 42, color: Colors.white)),
                    )
                  : imageWidget(cover, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('PUBLIC PLAYLIST',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                      color: ThemeScope.of(context).mutedForeground)),
              const SizedBox(height: 8),
              Text(name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 36, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('By $owner',
                  style: TextStyle(
                      fontSize: 13,
                      color: ThemeScope.of(context).mutedForeground)),
            ]),
          ),
        ]),
        const SizedBox(height: 24),
        if (tracks.isEmpty)
          const EmptyState(text: 'This playlist has no available tracks.')
        else
          Expanded(
            child: ListView.separated(
              itemCount: tracks.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final track = tracks[index];
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => openTrackRelease(state, track),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      child: Row(children: [
                        SizedBox(
                          width: 38,
                          height: 38,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: track.cover.isEmpty
                                ? const ColoredBox(
                                    color: Color(0xFF202024),
                                    child: Center(
                                        child: LIcon('note',
                                            size: 18, color: Colors.white)),
                                  )
                                : imageWidget(track.cover, fit: BoxFit.cover),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                Text(track.primary,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: ThemeScope.of(context)
                                            .mutedForeground)),
                              ]),
                        ),
                        const SizedBox(width: 8),
                        const LIcon('chevR', size: 16),
                      ]),
                    ),
                  ),
                );
              },
            ),
          ),
      ]),
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.state});
  final AppState state;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  int? _avatarColor;
  late final TextEditingController _nick =
      TextEditingController(text: widget.state.profile.nickname);
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _loadAvatarColor(widget.state.profile.avatar);
  }

  Future<void> _loadAvatarColor(String avatar) async {
    if (avatar.isEmpty) {
      if (mounted) setState(() => _avatarColor = null);
      return;
    }
    final color = await widget.state.colorFor(avatar);
    if (mounted) setState(() => _avatarColor = color);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _nick.dispose();
    super.dispose();
  }

  void _onNickChanged(String value) {
    final trimmed = value.length > 30 ? value.substring(0, 30) : value;
    widget.state.profile.nickname = trimmed;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      widget.state.save();
      widget.state.refresh();
    });
  }

  Future<void> _avatarMenu() async {
    final state = widget.state;
    final hasAvatar = state.profile.avatar.isNotEmpty;
    final choice = await showGlassDialog<String>(
      context,
      width: 280,
      padding: const EdgeInsets.all(8),
      builder: (dialogContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _option('Change photo', () async {
            Navigator.of(dialogContext).pop('change');
          }),
          if (hasAvatar)
            _option('Remove photo', () async {
              Navigator.of(dialogContext).pop('remove');
            }, danger: true),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'remove') {
      state.profile.avatar = '';
      _loadAvatarColor('');
      state.save();
      setState(() {});
      state.refresh();
      return;
    }
    final dataUrl = await pickImageAsDataUrl(size: 256, quality: 88);
    if (dataUrl.isEmpty || !mounted) return;
    state.profile.avatar = dataUrl;
    _loadAvatarColor(dataUrl);
    state.save();
    setState(() {});
    state.refresh();
  }

  Widget _option(String label, VoidCallback onTap, {bool danger = false}) {
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hovered
                ? (ThemeScope.of(context).light
                    ? const Color(0x12000000)
                    : const Color(0x1FFFFFFF))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: danger
                    ? const Color(0xFFFF7B7B)
                    : ThemeScope.of(context).foreground,
              )),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final light = ThemeScope.of(context).light;
    final nick = state.profile.nickname;
    final avatar = state.profile.avatar;
    final hue = (hashString(nick.isEmpty ? 'angel' : nick) % 360).toDouble();
    final hero = _avatarColor == null
        ? HSLColor.fromAHSL(1, hue, 0.38, 0.34).toColor()
        : Color(_avatarColor!);
    final compact = MediaQuery.sizeOf(context).width < 600;

    final liked = state
        .availableTracks()
        .where((t) => state.liked.contains(t.key))
        .toList();
    final groups = <String, _LikedGroup>{};
    for (final track in liked) {
      final name =
          track.album.trim().isEmpty ? track.title : track.album.trim();
      final key = '${norm(name)}|${norm(track.primary)}';
      final group = groups.putIfAbsent(key, () => _LikedGroup(name, track));
      group.count++;
    }
    final availableTracks = state.availableTracks();
    final profilePlaylists = state.playlists.map((playlist) {
      var cover = playlist.cover;
      if (cover.isEmpty) {
        for (final id in playlist.ids) {
          final track = availableTracks
              .where((candidate) => candidate.id == id)
              .firstOrNull;
          if (track != null && track.cover.isNotEmpty) {
            cover = track.cover;
            break;
          }
        }
      }
      return <String, dynamic>{
        'id': playlist.id,
        'name': playlist.name,
        'cover': cover,
      };
    }).toList();
    state.ensureCovers(groups.values.take(8).map((g) => g.first),
        priority: true);

    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 238),
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.55, -0.95),
                radius: 1.55,
                colors: [
                  Color.lerp(hero, light ? Colors.white : Colors.black,
                          light ? 0.72 : 0.18)!
                      .withValues(alpha: 0.92),
                  light ? const Color(0xFFF1F2F5) : const Color(0xFF121214),
                  light ? const Color(0xFFE6E8ED) : const Color(0xFF08080A),
                ],
                stops: const [0, 0.52, 1],
              ),
            ),
            padding: EdgeInsets.fromLTRB(
                compact ? 18 : 32, compact ? 18 : 60, compact ? 18 : 32, 24),
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              GestureDetector(
                onTap: _avatarMenu,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    width: compact ? 88 : 150,
                    height: compact ? 88 : 150,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x99000000),
                            blurRadius: 34,
                            offset: Offset(0, 14))
                      ],
                      color: hero,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(fit: StackFit.expand, children: [
                      if (avatar.isNotEmpty)
                        imageWidget(avatar)
                      else
                        Center(
                          child: LIcon(
                            'user',
                            size: 56,
                            color: light
                                ? const Color(0x66808088)
                                : const Color(0x66FFFFFF),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
              SizedBox(width: compact ? 14 : 26),
              Expanded(
                child: TextField(
                  controller: _nick,
                  onChanged: _onNickChanged,
                  onSubmitted: (_) => state.save(),
                  maxLength: 30,
                  style: TextStyle(
                    fontSize: compact ? 25 : 40,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.2,
                    color: ThemeScope.of(context).foreground,
                  ),
                  cursorColor: ThemeScope.of(context).foreground,
                  decoration: InputDecoration(
                    hintText: 'Add a nickname',
                    hintStyle: TextStyle(
                        fontSize: compact ? 25 : 40,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.2,
                        color: ThemeScope.of(context).light
                            ? const Color(0x66808088)
                            : const Color(0x4DFFFFFF)),
                    counterText: '',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ]),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                compact ? 18 : 32, 18, compact ? 18 : 32, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Playlists',
                    style:
                        TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                if (profilePlaylists.isEmpty)
                  const EmptyState(
                      text: 'Your playlists will appear here.', left: true)
                else
                  Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      for (final playlist in profilePlaylists)
                        _PublicPlaylistCard(
                          playlist: playlist,
                          onTap: () => state.go(
                            'playlist',
                            arg: playlist['id'] as String,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                compact ? 18 : 32, 18, compact ? 18 : 32, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Liked releases',
                    style:
                        TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                if (groups.isEmpty)
                  const EmptyState(
                      text:
                          'Tap the heart in the player to collect releases you like.',
                      left: true)
                else
                  LayoutBuilder(builder: (context, constraints) {
                    const gap = 16.0;
                    final columns = ((constraints.maxWidth + gap) / (160 + gap))
                        .floor()
                        .clamp(2, 7)
                        .toInt();
                    final items = groups.values.toList();
                    final preview = items.take(5).toList();
                    final rows = <Widget>[];
                    for (var i = 0; i < preview.length; i += columns) {
                      final slice = preview.sublist(
                          i, (i + columns).clamp(0, preview.length).toInt());
                      rows.add(Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var j = 0; j < columns; j++) ...[
                            if (j > 0) const SizedBox(width: gap),
                            Expanded(
                              child: j < slice.length
                                  ? _LikedReleaseCard(
                                      state: state, group: slice[j])
                                  : const SizedBox(),
                            ),
                          ],
                        ],
                      ));
                      if (i + columns < preview.length) {
                        rows.add(const SizedBox(height: 18));
                      }
                    }
                    return Column(children: [
                      ...rows,
                      if (items.length > 5) ...[
                        const SizedBox(height: 14),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: GhostButton(
                            label: 'Show More',
                            onTap: () => state.go(
                              'liked-releases',
                              arg: {
                                'username': state.auth.username ?? '',
                                'display_name': state.auth.displayName ?? '',
                                'avatar': state.profile.avatar,
                              },
                            ),
                          ),
                        ),
                      ],
                    ]);
                  }),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LikedGroup {
  _LikedGroup(this.name, this.first);
  final String name;
  final Track first;
  int count = 0;
}

class _LikedReleaseCard extends StatefulWidget {
  const _LikedReleaseCard({required this.state, required this.group});
  final AppState state;
  final _LikedGroup group;

  @override
  State<_LikedReleaseCard> createState() => _LikedReleaseCardState();
}

class _LikedReleaseCardState extends State<_LikedReleaseCard> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    final track = widget.group.first;
    final artist = track.primary;
    Release? release;
    try {
      release = await widget.state.releaseForTrack(track);
    } catch (_) {
      release = null;
    }
    if (!mounted) return;
    setState(() => _opening = false);
    if (!const {'profile', 'user-profile', 'liked-releases'}
        .contains(widget.state.pageName)) {
      return;
    }
    if (release != null) {
      widget.state.go('release',
          arg: ReleaseArg(
            release,
            artist: release.artistName.isNotEmpty ? release.artistName : artist,
          ));
    } else {
      widget.state.showToast("Couldn't find this release");
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final first = group.first;
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        onTap: _open,
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
              CoverArt(
                url: first.cover,
                seed: group.name,
                letter: group.name.isEmpty
                    ? '?'
                    : group.name.characters.first.toUpperCase(),
                square: true,
                radius: 12,
              ),
              if (_opening)
                const Positioned.fill(
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    ),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 10),
          Text(group.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            '${displayName(first.primary)}${group.count > 1 ? ' · ${group.count} liked' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12.5, color: ThemeScope.of(context).mutedForeground),
          ),
        ]),
      ),
    );
  }
}

/// Small helper shared with the settings page.
String formatCacheSize(int bytes) {
  if (bytes <= 0) return '0 MB';
  final mb = bytes / (1024 * 1024);
  if (mb < 1) return '${math.max(1, (bytes / 1024).round())} KB';
  return '${mb.toStringAsFixed(mb >= 100 ? 0 : 1)} MB';
}
