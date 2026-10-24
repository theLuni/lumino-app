import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/app_rest_mode.dart';
import '../core/models.dart';
import '../core/performance_monitor.dart';
import 'actions.dart';
import 'design.dart';
import 'fullscreen.dart';
import 'onboarding.dart';
import 'pages.dart';
import 'queue_panel.dart';

class LuminoShell extends StatefulWidget {
  const LuminoShell({
    super.key,
    required this.state,
    required this.onSignOut,
    required this.onCheckForUpdates,
  });
  final AppState state;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onCheckForUpdates;

  @override
  State<LuminoShell> createState() => _LuminoShellState();
}

class _LuminoShellState extends State<LuminoShell> with WindowListener {
  AppState get state => widget.state;
  bool get _desktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  bool _resetOpen = false;

  @override
  void initState() {
    super.initState();
    if (_desktop) windowManager.addListener(this);
    state.addListener(_onStateChanged);
    if (_desktop) _syncMaximized();
  }

  @override
  void dispose() {
    if (_desktop) windowManager.removeListener(this);
    state.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    // Every AppState change (track, toast, likes, queue...) must reach the UI.
    // The old check only rebuilt on page changes, so the player bar, toasts and
    // play/pause icon went stale.
    if (mounted) setState(() {});
  }

  Future<void> _syncMaximized() async {
    try {
      final maximized = await windowManager.isMaximized();
      if (mounted) setState(() => state.maximized = maximized);
    } catch (_) {}
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => state.maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => state.maximized = false);
  }

  // --------------------------------------------------------------- shortcuts

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final typing = _isTyping();
    final key = event.logicalKey;

    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    if (pressed.contains(LogicalKeyboardKey.controlLeft) &&
        pressed.contains(LogicalKeyboardKey.altLeft) &&
        pressed.contains(LogicalKeyboardKey.shiftLeft)) {
      _askReset();
    }

    if (key == LogicalKeyboardKey.escape) {
      if (state.fullScreen) {
        state.closeFull();
        return KeyEventResult.handled;
      }
      if (state.queueOpen) {
        state.toggleQueue();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.space && !typing) {
      state.togglePlay();
      return KeyEventResult.handled;
    }
    if (!typing && key == LogicalKeyboardKey.arrowRight) {
      state.seekSeconds(state.position.inMilliseconds / 1000.0 + 30);
      return KeyEventResult.handled;
    }
    if (!typing && key == LogicalKeyboardKey.arrowLeft) {
      state.seekSeconds(state.position.inMilliseconds / 1000.0 - 30);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _isTyping() {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (context == null) return false;
    try {
      return context.findAncestorWidgetOfExactType<EditableText>() != null ||
          context.widget is EditableText;
    } catch (_) {
      return false;
    }
  }

  Future<void> _askReset() async {
    if (_resetOpen) return;
    _resetOpen = true;
    final confirmed = await confirmDialog(
      context,
      title: 'Reset Lumino?',
      message:
          'This erases your settings, library, likes, profile and listening history. Lumino will restart with the first-time setup.',
      confirmLabel: 'Reset everything',
    );
    _resetOpen = false;
    if (!confirmed) return;
    await state.resetAll();
    await widget.onSignOut();
  }

  // ---------------------------------------------------------------- window

  Future<void> _toggleMaximize() async {
    if (!_desktop) return;
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {}
  }

  Future<void> _minimize() async {
    if (!_desktop) return;
    try {
      appRestMode.sleep();
      await windowManager.minimize();
    } catch (_) {}
  }

  Future<void> _close() async {
    if (!_desktop) return;
    try {
      await windowManager.close();
    } catch (_) {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final light = state.settings.theme == 'light';
    final black = state.settings.theme == 'black';
    final content = Focus(
      onKeyEvent: _onKey,
      child: _ShellContent(
          state: state,
          black: black,
          light: light,
          onSignOut: widget.onSignOut,
          onCheckForUpdates: widget.onCheckForUpdates,
          desktop: _desktop),
    );
    Widget stack = Stack(children: [
      Positioned.fill(child: content),
      if (state.ready && !state.setup.done)
        Positioned.fill(child: OnboardingView(state: state)),
      if (_desktop)
        Positioned(
          top: 18,
          right: 22,
          child: _WindowControls(
            state: state,
            onMinimize: _minimize,
            onMaximize: _toggleMaximize,
            onClose: _close,
          ),
        ),
      if (state.toastMessage != null)
        ToastView(
          key: ValueKey(state.toastMessage!.id),
          message: state.toastMessage!.message,
          actionLabel: state.toastMessage!.actionLabel,
          onAction: state.toastMessage!.onAction,
        ),
    ]);
    final currentTheme = Theme.of(context);
    final brightness = light ? Brightness.light : Brightness.dark;
    return Theme(
      data: currentTheme.copyWith(
        textTheme: currentTheme.textTheme.apply(fontFamily: 'SF Pro Display'),
        primaryTextTheme:
            currentTheme.primaryTextTheme.apply(fontFamily: 'SF Pro Display'),
        brightness: brightness,
        scaffoldBackgroundColor: light ? const Color(0xFFF4F5F8) : kBg,
        colorScheme: currentTheme.colorScheme.copyWith(
          brightness: brightness,
          primary: light ? const Color(0xFF3949AB) : Colors.white,
          onSurface: light ? const Color(0xFF17181C) : Colors.white,
        ),
      ),
      child: ThemeScope(
        light: light,
        black: black,
        openArtwork: state.settings.openArtwork,
        child: DefaultTextStyle.merge(
          style: const TextStyle(
            fontFamily: 'SF Pro Display',
            fontFamilyFallback: ['SF Pro Text'],
          ),
          child: PopScope<void>(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              if (state.fullScreen) {
                state.closeFull();
              } else if (state.queueOpen) {
                state.toggleQueue();
              } else if (pageHasBack(state.pageName)) {
                state.back();
              } else if (!_desktop) {
                SystemNavigator.pop();
              }
            },
            child: Material(type: MaterialType.transparency, child: stack),
          ),
        ),
      ),
    );
  }
}

class _ShellContent extends StatelessWidget {
  const _ShellContent(
      {required this.state,
      required this.black,
      required this.light,
      required this.onSignOut,
      required this.onCheckForUpdates,
      required this.desktop});

  final AppState state;
  final bool black;
  final bool light;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onCheckForUpdates;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final mobile = !desktop;
    final screen = state.fullScreen
        ? '${state.pageName}/fullscreen'
        : state.queueOpen
            ? '${state.pageName}/queue'
            : state.pageName;
    PerformanceMonitor.instance.setScreen(screen);
    return Stack(children: [
      Positioned.fill(
          child: RepaintBoundary(child: _Ambient(black: black, light: light))),
      if (mobile)
        Positioned.fill(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              child: Column(children: [
                Expanded(
                    child: _MainPanel(
                        state: state,
                        light: light,
                        onSignOut: onSignOut,
                        onCheckForUpdates: onCheckForUpdates,
                        desktop: desktop)),
                if (state.current != null) ...[
                  const SizedBox(height: 8),
                  _MobilePlayerBar(state: state),
                ],
                const SizedBox(height: 6),
                _MobileNavBar(state: state),
              ]),
            ),
          ),
        )
      else
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ShelfSidebar(
                  state: state,
                  black: black,
                  light: light,
                  onSignOut: onSignOut),
              const SizedBox(width: 6),
              Expanded(
                child: Column(children: [
                  Expanded(
                      child: _MainPanel(
                          state: state,
                          light: light,
                          onSignOut: onSignOut,
                          onCheckForUpdates: onCheckForUpdates,
                          desktop: desktop)),
                  const SizedBox(height: 6),
                  _PlayerBar(state: state),
                ]),
              ),
            ]),
          ),
        ),
      QueuePanel(state: state, mobile: mobile),
      Positioned.fill(child: FullscreenPlayer(state: state)),
    ]);
  }
}

