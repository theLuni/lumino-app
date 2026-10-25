import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:smtc_windows/smtc_windows.dart';

enum MediaCommand { play, pause, next, previous, stop }

/// Audio engine built on media_kit (libmpv). It supports direct HTTPS streams
/// from the Lumino node, seeking, volume and a 10-band equalizer via mpv's
/// audio filter chain.
class AudioService {
  AudioService() {
    _subscriptions.add(player.stream.playing.listen((value) {
      playing = value;
      playingNotifier.value = value;
      _updateMediaSession(() async {
        final session = _mediaSession;
        if (session != null) {
          await session.setPlaybackStatus(
              value ? PlaybackStatus.playing : PlaybackStatus.paused);
        }
      });
    }));
    _subscriptions.add(player.stream.position.listen((value) {
      position = value;
      final delta = (value - positionNotifier.value).inMilliseconds;
      final threshold = positionUpdateInterval.inMilliseconds;
      if (delta >= threshold || delta <= -threshold) {
        positionNotifier.value = value;
      }
      final now = DateTime.now();
      if (_lastMediaTimelineUpdate == null ||
          now.difference(_lastMediaTimelineUpdate!) >=
              const Duration(seconds: 1)) {
        _lastMediaTimelineUpdate = now;
        _updateMediaTimeline();
      }
    }));
    _subscriptions.add(player.stream.duration.listen((value) {
      duration = value;
      durationNotifier.value = value;
      _updateMediaTimeline();
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

  static SMTCWindows? _mediaSession;

  static Future<void> initializeWindowsMediaSession() async {
    if (!Platform.isWindows || _mediaSession != null) return;
    try {
      await SMTCWindows.initialize();
      final session = SMTCWindows(
        config: const SMTCConfig(
          playEnabled: true,
          pauseEnabled: true,
          nextEnabled: true,
          prevEnabled: true,
          stopEnabled: true,
          fastForwardEnabled: false,
          rewindEnabled: false,
        ),
      );
      _mediaSession = session;
      session.buttonPressStream.listen(_handleMediaButton);
    } catch (error) {
      debugPrint('Windows media controls could not be initialized: $error');
    }
  }

  static void Function(MediaCommand command)? _onMediaCommand;

  static void _handleMediaButton(PressedButton button) {
    final command = switch (button) {
      PressedButton.play => MediaCommand.play,
      PressedButton.pause => MediaCommand.pause,
      PressedButton.next => MediaCommand.next,
      PressedButton.previous => MediaCommand.previous,
      PressedButton.stop => MediaCommand.stop,
      _ => null,
    };
    if (command != null) _onMediaCommand?.call(command);
  }

  DateTime? _lastMediaTimelineUpdate;

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
  Duration positionUpdateInterval = const Duration(milliseconds: 50);

  VoidCallback? onEnded;
  void Function(String message)? onError;
  static void setMediaCommandHandler(
      void Function(MediaCommand command)? handler) {
    _onMediaCommand = handler;
  }

  Future<void> setCurrentMedia({
    required String title,
    required String artist,
    required String album,
    required String thumbnail,
  }) async {
    final session = _mediaSession;
    if (session == null) return;
    await _updateMediaSession(() async {
      await session.enableSmtc();
      await session.updateMetadata(MusicMetadata(
        title: title,
        artist: artist,
        album: album,
        albumArtist: artist,
        thumbnail: thumbnail.isEmpty ? null : thumbnail,
      ));
      await _updateMediaTimeline();
    });
  }

  Future<void> clearCurrentMedia() async {
    final session = _mediaSession;
    if (session == null) return;
    await _updateMediaSession(() async {
      await session.setPlaybackStatus(PlaybackStatus.stopped);
      await session.clearMetadata();
      await session.disableSmtc();
    });
  }

  Future<void> _updateMediaTimeline() async {
    final session = _mediaSession;
    if (session == null || !session.enabled) return;
    final endTime =
        duration.inMilliseconds.clamp(0, 0x7fffffffffffffff).toInt();
    final positionTime = position.inMilliseconds.clamp(0, endTime).toInt();
    await _updateMediaSession(() => session.updateTimeline(PlaybackTimeline(
          startTimeMs: 0,
          endTimeMs: endTime,
          positionMs: positionTime,
          minSeekTimeMs: 0,
          maxSeekTimeMs: endTime,
        )));
  }

  Future<void> _updateMediaSession(Future<void> Function() update) async {
    try {
      await update();
    } catch (error) {
      debugPrint('Windows media controls update failed: $error');
    }
  }

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
    await clearCurrentMedia();
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
