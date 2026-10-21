import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

/// Lumino keeps no account data on this device. The library, likes, playlists,
/// settings and history live on the server. This class only:
///   * holds the state received from the server for the current session,
///   * sends the state back after changes (in memory, retried while offline),
///   * keeps the session token, so the account survives a restart.
///
/// Files written here: the session token and the app log (AppLog), plus the
/// tray icon copied from the app assets. Old local copies are removed by
/// [purgeLocalData].
class Persistence {
  /// Coalesces a burst of calls (several in one frame) into one encode.
  static const Duration _saveDebounce = Duration(milliseconds: 100);
  static const Duration _retryDelay = Duration(seconds: 5);

  Directory? _dir;
  File? _sessionFile;
  Timer? _timer;
  Map<String, dynamic> Function()? _pendingBuild;

  Map<String, dynamic> _initialState = <String, dynamic>{};

  /// Sends the encoded state to the server. Set only while signed in.
  Future<void> Function(String json)? onStateWritten;
  Timer? _uploadTimer;
  String? _pendingUpload;
  bool _uploading = false;

  Future<Directory> ensureDir() async {
    if (_dir != null) return _dir!;
    final support = await getApplicationSupportDirectory();
    var dir = support;
    // Windows runner metadata is "Lumino", path_provider gives ...\Lumino.
    if (!dir.path.toLowerCase().contains('lumino')) {
      dir = Directory('${support.path}${Platform.pathSeparator}Lumino');
    }
    await dir.create(recursive: true);
    _dir = dir;
    _sessionFile = File('${dir.path}${Platform.pathSeparator}lumino-session.json');
    return dir;
  }

  // ------------------------------------------------------------ account state

  /// Account state received from the server before the player opens.
  void setInitialState(Map<String, dynamic> state) {
    _initialState = state;
  }

  Future<Map<String, dynamic>> loadState() async => _initialState;

  /// Takes a builder, not a finished map: the snapshot is built once, when the
  /// debounce window closes, instead of on every save call.
  void scheduleSave(Map<String, dynamic> Function() build) {
    _pendingBuild = build;
    _timer?.cancel();
    _timer = Timer(_saveDebounce, () {
      final build = _pendingBuild;
      _pendingBuild = null;
      if (build != null) unawaited(writeState(build()));
    });
  }

  Future<void> writeState(Map<String, dynamic> data) async {
    if (onStateWritten == null) return;
    try {
      // JSON encoding of a large library runs off the UI isolate.
      final text = await Isolate.run(() => jsonEncode(data));
      _pendingUpload = text;
      // Sent right away, not later: a restart must not bring back onboarding.
      unawaited(flush());
    } catch (_) {
      // Best-effort: the next change sends the newer state anyway.
    }
  }

  /// Sends the newest state now. Only one request runs at a time; a change made
  /// meanwhile is sent right after it. Returns false if the server did not take it;
  /// the state stays queued and is retried.
  Future<bool> flush() async {
    _uploadTimer?.cancel();
    _uploadTimer = null;
    if (_uploading) return true; // the running loop picks up the newest body
    _uploading = true;
    var ok = true;
    try {
      while (_pendingUpload != null) {
        final hook = onStateWritten;
        final body = _pendingUpload!;
        _pendingUpload = null;
        if (hook == null) continue;
        try {
          await hook(body);
        } catch (_) {
          _pendingUpload ??= body; // a newer save may already be queued; keep it
          ok = false;
          break;
        }
      }
    } finally {
      _uploading = false;
    }
    if (!ok) _uploadTimer = Timer(_retryDelay, () => unawaited(flush()));
    return ok;
  }

  /// Drops unsent changes and detaches from the server (sign-out).
  void discardPending() {
    _timer?.cancel();
    _pendingBuild = null;
    _uploadTimer?.cancel();
    _uploadTimer = null;
    _pendingUpload = null;
    onStateWritten = null;
    _initialState = <String, dynamic>{};
  }

  /// Clears the whole account on the server ("reset everything").
  Future<void> deleteState() async {
    _timer?.cancel();
    _pendingBuild = null;
    _initialState = <String, dynamic>{};
    _pendingUpload = '{}';
    await flush();
  }

  /// Removes what older builds stored on this device: the state copy, the
  /// node preference and the cache folder.
  Future<void> purgeLocalData() async {
    final dir = await ensureDir();
    final sep = Platform.pathSeparator;
    for (final name in ['lumino-state.json', 'lumino-state.json.tmp', 'lumino-node.json', 'lumino-unsynced']) {
      try {
        final file = File('${dir.path}$sep$name');
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    try {
      final cache = Directory('${dir.path}${sep}cache');
      if (await cache.exists()) await cache.delete(recursive: true);
    } catch (_) {}
  }

  // ----------------------------------------------------------------- session

  /// Saved session token, or null if nobody signed in on this device.
  Future<String?> loadSession() async {
    await ensureDir();
    try {
      if (!await _sessionFile!.exists()) return null;
      final decoded = jsonDecode(await _sessionFile!.readAsString());
      final token = decoded is Map ? decoded['token']?.toString() : null;
      return (token == null || token.isEmpty) ? null : token;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSession(String token) async {
    await ensureDir();
    try {
      await _sessionFile!.writeAsString(jsonEncode({'token': token}), flush: true);
    } catch (_) {}
  }

  Future<void> clearSession() async {
    await ensureDir();
    try {
      if (await _sessionFile!.exists()) await _sessionFile!.delete();
    } catch (_) {}
  }
}