class _MobileNavBar extends StatelessWidget {
  const _MobileNavBar({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final light = ThemeScope.of(context).light;
    const pages = [
      ('home', 'home', 'Home'),
      ('search', 'search', 'Search'),
      ('library', 'library', 'Library'),
      ('chats', 'chats', 'Chats'),
      ('profile', 'user', 'Profile'),
      ('settings', 'gear', 'Settings'),
    ];
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: light ? const Color(0xF8FFFFFF) : const Color(0xF20D0D0F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: light ? const Color(0x1F17181C) : const Color(0x14FFFFFF)),
      ),
      child: Row(
        children: [
          for (final page in pages)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => state.navTo(page.$1),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    LIcon(
                      page.$2,
                      size: 20,
                      color: state.pageName == page.$1
                          ? ThemeScope.of(context).foreground
                          : ThemeScope.of(context).mutedForeground,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      page.$3,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: state.pageName == page.$1
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: state.pageName == page.$1
                            ? ThemeScope.of(context).foreground
                            : ThemeScope.of(context).mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MobilePlayerBar extends StatelessWidget {
  const _MobilePlayerBar({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final track = state.current;
    if (track == null) return const SizedBox.shrink();
    return SizedBox(
      height: 66,
      child: GlassPanel(
        dark: true,
        radius: 14,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: Stack(
            children: [
              Positioned.fill(child: _PlayerProgress(state: state)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                child: Row(
                  children: [
                    CoverArt(
                        track: track,
                        size: 44,
                        radius: 7,
                        onTap: state.openFull),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => openTrackRelease(state, track),
                            child: Text(track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(height: 2),
                          ArtistsText(
                            artists: track.artists,
                            maxLines: 1,
                            onArtist: (name) => state.go('artist', arg: name),
                            style: TextStyle(
                                fontSize: 11,
                                color: ThemeScope.of(context).mutedForeground),
                          ),
                        ],
                      ),
                    ),
                    IconAction(
                      icon: 'prev',
                      size: 32,
                      iconSize: 17,
                      tooltip: 'Previous',
                      onTap: state.prev,
                    ),
                    PlayMainButton(
                      playing: state.playing,
                      size: 38,
                      iconSize: 17,
                      inverted: true,
                      onTap: state.togglePlay,
                    ),
                    IconAction(
                      icon: 'next',
                      size: 32,
                      iconSize: 17,
                      tooltip: 'Next',
                      onTap: () => state.next(),
                    ),
                    IconAction(
                      icon: 'share',
                      size: 30,
                      iconSize: 16,
                      tooltip: 'Share Track',
                      onTap: () => shareTrackInChat(context, state, track),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Ambient extends StatelessWidget {
  const _Ambient({required this.black, required this.light});
  final bool black;
  final bool light;

  @override
  Widget build(BuildContext context) {
    if (black) return const ColoredBox(color: Colors.black);
    if (light) {
      return const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF4F5F8), Color(0xFFE7E9EE), Color(0xFFD9DCE3)],
          ),
        ),
      );
    }
    final size = MediaQuery.of(context).size;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF202020), Color(0xFF101010), Color(0xFF050505)],
          stops: [0, 0.38, 1],
        ),
      ),
      child: ClipRect(
        child: Stack(children: [
          _Blob(
            size: size.width * 0.6,
            color: const Color(0x45383838),
            left: -size.width * 0.11,
            top: -size.width * 0.17,
          ),
          _Blob(
            size: size.width * 0.6,
            color: const Color(0x38202020),
            left: size.width * 0.71,
            top: size.height * 0.14,
          ),
          _Blob(
            size: size.width * 0.6,
            color: const Color(0x4D111111),
            left: size.width * 0.175,
            top: size.height - size.width * 0.33,
          ),
        ]),
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({
    required this.size,
    required this.color,
    required this.left,
    required this.top,
  });
  final double size;
  final Color color;
  final double left;
  final double top;

  @override
  Widget build(BuildContext context) {
    // Use gradients for soft ambient lighting without a costly full-window blur.
    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient:
                RadialGradient(colors: [color, color.withValues(alpha: 0)]),
          ),
        ),
      ),
    );
  }
}

class ShelfSidebar extends StatelessWidget {
  const ShelfSidebar(
      {super.key,
      required this.state,
      required this.onSignOut,
      this.black = false,
      this.light = false});
  final AppState state;
  final Future<void> Function() onSignOut;
  final bool black;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final pages = [
      ['home', 'home', 'Home'],
      ['search', 'search', 'Search'],
      ['library', 'library', 'Library'],
      ['chats', 'chats', 'Chats'],
      ['settings', 'gear', 'Settings'],
    ];
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        width: 62,
        padding: const EdgeInsets.only(top: 14, bottom: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: black ? Colors.black : null,
          gradient: black
              ? null
              : light
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xF8FFFFFF), Color(0xF1F0F1F4)],
                    )
                  : const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xF2141416), Color(0xF7050505)],
                    ),
          border: Border.all(
              color: light ? const Color(0x1F17181C) : const Color(0x0FFFFFFF)),
        ),
        child: Column(children: [
          Tooltip(
            message: 'About Lumino',
            waitDuration: const Duration(milliseconds: 500),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: GestureDetector(
                onDoubleTap: () => _showAbout(context, state),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: Image.asset('assets/logo.png', fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(children: [
              for (final page in pages) ...[
                _NavButton(
                  icon: page[1],
                  title: page[2],
                  active: state.pageName == page[0],
                  light: light,
                  onTap: () => state.navTo(page[0]),
                ),
                if (page[0] != 'settings') const SizedBox(height: 8),
              ],
            ]),
          ),
          _ProfileButton(state: state),
          const SizedBox(height: 8),
          _SignOutButton(onSignOut: onSignOut, light: light),
        ]),
      ),
    );
  }
}

