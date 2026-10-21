import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/utils.dart';
import '../design.dart';
import 'home.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.state});
  final AppState state;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final TextEditingController _nick =
      TextEditingController(text: widget.state.profile.nickname);
  Timer? _saveTimer;

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
      state.save();
      setState(() {});
      state.refresh();
      return;
    }
    final dataUrl = await pickImageAsDataUrl(size: 256, quality: 88);
    if (dataUrl.isEmpty || !mounted) return;
    state.profile.avatar = dataUrl;
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
    final hero = HSLColor.fromAHSL(1, hue, 0.38, 0.34).toColor();
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
                      color: HSLColor.fromAHSL(1, hue, 0.34, 0.30).toColor(),
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
                    final rows = <Widget>[];
                    for (var i = 0; i < items.length; i += columns) {
                      final slice = items.sublist(
                          i, (i + columns).clamp(0, items.length).toInt());
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
                      if (i + columns < items.length) {
                        rows.add(const SizedBox(height: 18));
                      }
                    }
                    return Column(children: rows);
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
    if (widget.state.pageName != 'profile') return;
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
