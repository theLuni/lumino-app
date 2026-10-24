import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:app_links/app_links.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/app_log.dart';
import 'core/app_state.dart';
import 'core/app_rest_mode.dart';
import 'core/audio_service.dart';
import 'core/catalog_service.dart';
import 'core/lyrics_service.dart';
import 'core/meta_service.dart';
import 'core/node_service.dart';
import 'core/auth_service.dart';
import 'core/persistence.dart';
import 'core/performance_monitor.dart';
import 'core/server_status.dart';
import 'core/share_links.dart';
import 'core/windows_efficiency_service.dart';
import 'core/windows_update_service.dart';
import 'ui/auth.dart';
import 'ui/design.dart';
import 'ui/server_unavailable.dart';
import 'ui/shell.dart';
import 'ui/window_corners.dart';

final bool _isDesktop =
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _configureRestMode();

  final imageCache = PaintingBinding.instance.imageCache
    ..maximumSize = 200
    ..maximumSizeBytes = 64 * 1024 * 1024;

  // Route every uncaught error into the log file, including ones that happen
  // before the UI is up.
  if (kDebugMode) {
    FlutterError.onError = (details) {
      AppLog.instance.log(
          LogLevel.error, 'flutter', details.exceptionAsString(),
          stack: details.stack);
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      AppLog.instance.log(LogLevel.error, 'app', 'uncaught error',
          error: error, stack: stack);
      return true;
    };
  }

  if (_isDesktop) await windowManager.ensureInitialized();

  const options = WindowOptions(
    size: Size(1110, 715),
    minimumSize: Size(900, 600),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    title: 'Lumino',
    titleBarStyle: TitleBarStyle.hidden,
  );
  // Each platform call is guarded separately: a single unsupported call must
  // not prevent the window from being shown.
  Future<void> attempt(String label, Future<void> Function() call) async {
    try {
      await call();
    } catch (error) {
      debugPrint('$label failed: $error');
    }
  }

  if (_isDesktop) {
    windowManager.waitUntilReadyToShow(options, () async {
      await attempt('setAsFrameless', () => windowManager.setAsFrameless());
      await attempt('setBackgroundColor',
          () => windowManager.setBackgroundColor(Colors.transparent));
      await attempt('isMaximized', () async {
        WindowCorners.square.value = await windowManager.isMaximized() ||
            await windowManager.isFullScreen();
      });
      await attempt('setTitle', () => windowManager.setTitle('Lumino'));
      await attempt(
          'setPreventClose', () => windowManager.setPreventClose(true));
      await attempt('show', () => windowManager.show());
      await attempt('focus', () => windowManager.focus());
    });
  }

  MediaKit.ensureInitialized();

  final persistence = Persistence();
  if (kDebugMode) {
    await AppLog.instance.init(await persistence.ensureDir());
    AppLog.instance.log(
      LogLevel.info,
      'performance',
      'image-cache maxEntries=${imageCache.maximumSize} '
          'maxDecodedMB=${imageCache.maximumSizeBytes ~/ (1024 * 1024)}',
    );
    PerformanceMonitor.instance.start();
  }
  if (_isDesktop) windowManager.addListener(_appWindowListener);

  runApp(LuminoApp(persistence: persistence));

  if (_isDesktop) unawaited(_startTray(() => _liveState, _appWindowListener));
}

/// The player state of the signed-in account. Null while the account screens are shown.
AppState? _liveState;
final _AppWindowListener _appWindowListener = _AppWindowListener();

void _configureRestMode() {
  appRestMode
    ..onSleep = () {
      _liveState?.audio.positionUpdateInterval = const Duration(seconds: 10);
    }
    ..onWake = () {
      final state = _liveState;
      if (state != null) {
        state.audio.positionUpdateInterval = const Duration(milliseconds: 50);
      }
    };
}

/// Builds the player state. It is created only after a session exists,
/// so it always loads the state of the right account.
AppState _buildAppState(Persistence persistence, AuthService auth,
    {String? registeredDisplayName}) {
  final node = NodeService(persistence);
  final audio = AudioService();
  final meta = MetaService(http.Client(), node: node);
  final catalog = CatalogService(node);
  final lyrics = LyricsService(node);
  return AppState(
    persistence: persistence,
    node: node,
    catalog: catalog,
    meta: meta,
    lyricsService: lyrics,
    audio: audio,
    auth: auth,
    registeredDisplayName: registeredDisplayName,
  );
}