class _SignOutButton extends StatelessWidget {
  const _SignOutButton({required this.onSignOut, required this.light});
  final Future<void> Function() onSignOut;
  final bool light;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Sign out',
      waitDuration: const Duration(milliseconds: 500),
      child: IconAction(
        icon: 'exit',
        size: 42,
        iconSize: 20,
        color: light ? const Color(0xFF555555) : const Color(0xB3FFFFFF),
        hoverColor: light ? const Color(0x12000000) : const Color(0x12FFFFFF),
        onTap: () async {
          final confirmed = await confirmDialog(
            context,
            title: 'Sign out?',
            message: 'You can sign back in to access your library.',
            confirmLabel: 'Sign out',
          );
          if (confirmed) await onSignOut();
        },
      ),
    );
  }
}

Future<void> _showAbout(BuildContext context, AppState state) {
  return showGlassDialog<void>(
    context,
    width: 360,
    builder: (dialogContext) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Lumino',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('Version 0.3.0',
            style: TextStyle(
                fontSize: 13, color: ThemeScope.of(context).mutedForeground)),
        const SizedBox(height: 18),
        const Text('Developers',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () =>
              _openDeveloper(context, state, 'https://theluni.ru/'),
          child: const Text('theLuni'),
        ),
        TextButton(
          onPressed: () =>
              _openDeveloper(context, state, 'https://github.com/lomtikkk'),
          child: const Text('lomtikkk'),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ),
      ],
    ),
  );
}

