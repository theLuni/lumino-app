import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum LogLevel { debug, info, warn, error }

/// Lumino's own log file: server-node traffic, failovers, catalog/lyrics/meta
/// requests and uncaught errors.
///
/// Location: `<app data>/Lumino/logs/lumino.log`. When the file reaches
/// [maxFileBytes] it is rotated to `lumino.1.log` ... `lumino.3.log`.
///
/// Lines are buffered in memory and written in batches every [flushInterval],
/// so logging never waits on the disk inside a UI frame or a network call.
/// Logging is best-effort: if the folder cannot be created, the app still runs
/// and the newest [maxBuffered] lines are kept in memory only.
///
/// Scopes used in the file: `node`, `catalog`, `lyrics`, `meta`, `app`, `flutter`.
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const String fileName = 'lumino.log';
  static const int maxFileBytes = 2 * 1024 * 1024;
  static const int keepRotated = 3;
  static const Duration flushInterval = Duration(seconds: 2);
  static const int maxBuffered = 2000;

  /// Debug lines are dropped unless this is lowered (for example while
  /// investigating a problem).
  LogLevel minLevel = LogLevel.info;

  Directory? _dir;
  IOSink? _sink;
  int _bytes = 0;
  final List<String> _buffer = [];
  Timer? _timer;
  bool _writing = false;

  String get filePath =>
      _dir == null ? '' : '${_dir!.path}${Platform.pathSeparator}$fileName';

  void _scheduleFlush() {
    if (_timer != null) return;
    _timer = Timer(flushInterval, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Opens the log file under [appDir]. Lines logged before this call are kept
  /// in memory and written once the file is open.
  Future<void> init(Directory appDir) async {
    try {
      final dir = Directory('${appDir.path}${Platform.pathSeparator}logs');
      await dir.create(recursive: true);
      _dir = dir;
      final file = File(filePath);
      _bytes = await file.exists() ? await file.length() : 0;
      _sink = file.openWrite(mode: FileMode.append);
    } catch (_) {
      _sink = null;
    }
    log(LogLevel.info, 'app',
        '=== session start: ${Platform.operatingSystem} ${Platform.operatingSystemVersion} ===');
    if (_buffer.isNotEmpty) _scheduleFlush();
  }

  void log(
    LogLevel level,
    String scope,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    if (level.index < minLevel.index) return;
    final buffer = StringBuffer()
      ..write(DateTime.now().toIso8601String())
      ..write(' ')
      ..write(level.name.toUpperCase().padRight(5))
      ..write(' [')
      ..write(scope)
      ..write('] ')
      ..write(message);
    if (error != null) buffer.write(' | $error');
    if (stack != null) buffer.write('\n$stack');
    final line = buffer.toString();

    if (_buffer.length >= maxBuffered) _buffer.removeAt(0);
    _buffer.add(line);
    // ignore: avoid_print
    print(line);
    _scheduleFlush();
    if (level == LogLevel.error) unawaited(flush());
  }

  /// Writes the buffered lines. Safe to call often; overlapping calls are skipped.
  Future<void> flush() async {
    if (_writing || _buffer.isEmpty || _sink == null) return;
    _writing = true;
    try {
      final batch = List<String>.from(_buffer);
      _buffer.clear();
      final chunk = '${batch.join('\n')}\n';
      final bytes = utf8.encode(chunk).length;
      if (_bytes + bytes > maxFileBytes && _bytes > 0) await _rotate();
      final out = _sink;
      if (out == null) return;
      out.write(chunk);
      await out.flush();
      _bytes += bytes;
    } catch (_) {
      // Ignore disk errors; the next batch will try again.
    } finally {
      _writing = false;
      if (_buffer.isNotEmpty) _scheduleFlush();
    }
  }

  Future<void> _rotate() async {
    final dir = _dir;
    if (dir == null) return;
    await _sink?.close();
    _sink = null;
    final sep = Platform.pathSeparator;
    String rotated(int n) => '${dir.path}${sep}lumino.$n.log';
    try {
      final oldest = File(rotated(keepRotated));
      if (await oldest.exists()) await oldest.delete();
      for (var n = keepRotated - 1; n >= 1; n--) {
        final file = File(rotated(n));
        if (await file.exists()) await file.rename(rotated(n + 1));
      }
      final current = File(filePath);
      if (await current.exists()) await current.rename(rotated(1));
    } catch (_) {}
    _sink = File(filePath).openWrite(mode: FileMode.append);
    _bytes = 0;
  }

  /// Flushes everything and closes the file. Call before the app quits.
  Future<void> close() async {
    log(LogLevel.info, 'app', '=== session end ===');
    _timer?.cancel();
    _timer = null;
    while (_writing) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    _timer?.cancel();
    _timer = null;
    await flush();
    await _sink?.close();
    _sink = null;
  }

  /// `host/path` of a URL without its query string, so logs never contain
  /// tokens or search text that may sit in parameters.
  static String shortUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return '${uri.host}${uri.path}';
    } catch (_) {
      return '<invalid url>';
    }
  }

  /// Clips long values (search text, titles) before they go into a log line.
  static String clip(Object? value, [int max = 80]) {
    final text = (value ?? '').toString().replaceAll('\n', ' ');
    return text.length <= max ? text : '${text.substring(0, max)}…';
  }
}