class LuminoApp extends StatelessWidget {
  const LuminoApp({super.key, required this.persistence});
  final Persistence persistence;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lumino',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        fontFamily: 'Segoe UI',
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Colors.white,
          selectionColor: Color(0x59FFFFFF),
          selectionHandleColor: Colors.white,
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: const Color(0xF01A1A1E),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0x1AFFFFFF)),
          ),
          textStyle: const TextStyle(color: Colors.white, fontSize: 12),
          waitDuration: const Duration(milliseconds: 500),
        ),
      ),
      scrollBehavior: const _LuminoScrollBehavior(),
      builder: (context, child) =>
          WindowCorners(child: child ?? const SizedBox.shrink()),
      home: _RootView(persistence: persistence),
    );
  }
}

/// Decides what the user sees. A saved session goes straight to the player,
/// otherwise the account screens are shown. While the server does not answer,
/// the "server unavailable" page covers everything and the app keeps checking.
class _RootView extends StatefulWidget {
  const _RootView({required this.persistence});
  final Persistence persistence;

  @override
  State<_RootView> createState() => _RootViewState();
}

class _RootViewState extends State<_RootView> {
  final ServerStatus _status = ServerStatus();
  final WindowsUpdateService _windowsUpdates = WindowsUpdateService();
  late final AuthService _auth =
      AuthService(status: _status, onToken: _saveToken);

  AppState? _state;
  bool _checking = true;
  bool _showStartupSplash = true;
  bool _showAuthSuccess = false;
  bool _startupPending = false; // start-up stopped because the server was down
  bool _retrying = false;
  bool _checkingForUpdates = false;
  Timer? _healthTimer;
  Timer? _startupTimer;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;
  ShareLinkTarget? _pendingLink;
  bool _handlingLink = false;

  @override
  void initState() {
    super.initState();
    _status.addListener(_onStatusChanged);
    _linkSubscription = _appLinks.uriLinkStream.listen(
      _acceptLink,
      onError: (Object error, StackTrace stack) {
        AppLog.instance.log(LogLevel.error, 'app-links', 'link stream failed',
            error: error, stack: stack);
      },
    );
    unawaited(_loadInitialLink());
    _startupTimer = Timer(const Duration(milliseconds: 2900), () {
      if (mounted) setState(() => _showStartupSplash = false);
    });
    unawaited(_restore());
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _startupTimer?.cancel();
    unawaited(_linkSubscription?.cancel());
    _state?.removeListener(_onPlayerStateChanged);
    _status.removeListener(_onStatusChanged);
    _auth.dispose();
    _status.dispose();
    _windowsUpdates.dispose();
    super.dispose();
  }

