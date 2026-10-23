import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// Audio engine built on media_kit (libmpv). It supports direct HTTPS streams
/// from the Lumino node, seeking, volume and a 10-band equalizer via mpv's
/// audio filter chain.
class AudioService {
  AudioService() {
    _subscriptions.add(player.stream.playing.listen((value) {
      playing = value;
      playingNotifier.value = value;
    }));
    _subscriptions.add(player.stream.position.listen((value) {
      position = value;
      final delta = (value - positionNotifier.value).inMilliseconds;
      final threshold = positionUpdateInterval.inMilliseconds;
      if (delta >= threshold || delta <= -threshold) {
        positionNotifier.value = value;
      }
    }));
    _subscriptions.add(player.stream.duration.listen((value) {
      duration = value;
      durationNotifier.value = value;
    }));
    _subscriptions.add(player.stream.completed.listen((value) {
      if (value && !_ended) {
        _ended = true;
        onEnded?.call();
      } else if (!value) {
        _ended = false;
      }
    }));
    _subscriptions.add(player.stream.error.listen((message) {
      lastError = message;
      onError?.call(message);
    }));
  }

  final Player player = Player();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  final ValueNotifier<Duration> positionNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> durationNotifier = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> playingNotifier = ValueNotifier(false);

  bool playing = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  String lastError = '';
  bool _ended = false;
  bool _loaded = false;
  Duration positionUpdateInterval = const Duration(milliseconds: 250);

  VoidCallback? onEnded;
  void Function(String message)? onError;

  Future<void> load(String url, {double volume = 0.7}) async {
    _ended = false;
    lastError = '';
    _loaded = false;
    try {
      await player.setVolume((volume * 100).clamp(0.0, 100.0).toDouble());
      await player.open(Media(url), play: false);
      _loaded = true;
    } catch (error) {
      lastError = error.toString();
    }
  }

  Future<void> play() async {
    if (!_loaded) return;
    try {
      await player.play();
    } catch (error) {
      lastError = error.toString();
    }
  }

  Future<void> pause() async => player.pause();

  Future<void> stop() async {
    _loaded = false;
    _ended = false;
    try {
      await player.stop();
    } catch (_) {}
  }

  Future<void> seek(Duration value) async {
    if (!_loaded) return;
    try {
      await player.seek(value);
    } catch (_) {}
  }

  Future<void> setVolume(double value) async {
    try {
      await player.setVolume((value * 100).clamp(0.0, 100.0).toDouble());
    } catch (_) {}
  }

  Future<void> _setProperty(String name, String value) async {
    try {
      // media_kit only exposes mpv properties on the native platform player.
      final platform = player.platform;
      // ignore: avoid_dynamic_calls
      await (platform as dynamic).setProperty(name, value);
    } catch (_) {}
  }

  Future<void> setQuality(String quality) async {
    try {
      final seconds =
          quality == 'low' ? '6' : (quality == 'high' ? '60' : '20');
      await _setProperty('demuxer-readahead-secs', seconds);
      await _setProperty('cache-secs', seconds);
    } catch (_) {}
  }

  static const List<int> eqFrequencies = [
    32,
    64,
    125,
    250,
    500,
    1000,
    2000,
    4000,
    8000,
    16000
  ];

  /// Applies the equalizer. mpv's libavfilter `equalizer` accepts a chain; an
  /// empty chain means "equalizer off".
  Future<void> applyEqualizer(bool enabled, List<double> bands) async {
    try {
      if (!enabled) {
        await _setProperty('af', '');
        return;
      }
      final filters = <String>[];
      for (var i = 0; i < eqFrequencies.length && i < bands.length; i++) {
        if (bands[i].abs() < 0.05) continue;
        filters.add(
          'equalizer=f=${eqFrequencies[i]}:width_type=o:width=2:g=${bands[i].toStringAsFixed(1)}',
        );
      }
      await _setProperty('af', filters.join(','));
    } catch (_) {
      // Filters are a bonus: playback must continue if the build of mpv lacks them.
    }
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
  }
}
