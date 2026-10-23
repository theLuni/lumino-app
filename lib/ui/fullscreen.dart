import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/utils.dart';
import 'actions.dart';
import 'design.dart';

class FullscreenPlayer extends StatefulWidget {
  const FullscreenPlayer({super.key, required this.state});
  final AppState state;

  @override
  State<FullscreenPlayer> createState() => _FullscreenPlayerState();
}

class _FullscreenPlayerState extends State<FullscreenPlayer> {
  final ScrollController _scroll = ScrollController();
  String _loadedKey = '';
  LyricsResult? _lyrics;
  bool _loading = false;
  int _variant = 0;
  int _active = -1;
  final double _lineHeight = 55;
  final Map<int, GlobalKey> _lineKeys = {};
  DateTime _userScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _showLikeBurst = false;
  bool _showLikeDim = false;
  Timer? _likeBurstTimer;

  @override
  void didUpdateWidget(covariant FullscreenPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeLoad();
  }

  @override
  void initState() {
    super.initState();
    widget.state.audio.positionNotifier.addListener(_tick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoad());
  }

  @override
  void dispose() {
    widget.state.audio.positionNotifier.removeListener(_tick);
    _likeBurstTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Track? get _track => widget.state.current;

  void _maybeLoad() {
    final track = _track;
    if (track == null) return;
    if (!widget.state.fullScreen) return;
    if (_loadedKey == track.key) return;
    _loadedKey = track.key;
    _lyrics = null;
    _variant = 0;
    _active = -1;
    _showLikeBurst = false;
    _showLikeDim = false;
    _lineKeys.clear();
    _load(track);
  }

  Future<void> _load(Track track) async {
    setState(() {
      _loading = true;
      _lyrics = null;
    });
    LyricsResult result;
    try {
      result = await widget.state.lyricsService.getLyrics(track);
    } catch (_) {
      result = LyricsResult(failed: true);
    }
    if (!mounted || _track?.key != track.key) return;
    if (!track.explicit &&
        result.variants.any((variant) =>
            variant.lines.any((line) => hasExplicitLyrics(line.text)))) {
      track.explicit = true;
      widget.state.save();
    }
    setState(() {
      _lyrics = result;
      _loading = false;
      _variant = _defaultVariant(result);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _track?.key == track.key && _scroll.hasClients) {
        _scroll.jumpTo(0);
      }
    });
    widget.state.refresh();
  }

  int _defaultVariant(LyricsResult result) {
    for (var i = 0; i < result.variants.length; i++) {
      if (result.variants[i].synced) return i;
    }
    return 0;
  }

  LyricVariant? get _currentVariant {
    final result = _lyrics;
    if (result == null || result.variants.isEmpty) return null;
    if (_variant < 0 || _variant >= result.variants.length) return null;
    return result.variants[_variant];
  }