  Future<void> _loadInitialLink() async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) _acceptLink(uri);
    } catch (error, stack) {
      AppLog.instance.log(
          LogLevel.error, 'app-links', 'could not read launch link',
          error: error, stack: stack);
    }
  }

  void _acceptLink(Uri uri) {
    final target = parseShareUri(uri);
    if (target == null) {
      if (uri.scheme.toLowerCase() == luminoLinkScheme) {
        _liveState?.showToast('This Lumino link is invalid or unsupported.');
      }
      return;
    }
    _pendingLink = target;
    unawaited(_applyPendingLink());
  }

  void _onPlayerStateChanged() {
    if (_state?.ready == true) unawaited(_applyPendingLink());
  }

  Future<void> _applyPendingLink() async {
    final state = _state;
    final target = _pendingLink;
    if (state == null || !state.ready || target == null || _handlingLink) {
      return;
    }
    _handlingLink = true;
    _pendingLink = null;
    try {
      await openShareLinkTarget(state, target);
    } catch (error) {
      state.showToast('Could not open link: $error');
      AppLog.instance.log(
          LogLevel.warn, 'app-links', 'failed to resolve shared link',
          error: error);
    } finally {
      _handlingLink = false;
      if (_pendingLink != null) unawaited(_applyPendingLink());
    }
  }

  void _saveToken(String? token) {
    final p = widget.persistence;
    if (token == null) {
      unawaited(p.clearSession());
    } else {
      unawaited(p.saveSession(token));
    }
  }

  bool _unreachable(AuthException e) => e.offline || e.status >= 500;

  void _onStatusChanged() {
    if (_status.down) {
      _healthTimer ??= Timer.periodic(
          const Duration(seconds: 5), (_) => unawaited(_retry()));
    } else {
      _healthTimer?.cancel();
      _healthTimer = null;
      unawaited(widget.persistence.flush());
      if (_startupPending) unawaited(_restore());
    }
    if (mounted) setState(() {});
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await _auth.ping();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _restore() async {
    _startupPending = false;
    await widget.persistence.purgeLocalData();
    final token = await widget.persistence.loadSession();
    if (token == null) {
      _showAccount();
      return;
    }
    _auth.restore(token);
    widget.persistence.onStateWritten = _auth.pushStateJson;
    try {
      final user = await _auth.me();
      if (user == null) {
        await _dropSession();
        return;
      }
      await _loadRemote();
      _enter();
    } on AuthException catch (e) {
      if (_unreachable(e)) {
        _startupPending =
            true; // the outage page is up; resume when the server answers
      } else {
        await _dropSession();
      }
    }
  }

  /// Called after login or email verification.
  Future<void> _onAuthenticated() async {
    widget.persistence.onStateWritten = _auth.pushStateJson;
    try {
      await _loadRemote();
      if (!mounted) return;
      _startupTimer?.cancel();
      setState(() {
        _showStartupSplash = false;
        _showAuthSuccess = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 850));
      if (!mounted) return;
      _enter();
    } on AuthException catch (e) {
      if (_unreachable(e)) {
        _startupPending = true;
      } else {
        await _dropSession();
      }
    }
  }

  /// Loads the account state from the server. Throws AuthException if the server is unreachable.
  Future<void> _loadRemote() async {
    final remote = await _auth.fetchState();
    widget.persistence.setInitialState(remote ?? <String, dynamic>{});
  }

  Future<void> _dropSession() async {
    _auth.restore(null);
    await widget.persistence.clearSession();
    _showAccount();
  }

  void _showAccount() {
    if (mounted) setState(() => _checking = false);
  }

  void _enter() {
    _showAuthSuccess = false;
    final state = _buildAppState(widget.persistence, _auth,
        registeredDisplayName: _auth.displayName);
    _liveState = state;
    _state?.removeListener(_onPlayerStateChanged);
    state.addListener(_onPlayerStateChanged);
    unawaited(state.init());
    if (mounted) {
      setState(() {
        _state = state;
        _checking = false;
      });
    }
    if (Platform.isWindows) unawaited(_checkForUpdates());
  }

  Future<void> _checkForUpdates({bool manual = false}) async {
    if (!Platform.isWindows || _checkingForUpdates) return;
    _checkingForUpdates = true;
    try {
      final release = await _windowsUpdates.checkForUpdate();
      if (!mounted) return;
      if (release == null) {
        if (manual) {
          await _showUpdateMessage(
            'You already have the latest version of Lumino.',
          );
        }
        return;
      }

      final install = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Lumino ${release.version} is available'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Text(
                release.notes.isEmpty
                    ? 'Install the latest version now? Lumino will restart when the update is ready.'
                    : '${release.notes}\n\nInstall the update now? Lumino will restart when it is ready.',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Install update'),
            ),
          ],
        ),
      );
      if (install == true && mounted) await _installUpdate(release);
    } catch (error, stack) {
      AppLog.instance.log(
        LogLevel.warn,
        'updates',
        'Could not check for or install an update',
        error: error,
        stack: stack,
      );
      if (manual && mounted) {
        await _showUpdateMessage('Could not check for updates.\n$error');
      }
    } finally {
      _checkingForUpdates = false;
    }
  }

  Future<void> _installUpdate(WindowsUpdateRelease release) async {
    var progressDialogOpen = true;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          title: Text('Downloading Lumino update'),
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 18),
              Flexible(
                child: Text(
                  'The installer will open when the download is complete.',
                ),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      final installer = await _windowsUpdates.downloadInstaller(release);
      if (!mounted) return;
      await windowManager.setPreventClose(false);
      _appWindowListener.quitting = true;
      try {
        await Process.start(
          installer.path,
          const [
            '/CLOSEAPPLICATIONS',
            '/RESTARTAPPLICATIONS',
          ],
          mode: ProcessStartMode.detached,
          workingDirectory: Directory.systemTemp.path,
        );
        await windowManager.close();
      } catch (_) {
        _appWindowListener.quitting = false;
        await windowManager.setPreventClose(true);
        rethrow;
      }
    } catch (error, stack) {
      AppLog.instance.log(
        LogLevel.error,
        'updates',
        'Could not install the update',
        error: error,
        stack: stack,
      );
      if (mounted) {
        if (progressDialogOpen) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        await _showUpdateMessage('Could not install the update.\n$error');
      }
    }
  }

  Future<void> _showUpdateMessage(String message) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Ends the session on this device. Unsent changes are dropped.
  /// Not wired to a button yet.
  Future<void> signOut() async {
    final state = _state;
    widget.persistence.discardPending();
    await _auth.logout();
    await widget.persistence.clearSession();
    try {
      await WindowsEfficiencyService.setEnabled(false);
    } on PlatformException catch (error) {
      AppLog.instance.log(
        LogLevel.warn,
        'windows',
        'Could not disable Windows efficiency mode on sign-out',
        error: error,
      );
    }
    if (state != null) {
      await state.audio.stop();
      state.dispose();
      state.node.dispose();
    }
    _liveState = null;
    if (mounted) setState(() => _state = null);
  }

  @override
  Widget build(BuildContext context) {
    final Widget content;
    if (_checking) {
      content = const _StartupLoading();
    } else if (_showAuthSuccess) {
      content = const _AuthSuccess();
    } else if (_state == null) {
      content = AuthGate(
        auth: _auth,
        onAuthenticated: () => unawaited(_onAuthenticated()),
      );
    } else {
      content = LuminoShell(
        state: _state!,
        onSignOut: signOut,
        onCheckForUpdates: () => _checkForUpdates(manual: true),
      );
    }
    final activeContent = Stack(
      fit: StackFit.expand,
      children: [
        content,
        if (_showStartupSplash && !appRestMode.sleeping.value)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart:
                  _isDesktop ? (_) => windowManager.startDragging() : null,
              child: const LuminoSplash(),
            ),
          ),
        if (_status.down)
          ServerUnavailablePage(
              onRetry: () => unawaited(_retry()), retrying: _retrying),
      ],
    );
    return ValueListenableBuilder<bool>(
      valueListenable: appRestMode.sleeping,
      child: activeContent,
      builder: (context, sleeping, child) => Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: sleeping,
            child: TickerMode(enabled: !sleeping, child: child!),
          ),
          if (sleeping) const Positioned.fill(child: _AwayScreen()),
        ],
      ),
    );
  }
}

