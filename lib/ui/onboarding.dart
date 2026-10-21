import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/utils.dart';
import 'design.dart';

class OnboardingView extends StatefulWidget {
  const OnboardingView({super.key, required this.state});
  final AppState state;

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  AppState get state => widget.state;

  int _step = 0;
  final Map<String, String> _picked = {};
  final TextEditingController _query = TextEditingController();
  final TextEditingController _nickname = TextEditingController();
  Timer? _debounce;
  int _token = 0;
  List<String> _results = [];
  bool _searching = false;
  String _avatar = '';

  @override
  void initState() {
    super.initState();
    _nickname.text = state.profile.nickname;
    _avatar = state.profile.avatar;
    // Список исполнителей не загружаем заранее: каталог запрашивается только при поиске.
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _nickname.dispose();
    super.dispose();
  }

  List<String> _base() {
    final out = <String>[];
    final seen = <String>{};
    for (final alias in knownArtists) {
      final key = looseKey(alias.name);
      if (key.isEmpty || seen.contains(key)) continue;
      if (state.isBrowseHidden(alias.name)) continue;
      if (state.knownPlayable != null &&
          state.knownPlayable!.isNotEmpty &&
          !state.knownPlayable!.contains(key)) {
        continue;
      }
      seen.add(key);
      out.add(alias.name);
    }
    return out;
  }

  // Picked artists are pinned to the front (in pick order), both in the base
  // grid and while searching, so: (1) tapping an artist visibly moves it to
  // the first slot and everything else shifts right, and (2) artists already
  // picked stay visible even if the current search text no longer matches
  // them, so you don't lose track of your selections while searching.
  List<String> _visible() {
    final pool = _query.text.trim().isEmpty ? _base() : _results;
    final seen = <String>{};
    final out = <String>[];
    for (final name in [..._picked.values, ...pool]) {
      final key = looseKey(name);
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      out.add(name);
    }
    return out;
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _token++;
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final token = ++_token;
    _debounce =
        Timer(const Duration(milliseconds: 350), () => _search(query, token));
  }

  Future<void> _search(String query, int token) async {
    final loose = looseKey(query);
    final key = norm(query);
    final found = <String, String>{};
    void add(String name) {
      final id = looseKey(knownArtist(name)?.name ?? name);
      if (id.isEmpty ||
          found.containsKey(id) ||
          state.isUnknownArtist(norm(name))) {
        return;
      }
      if (state.isBrowseHidden(name)) return;
      found[id] = knownArtist(name)?.name ?? name;
    }

    for (final alias in knownArtists) {
      if (state.isBrowseHidden(alias.name)) continue;
      if (state.knownPlayable != null &&
          state.knownPlayable!.isNotEmpty &&
          !state.knownPlayable!.contains(looseKey(alias.name))) {
        continue;
      }
      if (alias.names.any((n) => looseKey(n).contains(loose))) add(alias.name);
    }
    if (mounted) {
      setState(() => _results = found.values.take(24).toList());
    }
    List<Track> remote = [];
    try {
      remote = await state.searchRemote(query);
    } catch (_) {}
    if (!mounted || token != _token) return;
    for (final track in remote) {
      for (final credit in track.artists) {
        for (final name in splitCredits(credit)) {
          if (loose.length >= 2 &&
              (looseKey(name).contains(loose) || norm(name).contains(key))) {
            add(name);
          }
        }
      }
    }
    setState(() {
      _results = found.values.take(24).toList();
      _searching = false;
    });
  }

  Future<void> _pickAvatar() async {
    final url = await pickImageAsDataUrl(size: 320);
    if (url.isEmpty || !mounted) return;
    setState(() => _avatar = url);
  }