  int _indexFor(double time) {
    final variant = _currentVariant;
    if (variant == null || !variant.synced) return -1;
    var index = -1;
    for (var i = 0; i < variant.lines.length; i++) {
      final t = variant.lines[i].t;
      if (t != null && t <= time) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _tick() {
    if (!mounted) return;
    final variant = _currentVariant;
    if (variant == null || !variant.synced) return;
    final time = widget.state.position.inMilliseconds / 1000.0;
    final index = _indexFor(time);
    if (index != _active) {
      _active = index;
      _follow(index);
      if (mounted) setState(() {});
    }
  }

  void _follow(int index) {
    if (index < 0 || !_scroll.hasClients) return;
    if (DateTime.now().isBefore(_userScrollUntil)) return;
    // Lines wrap, so index * fixed height drifts further off with every wrapped
    // line. If the line is built, align the real widget; otherwise jump close
    // by estimate and then correct it on the real one.
    final built = _lineKeys[index]?.currentContext;
    if (built != null) {
      final lineBox = built.findRenderObject();
      final viewportBox =
          _scroll.position.context.storageContext.findRenderObject();
      if (lineBox is RenderBox && viewportBox is RenderBox) {
        final lineTop = lineBox.localToGlobal(Offset.zero).dy;
        final lineBottom = lineTop + lineBox.size.height;
        final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
        final viewportBottom = viewportTop + viewportBox.size.height;
        if (lineTop >= viewportTop && lineBottom <= viewportBottom) return;
      }
      Scrollable.ensureVisible(
        built,
        alignment: 0.78,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final position = _scroll.position;
    final target =
        math.max(0.0, index * _lineHeight - position.viewportDimension * 0.78);
    _scroll
        .animateTo(
      math.min(target, position.maxScrollExtent),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    )
        .then((_) {
      if (!mounted || index != _active) return;
      final ctx = _lineKeys[index]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.38,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut);
      }
    });
  }

  // Until the player has been opened once, its layout and lyrics pane are not
  // needed. Building them at app start adds unnecessary work.
  bool _everOpened = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final open = state.fullScreen;
    if (open) _everOpened = true;
    if (!_everOpened) return const SizedBox.shrink();
    final track = state.current;
    return IgnorePointer(
      ignoring: !open,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
        offset: open ? Offset.zero : const Offset(0, 1),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 260),
          opacity: open ? 1 : 0,
          child: Material(
            type: MaterialType.transparency,
            child: track == null ? const SizedBox.expand() : _content(track),
          ),
        ),
      ),
    );
  }

  Widget _content(Track track) {
    return Stack(fit: StackFit.expand, children: [
      _background(track),
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
          child: Column(children: [
            _header(track),
            const SizedBox(height: 10),
            Expanded(
              child: LayoutBuilder(builder: (context, constraints) {
                final wide = constraints.maxWidth > 760;
                final left = _left(
                    track,
                    wide
                        ? constraints.maxHeight
                        : constraints.maxHeight * 0.56);
                final right = _lyricsPane(track);
                return wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                            Expanded(flex: 46, child: left),
                            const SizedBox(width: 28),
                            Expanded(flex: 54, child: right),
                          ])
                    : Column(children: [
                        SizedBox(
                            height: constraints.maxHeight * 0.56, child: left),
                        const SizedBox(height: 20),
                        Expanded(child: right),
                      ]);
              }),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _background(Track track) {
    return RepaintBoundary(
        child: Stack(fit: StackFit.expand, children: [
      ColoredBox(color: const Color(0xFF08080A)),
      if (track.cover.isNotEmpty)
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Opacity(
            opacity: 0.9,
            child: Transform.scale(
              scale: 1.12,
              child: imageWidget(track.cover, cacheWidth: 1800),
            ),
          ),
        ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0x7008080A),
              const Color(0x50101014),
              const Color(0x99050506),
            ],
          ),
        ),
      ),
    ]));
  }

  Widget _header(Track track) {
    void startDragging() {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        windowManager.startDragging();
      }
    }

    return Row(children: [
      Transform.translate(
        offset: const Offset(0, 10),
        child: _Pill(
          onTap: widget.state.closeFull,
          child: const LIcon('chevD', size: 15, color: Colors.white),
        ),
      ),
      Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => startDragging(),
          child: const SizedBox(height: 32),
        ),
      ),
    ]);
  }

  Widget _left(Track track, double availableHeight) {
    final state = widget.state;
    final liked = state.liked.contains(track.key);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Builder(builder: (context) {
          // Everything under the cover needs ~262px; at the 900x600 minimum window
          // size a fixed 280px cover overflowed the column.
          final coverSize =
              (availableHeight - 262).clamp(96.0, 280.0).toDouble();
          return Container(
            width: coverSize,
            height: coverSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x99000000),
                    blurRadius: 60,
                    offset: Offset(0, 22))
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(fit: StackFit.expand, children: [
                CoverArt(
                  track: track,
                  radius: 14,
                  onTap: () => openTrackRelease(state, track),
                ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: _showLikeDim ? 0.30 : 0,
                  child: const IgnorePointer(
                    child: ColoredBox(color: Colors.black),
                  ),
                ),
                if (_showLikeBurst)
                  Center(
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey(track.key),
                      tween: Tween(begin: 0.45, end: 1),
                      duration: const Duration(milliseconds: 380),
                      curve: Curves.elasticOut,
                      builder: (context, scale, child) => Transform.scale(
                        scale: scale,
                        child: child,
                      ),
                      child: const LIcon('heart',
                          size: 68, color: Colors.white, filled: true),
                    ),
                  ),
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: IconAction(
                    icon: 'heart',
                    size: 30,
                    iconSize: 14,
                    filled: liked,
                    active: liked,
                    animateOnTap: true,
                    tooltip: liked
                        ? 'Remove from Liked Songs'
                        : 'Add to Liked Songs',
                    onTap: () {
                      if (!liked) {
                        setState(() {
                          _showLikeBurst = true;
                          _showLikeDim = true;
                        });
                        _likeBurstTimer?.cancel();
                        _likeBurstTimer = Timer(
                          const Duration(milliseconds: 850),
                          () {
                            if (mounted) {
                              setState(() {
                                _showLikeBurst = false;
                                _showLikeDim = false;
                              });
                            }
                          },
                        );
                      } else {
                        setState(() {
                          _showLikeBurst = false;
                          _showLikeDim = false;
                        });
                      }
                      state.toggleLike(track);
                    },
                  ),
                ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: IconAction(
                    icon: 'share',
                    size: 30,
                    iconSize: 14,
                    tooltip: 'Share Track',
                    onTap: () => shareTrackInChat(context, state, track),
                  ),
                ),
              ]),
            ),
          );
        }),
        const SizedBox(height: 18),
        SizedBox(
          height: 42,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        ArtistsText(
          artists: track.artists,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, color: Color(0x99FFFFFF)),
          onArtist: (artist) {
            state.go('artist', arg: artist);
            state.closeFull();
          },
        ),
        const SizedBox(height: 26),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: _FullProgress(state: state),
        ),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconAction(
              icon: 'shuffle',
              size: 38,
              iconSize: 17,
              active: state.shuffle,
              onTap: state.toggleShuffle),
          const SizedBox(width: 12),
          IconAction(
              icon: 'prev',
              size: 42,
              iconSize: 20,
              tooltip: 'Previous',
              onTap: state.prev),
          const SizedBox(width: 12),
          PlayMainButton(
            playing: state.playing,
            size: 56,
            iconSize: 22,
            inverted: true,
            onTap: state.togglePlay,
          ),
          const SizedBox(width: 12),
          IconAction(
              icon: 'next',
              size: 42,
              iconSize: 20,
              tooltip: 'Next',
              onTap: state.next),
          const SizedBox(width: 12),
          IconAction(
            icon: 'repeat',
            size: 38,
            iconSize: 17,
            active: state.repeat != 'off',
            dot: state.repeat == 'one',
            tooltip: 'Repeat',
            onTap: state.cycleRepeat,
          ),
        ]),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Row(children: [
            IconAction(
              icon: 'volume',
              size: 30,
              iconSize: 16,
              tooltip: 'Mute',
              onTap: () => state.setVolume(state.volume > 0 ? 0 : 0.7),
            ),
            Expanded(
              child: LSlider(
                value: state.volume,
                onChanged: (v) => state.setVolume(v),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _lyricsPane(Track track) {
    final variant = _currentVariant;
    final result = _lyrics;
    if (_loading) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Color(0x66FFFFFF))),
          SizedBox(height: 12),
          Text('Loading lyrics…',
              style: TextStyle(fontSize: 13, color: kMuted)),
        ],
      );
    }
    if (result == null || variant == null || variant.lines.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const LIcon('note', size: 34, color: Color(0x4DFFFFFF)),
          const SizedBox(height: 12),
          const Text('Lyrics not available for this track',
              style: TextStyle(fontSize: 13.5, color: kMuted),
              textAlign: TextAlign.center),
          const SizedBox(height: 14),
          if (result?.failed != true && _loadedKey.isNotEmpty)
            ChipButton(
                label: 'Try again',
                ghost: true,
                onTap: () {
                  _loadedKey = '';
                  _maybeLoad();
                }),
        ],
      );
    }
    if (!variant.synced) {
      return Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 12),
              itemCount: variant.lines.length,
              itemBuilder: (context, index) => _lyricLine(
                variant.lines[index],
                index,
                style: const TextStyle(
                    fontSize: 20,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: Color(0xCCFFFFFF)),
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification &&
                  notification.dragDetails != null) {
                _userScrollUntil =
                    DateTime.now().add(const Duration(seconds: 4));
              }
              return false;
            },
            child: ListView.builder(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 24, 12, 16),
              itemCount: variant.lines.length,
              itemBuilder: (context, index) {
                final line = variant.lines[index];
                final active = index == _active;
                final distance = _active < 0 ? 0 : (index - _active).abs();
                return _lyricLine(
                  line,
                  index,
                  key: _lineKeys.putIfAbsent(index, () => GlobalKey()),
                  active: active,
                  child: active
                      ? _activeLine(line, index, variant)
                      : Text(line.text),
                  style: TextStyle(
                    fontSize: 22,
                    height: 1.32,
                    fontWeight: FontWeight.w700,
                    color: active
                        ? Colors.white
                        : (distance <= 1
                            ? const Color(0xB3FFFFFF)
                            : const Color(0x66FFFFFF)),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _lyricLine(
    LyricLine line,
    int index, {
    Key? key,
    required TextStyle style,
    bool active = false,
    Widget? child,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 14),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: line.t == null ? null : () => widget.state.seekSeconds(line.t!),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 180),
            style: style,
            child: child ?? Text(line.text),
          ),
        ),
      ),
    );
  }

  Widget _activeLine(LyricLine line, int index, LyricVariant variant) {
    return AnimatedBuilder(
      animation: widget.state.audio.positionNotifier,
      builder: (context, child) {
        final start = line.t ?? 0;
        final next = index + 1 < variant.lines.length
            ? (variant.lines[index + 1].t ?? start + 4)
            : start + 4;
        var end = next;
        if (end - start > 8) end = start + 8;
        final progress =
            ((widget.state.position.inMilliseconds / 1000.0 - start) /
                    math.max(0.3, end - start))
                .clamp(0.0, 1.0)
                .toDouble();
        final style = DefaultTextStyle.of(context).style;
        return LayoutBuilder(
          builder: (context, constraints) {
            final visibleLines = <String>[];
            for (final paragraph in line.text.split(RegExp(r'\r?\n'))) {
              visibleLines.addAll(_wrapLyricsParagraph(
                paragraph,
                style,
                constraints.maxWidth,
                Directionality.of(context),
                MediaQuery.textScalerOf(context),
              ));
            }
            return TweenAnimationBuilder<double>(
              tween: Tween<double>(end: progress),
              duration: const Duration(milliseconds: 90),
              curve: Curves.linear,
              builder: (context, fill, child) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < visibleLines.length; i++)
                    _highlightedLyricLine(
                      visibleLines[i],
                      style,
                      (fill * visibleLines.length - i)
                          .clamp(0.0, 1.0)
                          .toDouble(),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _highlightedLyricLine(String text, TextStyle style, double fill) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        stops: [0, fill, fill, 1],
        colors: const [
          Colors.white,
          Colors.white,
          Color(0x6BFFFFFF),
          Color(0x6BFFFFFF)
        ],
      ).createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
      child: Text(text, style: style, softWrap: false),
    );
  }

  List<String> _wrapLyricsParagraph(
    String paragraph,
    TextStyle style,
    double maxWidth,
    TextDirection direction,
    TextScaler scaler,
  ) {
    if (paragraph.isEmpty || !maxWidth.isFinite) return [paragraph];
    final painter = TextPainter(
      text: TextSpan(text: paragraph, style: style),
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: maxWidth);
    final lines = <String>[];
    var offset = 0;
    while (offset < paragraph.length) {
      final boundary = painter.getLineBoundary(TextPosition(offset: offset));
      final next = boundary.end.clamp(offset + 1, paragraph.length).toInt();
      final text = paragraph.substring(offset, next).trim();
      if (text.isNotEmpty) lines.add(text);
      offset = next;
    }
    return lines.isEmpty ? [''] : lines;
  }
}

class _FullProgress extends StatefulWidget {
  const _FullProgress({required this.state});
  final AppState state;

  @override
  State<_FullProgress> createState() => _FullProgressState();
}

class _FullProgressState extends State<_FullProgress> {
  bool _dragging = false;
  double _dragSeconds = 0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.state.audio.positionNotifier,
        widget.state.audio.durationNotifier,
      ]),
      builder: (context, child) {
        final duration = widget.state.duration;
        final maxSeconds = duration.inMilliseconds / 1000.0;
        final sliderMax =
            duration.inSeconds > 0 ? duration.inSeconds.toDouble() : maxSeconds;
        final position = widget.state.position.inMilliseconds / 1000.0;
        final sliderValue =
            (_dragging ? _dragSeconds : position).clamp(0.0, sliderMax);
        return Column(children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: Colors.white,
              inactiveTrackColor: const Color(0x1AFFFFFF),
              thumbColor: Colors.white,
              overlayColor: const Color(0x1AFFFFFF),
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 6,
                elevation: 0,
                pressedElevation: 0,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: sliderValue,
              min: 0,
              max: sliderMax > 0 ? sliderMax : 1,
              divisions: duration.inSeconds > 0 ? duration.inSeconds : null,
              onChanged: sliderMax <= 0
                  ? null
                  : (seconds) => setState(() {
                        _dragging = true;
                        _dragSeconds = seconds;
                      }),
              onChangeEnd: sliderMax <= 0
                  ? null
                  : (seconds) {
                      unawaited(widget.state.seekSeconds(seconds));
                      setState(() => _dragging = false);
                    },
            ),
          ),
          Row(children: [
            Text(fmtDuration(_dragging ? _dragSeconds : position),
                style: const TextStyle(
                    fontSize: 12,
                    color: Color(0x80FFFFFF),
                    fontFeatures: [ui.FontFeature.tabularFigures()])),
            const Spacer(),
            Text(fmtDuration(maxSeconds),
                style: const TextStyle(
                    fontSize: 12,
                    color: Color(0x80FFFFFF),
                    fontFeatures: [ui.FontFeature.tabularFigures()])),
          ]),
        ]);
      },
    );
  }
}

class _Pill extends StatefulWidget {
  const _Pill({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Hide player',
      waitDuration: const Duration(milliseconds: 500),
      child: GlassPanel(
        dark: true,
        radius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: SizedBox(
          height: 32,
          child: MouseRegion(
            cursor: widget.onTap != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 34,
                height: 28,
                decoration: BoxDecoration(
                  color:
                      _hovered ? const Color(0x1AFFFFFF) : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: IconTheme(
                    data: const IconThemeData(color: Color(0xBFFFFFFF)),
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