class _AwayScreen extends StatelessWidget {
  const _AwayScreen();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: kBg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LIcon('sun', size: 34, color: kMuted),
              SizedBox(height: 18),
              Text(
                'Optimized while you were away',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: kText,
                  decoration: TextDecoration.none,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Restoring your player…',
                style: TextStyle(
                  fontSize: 13,
                  color: kMuted,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      );
}

class _StartupLoading extends StatelessWidget {
  const _StartupLoading();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: kBg,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0x99FFFFFF),
            ),
          ),
        ),
      );
}

class _AuthSuccess extends StatelessWidget {
  const _AuthSuccess();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: kBg,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LIcon('check', size: 38, color: Color(0xFF9FE3A2)),
              SizedBox(height: 16),
              Text(
                'Signed in successfully',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 8),
              Text(
                'Opening your library…',
                style: TextStyle(fontSize: 13, color: kMuted),
              ),
            ],
          ),
        ),
      );
}

class _LuminoScrollBehavior extends MaterialScrollBehavior {
  const _LuminoScrollBehavior();

  @override
  Widget buildScrollbar(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;

  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

class _AppWindowListener extends WindowListener {
  bool quitting = false;

  @override
  void onWindowMinimize() {
    appRestMode.sleep();
    unawaited(_setEfficiencyMinimized(true));
  }

  @override
  void onWindowRestore() {
    appRestMode.wake();
    unawaited(_setEfficiencyMinimized(false));
  }

  @override
  void onWindowFocus() {
    appRestMode.wake();
    unawaited(_setEfficiencyMinimized(false));
  }

  @override
  void onWindowMaximize() => WindowCorners.square.value = true;

  @override
  void onWindowUnmaximize() => WindowCorners.square.value = false;

  @override
  void onWindowEnterFullScreen() => WindowCorners.square.value = true;

  @override
  void onWindowLeaveFullScreen() => WindowCorners.square.value = false;

  @override
  void onWindowClose() async {
    if (quitting) {
      await _flushOnQuit();
      await AppLog.instance.close();
      await windowManager.destroy();
      return;
    }
    appRestMode.sleep();
    unawaited(_setEfficiencyMinimized(true));
    try {
      await windowManager.hide();
    } catch (error) {
      debugPrint('Could not hide the window: $error');
    }
  }

  Future<void> _setEfficiencyMinimized(bool minimized) async {
    try {
      await WindowsEfficiencyService.setMinimized(minimized);
    } on PlatformException catch (error) {
      AppLog.instance.log(
        LogLevel.warn,
        'windows',
        'Could not update Windows efficiency mode',
        error: error,
      );
      _liveState?.showToast(
          'Windows efficiency mode could not be changed: ${error.message ?? error.code}');
    }
  }
}

/// Sends unsent changes before the app exits (at most 3 s).
Future<void> _flushOnQuit() async {
  try {
    await _liveState?.persistence.flush().timeout(const Duration(seconds: 3));
  } catch (_) {}
}

Future<String> _materializeIcon(String asset) async {
  final dir = await getApplicationSupportDirectory();
  final name = asset.split('/').last;
  final file = File('${dir.path}${Platform.pathSeparator}lumino-$name');
  if (!await file.exists()) {
    final data = await rootBundle.load(asset);
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }
  return file.path;
}

Future<void> _startTray(
    AppState? Function() current, _AppWindowListener listener) async {
  try {
    final assetPath =
        Platform.isWindows ? 'assets/icon.ico' : 'assets/icon.png';
    final iconPath = await _materializeIcon(assetPath);
    try {
      await windowManager.setIcon(iconPath);
    } catch (_) {}
    // tray_manager resolves Flutter assets itself; an absolute support path
    // would be prefixed with the asset directory a second time.
    await trayManager.setIcon(assetPath);
    await trayManager.setToolTip('Lumino');
    final menu = Menu(items: [
      MenuItem(key: 'show', label: 'Show Lumino'),
      MenuItem.separator(),
      MenuItem(key: 'toggle', label: 'Play / Pause'),
      MenuItem(key: 'next', label: 'Next track'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit Lumino'),
    ]);
    await trayManager.setContextMenu(menu);
    trayManager.addListener(_TrayHandler(current, listener));
  } catch (error) {
    AppLog.instance.log(
        LogLevel.warn, 'tray', 'Could not initialize the system tray',
        error: error);
    debugPrint('Tray unavailable: $error');
    // Without a tray icon a hidden window could not be restored, so closing
    // the window must quit the app instead.
    try {
      await windowManager.setPreventClose(false);
    } catch (fallbackError) {
      AppLog.instance.log(
        LogLevel.warn,
        'tray',
        'Could not disable hide-on-close without a tray icon',
        error: fallbackError,
      );
    }
  }
}

class _TrayHandler with TrayListener {
  _TrayHandler(this.current, this.listener);
  final AppState? Function() current;
  final _AppWindowListener listener;

  @override
  void onTrayIconMouseDown() {
    unawaited(_showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_showTrayMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _showWindow();
      case 'toggle':
        final toggled = current();
        if (toggled != null) unawaited(toggled.togglePlay());
      case 'next':
        final nexted = current();
        if (nexted != null) unawaited(nexted.next());
      case 'quit':
        listener.quitting = true;
        unawaited(_flushOnQuit()
            .then((_) => AppLog.instance.close())
            .then((_) => windowManager.destroy()));
    }
  }

  Future<void> _showWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
      appRestMode.wake();
    } catch (error) {
      AppLog.instance.log(
          LogLevel.warn, 'tray', 'Could not restore the app window',
          error: error);
    }
  }

  Future<void> _showTrayMenu() async {
    try {
      await trayManager.popUpContextMenu();
    } catch (error) {
      AppLog.instance.log(LogLevel.warn, 'tray', 'Could not open the tray menu',
          error: error);
    }
  }
}