  Future<void> _finish({required bool later}) async {
    await state.finishSetup(
      artistsPicked: _picked.values.toList(),
      nickname: later ? state.profile.nickname : _nickname.text,
      avatar: later ? state.profile.avatar : _avatar,
    );
    if (!later) {
      state.profile.nickname = _nickname.text.trim();
      state.profile.avatar = _avatar;
      state.save();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xF2080808),
      child: Stack(children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF202020),
                  Color(0xFF101010),
                  Color(0xFF050505)
                ],
                stops: [0, 0.38, 1],
              ),
            ),
          ),
        ),
        Column(children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => windowManager.startDragging(),
            child: const SizedBox(height: 56, width: double.infinity),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
                  child: _step == 0
                      ? _artistsStep(context)
                      : _profileStep(context),
                ),
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _artistsStep(BuildContext context) {
    final names = _visible();
    return Column(children: [
      const Text('Pick artists you like',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: -1)),
      const SizedBox(height: 8),
      const Text('Lumino will tune your recommendations to your taste.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14.5, color: kMuted)),
      const SizedBox(height: 20),
      SizedBox(
        width: 520,
        child: GlassPanel(
          radius: 14,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            height: 46,
            child: Row(children: [
              const LIcon('search', size: 18, color: Color(0xB3FFFFFF)),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _query,
                  onChanged: _onQueryChanged,
                  style: const TextStyle(fontSize: 15, color: Colors.white),
                  cursorColor: Colors.white,
                  decoration: const InputDecoration(
                    hintText: 'Search artists by nickname',
                    hintStyle:
                        TextStyle(fontSize: 15, color: Color(0x8FFFFFFF)),
                    border: InputBorder.none,
                    isCollapsed: true,
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 16),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
          child: names.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Text(
                      _searching
                          ? 'Searching…'
                          : (state.knownPlayable == null && _query.text.isEmpty
                              ? 'Loading artists…'
                              : 'No artists found'),
                      style: const TextStyle(fontSize: 14, color: kMuted),
                    ),
                  ),
                )
              : LayoutBuilder(builder: (context, constraints) {
                  final columns = mathMax(
                      1, ((constraints.maxWidth + 14) / (150 + 14)).floor());
                  final width =
                      (constraints.maxWidth - 14 * (columns - 1)) / columns;
                  return Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      for (final name in names)
                        SizedBox(
                          key: ValueKey('onboard-${looseKey(name)}'),
                          width: width,
                          child: _OnboardArtist(
                            state: state,
                            name: name,
                            selected: _picked.containsKey(looseKey(name)),
                            onTap: () {
                              final key = looseKey(name);
                              setState(() {
                                if (_picked.containsKey(key)) {
                                  _picked.remove(key);
                                } else {
                                  _picked[key] = name;
                                }
                              });
                            },
                          ),
                        ),
                    ],
                  );
                }),
        ),
      ),
      Container(
        padding: const EdgeInsets.only(top: 14),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0x1AFFFFFF))),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              _picked.isEmpty
                  ? 'Pick at least one artist'
                  : '${_picked.length} selected',
              style: const TextStyle(fontSize: 13.5, color: kMuted),
            ),
          ),
          Opacity(
            opacity: _picked.isEmpty ? 0.5 : 1,
            child: IgnorePointer(
              ignoring: _picked.isEmpty,
              child: PlayButton(
                label: 'Continue',
                height: 42,
                icon: false,
                onTap: () => setState(() => _step = 1),
              ),
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget _profileStep(BuildContext context) {
    final canContinue = _nickname.text.trim().isNotEmpty || _avatar.isNotEmpty;
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Text('Set up your profile',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: -1)),
      const SizedBox(height: 8),
      const Text('Add a photo and a nickname. You can change them at any time.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14.5, color: kMuted)),
      const SizedBox(height: 26),
      GestureDetector(
        onTap: _pickAvatar,
        child: Stack(children: [
          Container(
            width: 168,
            height: 168,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0x12FFFFFF),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x73000000),
                    blurRadius: 40,
                    offset: Offset(0, 12))
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: _avatar.isEmpty
                ? const Center(
                    child: LIcon('user', size: 54, color: Color(0x99FFFFFF)))
                : OriginalColors(child: imageWidget(_avatar)),
          ),
          Positioned(
            right: 6,
            bottom: 6,
            child: Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                  color: Colors.white, shape: BoxShape.circle),
              child: const Center(
                  child: LIcon('camera', size: 16, color: Color(0xFF111111))),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 26),
      SizedBox(
        width: 360,
        height: 46,
        child: TextField(
          controller: _nickname,
          onChanged: (_) => setState(() {}),
          maxLength: 30,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, color: Colors.white),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: 'Your nickname',
            hintStyle: const TextStyle(fontSize: 16, color: Color(0x8FFFFFFF)),
            counterText: '',
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            filled: true,
            fillColor: const Color(0x12FFFFFF),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0x1AFFFFFF)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0x1AFFFFFF)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0x66FFFFFF)),
            ),
          ),
        ),
      ),
      const SizedBox(height: 28),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        GhostButton(
            label: 'Maybe later',
            height: 42,
            padding: 28,
            onTap: () => _finish(later: true)),
        const SizedBox(width: 12),
        Opacity(
          opacity: canContinue ? 1 : 0.5,
          child: IgnorePointer(
            ignoring: !canContinue,
            child: PlayButton(
              label: 'Continue',
              height: 42,
              icon: false,
              onTap: () => _finish(later: false),
            ),
          ),
        ),
      ]),
    ]);
  }
}

int mathMax(int a, int b) => a > b ? a : b;

class _OnboardArtist extends StatelessWidget {
  const _OnboardArtist({
    required this.state,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final AppState state;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          transform: Matrix4.translationValues(0, hovered ? -2 : 0, 0),
          padding: const EdgeInsets.fromLTRB(10, 18, 10, 14),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0x1FFFFFFF)
                : (hovered ? const Color(0x14FFFFFF) : const Color(0x0DFFFFFF)),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
          child: Stack(children: [
            SizedBox(
              width: double.infinity,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    AvatarFromUrl(
                        name: name,
                        url: () => state.avatarOf(name),
                        size: 96,
                        fontSize: 34),
                    const SizedBox(height: 12),
                    Text(displayName(name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                  ]),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: selected ? 1 : 0,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: const BoxDecoration(
                      color: Colors.white, shape: BoxShape.circle),
                  child: const Center(
                      child:
                          LIcon('check', size: 14, color: Color(0xFF111111))),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
