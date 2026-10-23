import 'dart:async';

import 'package:flutter/foundation.dart';

class AppRestMode {
  VoidCallback? onSleep;
  VoidCallback? onWake;
  final ValueNotifier<bool> sleeping = ValueNotifier(false);
  Timer? _wakeTimer;

  void sleep() {
    _wakeTimer?.cancel();
    _wakeTimer = null;
    sleeping.value = true;
    onSleep?.call();
  }

  void wake() {
    if (!sleeping.value) return;
    _wakeTimer?.cancel();
    _wakeTimer = Timer(const Duration(milliseconds: 1500), () {
      _wakeTimer = null;
      onWake?.call();
      sleeping.value = false;
    });
  }
}

final appRestMode = AppRestMode();
