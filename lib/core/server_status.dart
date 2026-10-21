import 'package:flutter/foundation.dart';

/// Whether the Lumino server answers. Written by AuthService on every request
/// and by the health check; the UI shows the "server unavailable" page while
/// it is down.
class ServerStatus extends ChangeNotifier {
  bool _down = false;

  bool get down => _down;

  void markDown() {
    if (_down) return;
    _down = true;
    notifyListeners();
  }

  void markOk() {
    if (!_down) return;
    _down = false;
    notifyListeners();
  }
}
