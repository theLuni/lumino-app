import 'dart:io';

import 'package:flutter/services.dart';

class WindowsEfficiencyService {
  static const MethodChannel _channel = MethodChannel('lumino/efficiency');
  static bool _enabled = false;
  static bool _minimized = false;

  static Future<void> setEnabled(bool enabled) async {
    if (!Platform.isWindows) return;
    await _apply(enabled, _minimized);
    _enabled = enabled;
  }

  static Future<void> setMinimized(bool minimized) async {
    if (!Platform.isWindows) return;
    await _apply(_enabled, minimized);
    _minimized = minimized;
  }

  static Future<void> _apply(bool enabled, bool minimized) async {
    await _channel.invokeMethod<void>('setEfficiencyMode', {
      'enabled': enabled,
      'minimized': minimized,
    });
  }
}