Future<void> _openDeveloper(
    BuildContext context, AppState state, String url) async {
  final opened = await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  );
  if (!opened && context.mounted) {
    state.showToast('Could not open the developer page');
  }
}

class _NavButton extends StatefulWidget {
  const _NavButton(
      {required this.icon,
      required this.title,
      required this.active,
      required this.light,
      required this.onTap});
  final String icon;
  final String title;
  final bool active;
  final bool light;
  final VoidCallback onTap;

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.title,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: widget.active
                  ? (widget.light
                      ? const Color(0x1517181C)
                      : const Color(0x1AFFFFFF))
                  : (_hovered
                      ? (widget.light
                          ? const Color(0x0D17181C)
                          : const Color(0x12FFFFFF))
                      : Colors.transparent),
              borderRadius: BorderRadius.circular(12),
              boxShadow: widget.active
                  ? const [
                      BoxShadow(
                          color: Color(0x1FFFFFFF),
                          offset: Offset(0, 1),
                          blurRadius: 0,
                          spreadRadius: 1)
                    ]
                  : null,
            ),
            child: Center(
              child: LIcon(
                widget.icon,
                size: 22,
                color: widget.light
                    ? (widget.active || _hovered
                        ? const Color(0xFF17181C)
                        : const Color(0xFF777A82))
                    : (widget.active || _hovered
                        ? Colors.white
                        : const Color(0x73FFFFFF)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileButton extends StatelessWidget {
  const _ProfileButton({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final active = state.pageName == 'profile';
    final avatar = state.profile.avatar;
    return Tooltip(
      message: 'Profile',
      waitDuration: const Duration(milliseconds: 500),
      child: HoverBuilder(
        builder: (context, hovered) => GestureDetector(
          onTap: () => state.navTo('profile'),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 42,
            height: 42,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: active
                  ? const Color(0x1AFFFFFF)
                  : (hovered ? const Color(0x12FFFFFF) : Colors.transparent),
              borderRadius: BorderRadius.circular(12),
            ),
            child: avatar.isEmpty
                ? Center(
                    child: LIcon('user',
                        size: 22,
                        color: active || hovered
                            ? Colors.white
                            : const Color(0x73FFFFFF)),
                  )
                : Padding(
                    padding: const EdgeInsets.all(5),
                    child: ClipOval(
                      child: OriginalColors(child: imageWidget(avatar)),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _MainPanel extends StatefulWidget {
  const _MainPanel(
      {required this.state,
      required this.light,
      required this.onSignOut,
      required this.onCheckForUpdates,
      required this.desktop});
  final AppState state;
  final bool light;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onCheckForUpdates;
  final bool desktop;

  @override
  State<_MainPanel> createState() => _MainPanelState();
}

class _MainPanelState extends State<_MainPanel> {
  AppState get state => widget.state;
  final ScrollController _scroll = ScrollController();
  late String _identity = pageIdentity(state);

  @override
  void didUpdateWidget(covariant _MainPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identity = pageIdentity(state);
    if (identity != _identity) {
      _identity = identity;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mobile = !widget.desktop;
    return Container(
      decoration: BoxDecoration(
        color: widget.light ? const Color(0xF7FAFAFC) : const Color(0xE6080808),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: widget.light
                ? const Color(0x1F17181C)
                : const Color(0x0FFFFFFF)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        Positioned.fill(
          child: state.pageName == 'chats'
              ? Padding(
                  padding: EdgeInsets.only(top: mobile ? 44 : 50),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    child: buildPage(
                      state,
                      onSignOut: widget.onSignOut,
                      onCheckForUpdates: widget.onCheckForUpdates,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  controller: _scroll,
                  padding: EdgeInsets.only(top: mobile ? 44 : 0, bottom: 20),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeIn,
                    // Default layout centres the children vertically: while the old
                    // (taller) page fades out, a shorter new page was shifted down.
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topCenter,
                      children: [...previous, if (current != null) current],
                    ),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                                begin: const Offset(0, 0.012), end: Offset.zero)
                            .animate(animation),
                        child: child,
                      ),
                    ),
                    child: buildPage(
                      state,
                      onSignOut: widget.onSignOut,
                      onCheckForUpdates: widget.onCheckForUpdates,
                    ),
                  ),
                ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: 50,
          child: _TopBar(state: state, scroll: _scroll, mobile: mobile),
        ),
      ]),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar(
      {required this.state, required this.scroll, required this.mobile});
  final AppState state;
  final ScrollController scroll;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: scroll,
      builder: (context, _) {
        final back = pageHasBack(state.pageName) &&
            !(state.pageName == 'release' &&
                scroll.hasClients &&
                scroll.offset > 12);
        return Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent && scroll.hasClients) {
              scroll.jumpTo((scroll.offset + event.scrollDelta.dy)
                  .clamp(0.0, scroll.position.maxScrollExtent)
                  .toDouble());
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: mobile ? null : (_) => windowManager.startDragging(),
            onDoubleTap: mobile
                ? null
                : () async {
                    if (await windowManager.isMaximized()) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  },
            child: Padding(
              padding: EdgeInsets.only(
                  left: mobile ? 14 : 24,
                  right: mobile ? 14 : 170,
                  top: mobile ? 5 : 9),
              child: Row(children: [
                if (mobile)
                  if (back)
                    TapArea(
                      onTap: state.back,
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: ThemeScope.of(context).light
                              ? const Color(0x12000000)
                              : const Color(0x12FFFFFF),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: const LIcon('back', size: 17),
                      ),
                    )
                  else
                    SizedBox(
                      width: 34,
                      height: 34,
                      child:
                          Image.asset('assets/logo.png', fit: BoxFit.contain),
                    ),
                if (mobile) ...[
                  const SizedBox(width: 10),
                  Text(
                    _mobilePageTitle(state.pageName),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ],
                if (!mobile && back)
                  TapArea(
                    onTap: state.back,
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: ThemeScope.of(context).light
                            ? const Color(0x12000000)
                            : const Color(0x12FFFFFF),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const LIcon('back', size: 16),
                        const SizedBox(width: 8),
                        Text(
                          'Back',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: ThemeScope.of(context).foreground,
                          ),
                        ),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

String _mobilePageTitle(String pageName) => switch (pageName) {
      'home' => 'Lumino',
      'search' => 'Search',
      'library' => 'Library',
      'settings' => 'Settings',
      'profile' => 'Profile',
      'artist' => 'Artist',
      'release' => 'Release',
      'playlist' => 'Playlist',
      'liked' => 'Liked Songs',
      'mix' => 'Mix',
      _ => 'Lumino',
    };

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final track = state.current;
    final liked = track != null && state.liked.contains(track.key);
    return AnimatedSlide(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      offset: track == null ? const Offset(0, 1.2) : Offset.zero,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 350),
        opacity: track == null ? 0 : 1,
        child: IgnorePointer(
          ignoring: track == null,
          child: SizedBox(
            height: 76,
            child: GlassPanel(
              dark: true,
              radius: 14,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(13),
                child: Stack(children: [
                  Positioned.fill(child: _PlayerProgress(state: state)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(children: [
                      Expanded(
                        child: _PlayerLeft(
                            state: state, track: track, liked: liked),
                      ),
                      _PlayerCenter(state: state),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: _PlayerRight(state: state),
                        ),
                      ),
                    ]),
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

class _PlayerProgress extends StatefulWidget {
  const _PlayerProgress({required this.state});
  final AppState state;

  @override
  State<_PlayerProgress> createState() => _PlayerProgressState();
}

class _PlayerProgressState extends State<_PlayerProgress> {
  bool _dragging = false;
  double _fraction = 0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.state.audio.positionNotifier,
        widget.state.audio.durationNotifier,
      ]),
      builder: (context, child) {
        final duration = widget.state.duration.inMilliseconds;
        final position = widget.state.position.inMilliseconds;
        final value = _dragging
            ? _fraction
            : duration > 0
                ? (position / duration).clamp(0.0, 1.0)
                : 0.0;
        void update(Offset local, double width) {
          if (width <= 0) return;
          setState(() {
            _dragging = true;
            _fraction = (local.dx / width).clamp(0.0, 1.0).toDouble();
          });
        }

        return LayoutBuilder(builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (details) =>
                update(details.localPosition, constraints.maxWidth),
            onHorizontalDragUpdate: (details) =>
                update(details.localPosition, constraints.maxWidth),
            onHorizontalDragEnd: (_) {
              widget.state.seekToFraction(_fraction);
              setState(() => _dragging = false);
            },
            onHorizontalDragCancel: () => setState(() => _dragging = false),
            onTapUp: (details) {
              final fraction = (details.localPosition.dx / constraints.maxWidth)
                  .clamp(0.0, 1.0)
                  .toDouble();
              widget.state.seekToFraction(fraction);
            },
            child: SizedBox.expand(
              child: Align(
                alignment: Alignment.centerLeft,
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: value),
                  duration: _dragging
                      ? Duration.zero
                      : const Duration(milliseconds: 80),
                  curve: Curves.linear,
                  builder: (context, progress, child) => FractionallySizedBox(
                    widthFactor: progress,
                    heightFactor: 1,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Color(0x376E6E72),
                            Color(0x376E6E72),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        });
      },
    );
  }
}

class _PlayerLeft extends StatelessWidget {
  const _PlayerLeft(
      {required this.state, required this.track, required this.liked});
  final AppState state;
  final Track? track;
  final bool liked;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      if (track != null)
        GestureDetector(
          onTap: state.openFull,
          child: CoverArt(
              track: track, size: 40, radius: 6, onTap: state.openFull),
        ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: track == null
                    ? null
                    : () => openTrackRelease(state, track!),
                child: Text(track?.title ?? 'Choose a track',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: track == null
                  ? Text('Choose a track',
                      style: TextStyle(
                          fontSize: 12,
                          color: ThemeScope.of(context).mutedForeground))
                  : ArtistsText(
                      artists: track!.artists,
                      onArtist: (name) => state.go('artist', arg: name),
                      style: TextStyle(
                        fontSize: 12,
                        color: ThemeScope.of(context).mutedForeground,
                        height: 1.2,
                      ),
                    ),
            ),
          ],
        ),
      ),
      if (track != null)
        IconAction(
          icon: 'heart',
          size: 34,
          iconSize: 18,
          color: liked ? Colors.white : const Color(0x8CFFFFFF),
          filled: liked,
          animateOnTap: true,
          onTap: () => state.toggleLike(track),
          tooltip: 'Like',
        ),
    ]);
  }
}

class _PlayerCenter extends StatelessWidget {
  const _PlayerCenter({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconAction(
        icon: 'prev',
        size: 34,
        iconSize: 20,
        onTap: state.prev,
        tooltip: 'Previous',
        color: const Color(0x8CFFFFFF),
        filled: true,
      ),
      const SizedBox(width: 14),
      PlayMainButton(
        playing: state.playing,
        size: 40,
        iconSize: 18,
        inverted: true,
        onTap: state.togglePlay,
      ),
      const SizedBox(width: 14),
      IconAction(
        icon: 'next',
        size: 34,
        iconSize: 20,
        onTap: () => state.next(),
        tooltip: 'Next',
        color: const Color(0x8CFFFFFF),
        filled: true,
      ),
    ]);
  }
}

class _PlayerRight extends StatelessWidget {
  const _PlayerRight({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x0FFFFFFF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconAction(
          icon: 'shuffle',
          size: 34,
          iconSize: 18,
          color: const Color(0x8CFFFFFF),
          active: state.shuffle,
          dot: state.shuffle,
          onTap: state.toggleShuffle,
          tooltip: 'Shuffle',
        ),
        IconAction(
          icon: 'repeat',
          size: 34,
          iconSize: 18,
          color: const Color(0x8CFFFFFF),
          active: state.repeat != 'off',
          dot: state.repeat != 'off',
          onTap: state.cycleRepeat,
          tooltip: 'Repeat',
        ),
        _VolumeControl(state: state),
        Container(
          width: 1,
          height: 18,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          color: const Color(0x24FFFFFF),
        ),
        IconAction(
          icon: 'expand',
          size: 34,
          iconSize: 18,
          onTap: state.openFull,
          tooltip: 'Full-screen player',
        ),
        IconAction(
          icon: 'panel',
          size: 34,
          iconSize: 18,
          active: state.queueOpen,
          onTap: state.toggleQueue,
          tooltip: 'Queue',
        ),
      ]),
    );
  }
}

class _VolumeControl extends StatefulWidget {
  const _VolumeControl({required this.state});
  final AppState state;

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: SizedBox(
            width: _hovered ? 70 : 0,
            height: 20,
            child: _hovered
                ? Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: LSlider(
                      value: widget.state.volume,
                      onChanged: (value) => widget.state.setVolume(value),
                    ),
                  )
                : null,
          ),
        ),
        IconAction(
          icon: 'volume',
          size: 34,
          iconSize: 18,
          onTap: () =>
              widget.state.setVolume(widget.state.volume > 0 ? 0 : 0.7),
          tooltip: 'Volume',
        ),
      ]),
    );
  }
}

class _WindowControls extends StatelessWidget {
  const _WindowControls({
    required this.state,
    required this.onMinimize,
    required this.onMaximize,
    required this.onClose,
  });

  final AppState state;
  final VoidCallback onMinimize;
  final VoidCallback onMaximize;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      dark: true,
      radius: 10,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        height: 32,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _WindowButton(icon: 'min', tooltip: 'Minimize', onTap: onMinimize),
          _WindowButton(
            icon: state.maximized ? 'restore' : 'max',
            tooltip: 'Maximize',
            onTap: onMaximize,
          ),
          _WindowButton(
              icon: 'close', tooltip: 'Close', onTap: onClose, close: true),
        ]),
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.close = false,
  });

  final String icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool close;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final light = ThemeScope.of(context).light;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 34,
            height: 28,
            decoration: BoxDecoration(
              color: _hovered
                  ? (widget.close
                      ? const Color(0xFFE5484D)
                      : (light
                          ? const Color(0x12000000)
                          : const Color(0x1AFFFFFF)))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: LIcon(
                widget.icon,
                size: widget.icon == 'min' ? 16 : 15,
                color: _hovered && widget.close
                    ? Colors.white
                    : (light
                        ? const Color(0xFF686B73)
                        : const Color(0xBFFFFFFF)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LuminoSplash extends StatefulWidget {
  const LuminoSplash({super.key});

  @override
  State<LuminoSplash> createState() => _SplashState();
}

class _SplashState extends State<LuminoSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2900),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appear = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.34, curve: Curves.easeOutCubic),
    );
    final textIn = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.19, 0.43, curve: Curves.easeOutCubic),
    );
    final fadeOut = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.83, 1, curve: Curves.easeIn),
    );
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Opacity(
        opacity: 1 - fadeOut.value,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.2),
              radius: 0.85,
              colors: [Color(0xFF2A2A2A), Color(0xFF121212), Color(0xFF050505)],
              stops: [0, 0.55, 1],
            ),
          ),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              FadeTransition(
                opacity: appear,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.88, end: 1).animate(appear),
                  child: SizedBox(
                    width: 116,
                    height: 147,
                    child: Image.asset('assets/logo.png', fit: BoxFit.contain),
                  ),
                ),
              ),
              const SizedBox(height: 26),
              FadeTransition(
                opacity: textIn,
                child: SlideTransition(
                  position: Tween<Offset>(
                          begin: const Offset(0, 0.2), end: Offset.zero)
                      .animate(textIn),
                  child: const Text(
                    'Welcome to Lumino!',
                    style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: Colors.white,
                        decoration: TextDecoration.none,
                        decorationColor: Colors.transparent),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
