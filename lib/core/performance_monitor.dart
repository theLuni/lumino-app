import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/scheduler.dart';

import 'app_log.dart';

class PerformanceMonitor {
  PerformanceMonitor._();

  static final PerformanceMonitor instance = PerformanceMonitor._();
  static const int _frameBudgetMicros = 16667;
  static const Duration _reportInterval = Duration(seconds: 5);
  static const Duration _operationLogInterval = Duration(seconds: 5);

  final Map<String, _FrameSample> _frameSamples = {};
  final Map<String, DateTime> _lastOperationLogs = {};
  Timer? _reportTimer;
  String _screen = 'startup';
  bool _started = false;

  void start() {
    if (!kDebugMode) return;
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback(_recordFrames);
  }

  void setScreen(String screen) {
    if (!kDebugMode) return;
    if (screen == _screen) return;
    _screen = screen;
    AppLog.instance.log(LogLevel.info, 'performance', 'screen=$screen');
  }

  T measureSync<T>(String operation, T Function() action,
      {Duration threshold = const Duration(milliseconds: 16)}) {
    if (!kDebugMode) return action();
    final stopwatch = Stopwatch()..start();
    try {
      return action();
    } finally {
      stopwatch.stop();
      recordOperation(operation, stopwatch.elapsed, threshold: threshold);
    }
  }

  void recordOperation(String operation, Duration elapsed,
      {Duration threshold = const Duration(milliseconds: 16),
      String details = ''}) {
    if (!kDebugMode) return;
    if (elapsed < threshold) return;
    final now = DateTime.now();
    final previous = _lastOperationLogs[operation];
    if (previous != null && now.difference(previous) < _operationLogInterval) {
      return;
    }
    _lastOperationLogs[operation] = now;
    AppLog.instance.log(
      LogLevel.warn,
      'performance',
      'operation=$operation elapsedMs=${_milliseconds(elapsed)}'
          '${details.isEmpty ? '' : ' $details'} screen=$_screen',
    );
  }

  void _recordFrames(List<ui.FrameTiming> timings) {
    for (final timing in timings) {
      final buildMicros = timing.buildDuration.inMicroseconds;
      final rasterMicros = timing.rasterDuration.inMicroseconds;
      if (buildMicros <= _frameBudgetMicros &&
          rasterMicros <= _frameBudgetMicros) {
        continue;
      }
      final sample = _frameSamples.putIfAbsent(_screen, _FrameSample.new);
      sample.add(buildMicros, rasterMicros, timing.totalSpan.inMicroseconds);
    }

    if (_frameSamples.isNotEmpty) {
      _reportTimer ??= Timer(_reportInterval, _flushFrameSamples);
    }
  }

  void _flushFrameSamples() {
    _reportTimer = null;
    if (_frameSamples.isEmpty) return;
    final samples = Map<String, _FrameSample>.from(_frameSamples);
    _frameSamples.clear();
    for (final entry in samples.entries) {
      final sample = entry.value;
      AppLog.instance.log(
        LogLevel.warn,
        'performance',
        'frame-window=${_reportInterval.inSeconds}s screen=${entry.key} '
            'slowFrames=${sample.count} '
            'uiAvgMs=${_averageMilliseconds(sample.buildMicros, sample.count)} '
            'uiMaxMs=${_millisecondsFromMicros(sample.maxBuildMicros)} '
            'rasterAvgMs=${_averageMilliseconds(sample.rasterMicros, sample.count)} '
            'rasterMaxMs=${_millisecondsFromMicros(sample.maxRasterMicros)} '
            'frameMaxMs=${_millisecondsFromMicros(sample.maxFrameMicros)}',
      );
    }
    if (_frameSamples.isNotEmpty) {
      _reportTimer = Timer(_reportInterval, _flushFrameSamples);
    }
  }

  static String _milliseconds(Duration duration) =>
      _millisecondsFromMicros(duration.inMicroseconds);

  static String _millisecondsFromMicros(int microseconds) =>
      (microseconds / 1000).toStringAsFixed(1);

  static String _averageMilliseconds(int microseconds, int count) =>
      _millisecondsFromMicros((microseconds / count).round());
}

class _FrameSample {
  int count = 0;
  int buildMicros = 0;
  int rasterMicros = 0;
  int maxBuildMicros = 0;
  int maxRasterMicros = 0;
  int maxFrameMicros = 0;

  void add(int build, int raster, int frame) {
    count++;
    buildMicros += build;
    rasterMicros += raster;
    if (build > maxBuildMicros) maxBuildMicros = build;
    if (raster > maxRasterMicros) maxRasterMicros = raster;
    if (frame > maxFrameMicros) maxFrameMicros = frame;
  }
}
