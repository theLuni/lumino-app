import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_log.dart';
import 'models.dart';
import 'persistence.dart';

class NodeChange {
  NodeChange(this.state, this.reason);
  final NodeState state;
  final String reason;
}

class _Health {
  bool? ok;
  int ms = 0;
  int fails = 0;
  int slow = 0;
}

class _Node {
  const _Node(this.id, this.label, this.base);
  final String id;
  final String label;
  final String base;
}

/// Talks to the Lumino server nodes (Russia / Poland) and performs the same
/// health checks / automatic failover as the Electron main process.
class NodeService {
  NodeService(this.persistence);

  static const List<_Node> _nodes = [
    _Node('ru', 'Russia', 'https://fascind.theluni.ru'),
    _Node('pl', 'Poland', 'https://147.45.72.47.sslip.io'),
  ];
  static const List<String> _order = ['ru', 'pl'];
  static const int probeTimeoutMs = 5000;
  static const int probeEveryMs = 30000;
  static const int slowMs = 2500;
  static const int slowRounds = 3;
  static const int failsToSwitch = 2;
  static const int switchCooldownMs = 60000;

  final Persistence persistence;
  final http.Client _client = http.Client();
  final Map<String, _Health> _health = {
    'ru': _Health(),
    'pl': _Health(),
  };
  final StreamController<NodeChange> _events = StreamController<NodeChange>.broadcast();

  String? _active;
  bool auto = true;
  int _lastSwitchAt = 0;
  Timer? _timer;
  Future<void>? _ready;

  Stream<NodeChange> get changes => _events.stream;

  _Node? _byId(String? id) {
    for (final node in _nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  String get activeId => _active ?? '';
  String get base {
    final node = _byId(_active);
    return node?.base ?? _nodes.first.base;
  }

  List<NodeInfo> _nodeInfos() => _order.map((id) {
        final node = _byId(id)!;
        final health = _health[id]!;
        return NodeInfo(
          id: id,
          label: node.label,
          active: id == _active,
          ok: health.ok,
          ms: health.ms,
        );
      }).toList();

  NodeState snapshot() => NodeState(
        active: _active ?? '',
        auto: auto,
        base: base,
        nodes: _nodeInfos(),
      );

  void _emit(String reason) {
    if (!_events.isClosed) _events.add(NodeChange(snapshot(), reason));
  }

  // The node choice is kept in memory only: nothing is stored on the device.
  Future<void> _persist() async {}

  bool _switchTo(String id, String reason) {
    if (_byId(id) == null || id == _active) return false;
    final from = _active;
    _active = id;
    _lastSwitchAt = DateTime.now().millisecondsSinceEpoch;
    _health[id]!
      ..fails = 0
      ..slow = 0;
    unawaited(_persist());
    AppLog.instance.log(LogLevel.warn, 'node', 'switched $from -> $id ($reason)');
    _emit(reason);
    return true;
  }

  String get _other => _active == 'ru' ? 'pl' : 'ru';

  bool _evaluateSlow() {
    if (!auto || _active == null) return false;
    if (DateTime.now().millisecondsSinceEpoch - _lastSwitchAt < switchCooldownMs) return false;
    final a = _health[_active]!;
    final b = _health[_other]!;
    if (a.slow >= slowRounds && b.ok == true && b.ms < a.ms * 0.6) {
      return _switchTo(_other, 'slow');
    }
    return false;
  }

  Future<bool> _maybeFailover(String reason) async {
    if (!auto || _active == null) return false;
    if (_health[_active]!.fails < failsToSwitch) return false;
    if (DateTime.now().millisecondsSinceEpoch - _lastSwitchAt < switchCooldownMs) return false;
    final candidate = _other;
    final up = await _probe(candidate);
    if (!up) return false;
    return _switchTo(candidate, reason);
  }

  Future<bool> _probe(String id) async {
    final node = _byId(id);
    if (node == null) return false;
    final health = _health[id]!;
    final started = DateTime.now().millisecondsSinceEpoch;
    var ok = false;
    String? problem;
    try {
      final res = await _client
          .get(Uri.parse('${node.base}/health'), headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(milliseconds: probeTimeoutMs));
      ok = res.statusCode >= 200 && res.statusCode < 300 && res.body.trim() == 'ok';
      if (!ok) problem = 'HTTP ${res.statusCode}, body "${AppLog.clip(res.body, 40)}"';
    } catch (error) {
      ok = false;
      problem = '$error';
    }
    final ms = DateTime.now().millisecondsSinceEpoch - started;
    // Log only transitions (up <-> down) so the 30 s probe cycle does not flood the file.
    final wasOk = health.ok;
    if (ok && wasOk != true) {
      AppLog.instance.log(LogLevel.info, 'node', '$id (${node.base}) is up, ${ms}ms');
    } else if (!ok && wasOk != false) {
      AppLog.instance.log(LogLevel.warn, 'node', '$id is down: $problem');
    } else if (ok) {
      AppLog.instance.log(LogLevel.debug, 'node', 'probe $id ok ${ms}ms');
    }
    if (ok) {
      health.ok = true;
      health.ms = ms;
      health.fails = 0;
      health.slow = ms >= slowMs ? health.slow + 1 : 0;
    } else {
      health.ok = false;
      health.fails += 1;
      health.slow = 0;
    }
    return ok;
  }

  Future<void> _probeAll([String reason = 'probe']) async {
    await Future.wait(_order.map(_probe));
    if (_active != null && !await _maybeFailover('unreachable')) _evaluateSlow();
    _emit(reason);
  }

  Future<void> init() async {
    // Starts in automatic mode every time; the previous choice is not stored.
    auto = true;
    _active = null;
  }

  Future<void> start() {
    return _ready ??= (() async {
      await init();
      await Future.wait(_order.map(_probe));
      if (_active == null) {
        final healthy = _order
            .where((id) => _health[id]!.ok == true)
            .toList()
          ..sort((a, b) => _health[a]!.ms - _health[b]!.ms);
        // Prefer the Russian node (fascind) whenever it answers; otherwise the other one.
        _active = healthy.contains('ru') ? 'ru' : (healthy.isNotEmpty ? healthy.first : 'ru');
        await _persist();
      }
      _timer ??= Timer.periodic(
        const Duration(milliseconds: probeEveryMs),
        (_) => unawaited(_probeAll()),
      );
      _emit('probe');
    })();
  }

  Future<void> ready() => _ready ?? start();

  Future<NodeState> state() async {
    await ready();
    return snapshot();
  }

  Future<NodeState> set({String? active, bool? autoSwitch}) async {
    await ready();
    AppLog.instance.log(LogLevel.info, 'node', 'manual change: active=${active ?? '-'} auto=${autoSwitch ?? '-'}');
    if (active != null && _byId(active) != null && active != _active) {
      _active = active;
      _health[active]!
        ..fails = 0
        ..slow = 0;
      _lastSwitchAt = DateTime.now().millisecondsSinceEpoch;
    }
    if (autoSwitch != null) auto = autoSwitch;
    await _persist();
    _emit('manual');
    final id = _active;
    if (id != null) unawaited(_probe(id).then((_) => _emit('probe')));
    return snapshot();
  }

  Future<NodeState> reportStreamFailure() async {
    await ready();
    final id = _active;
    if (id == null) return snapshot();
    // A failed stream is usually a bad track link (expired or refused upstream),
    // not a bad node. Switch nodes only if the node itself stops answering /health.
    final alive = await _probe(id);
    AppLog.instance.log(LogLevel.warn, 'node', 'stream failed on $id, node ${alive ? 'answers' : 'does not answer'} /health');
    if (alive) return snapshot();
    _health[id]!
      ..fails = failsToSwitch
      ..ok = false;
    await _maybeFailover('stream');
    return snapshot();
  }

  Future<({int status, dynamic data})> request(
    String route, {
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await ready();
    final query = <String, String>{};
    params.forEach((key, value) => query[key] = value?.toString() ?? '');
    final shownParams = query.entries.map((e) => '${e.key}=${AppLog.clip(e.value, 60)}').join('&');
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      final id = _active;
      final node = _byId(id);
      if (node == null) break;
      final uri = Uri.parse('${node.base}$route').replace(queryParameters: query.isEmpty ? null : query);
      final sw = Stopwatch()..start();
      try {
        final res = await _client.get(uri, headers: {'Accept': 'application/json'}).timeout(timeout);
        if (res.statusCode >= 500) {
          throw NodeHttpException('server node responded with ${res.statusCode}', res.statusCode);
        }
        AppLog.instance.log(LogLevel.info, 'node', 'GET $route ${res.statusCode} ${sw.elapsedMilliseconds}ms via $id');
        dynamic data;
        try {
          data = jsonDecode(utf8.decode(res.bodyBytes));
        } catch (_) {
          data = null;
        }
        _health[id]!
          ..fails = 0
          ..ok = true;
        return (status: res.statusCode, data: data);
      } catch (error) {
        lastError = error;
        AppLog.instance.log(
          LogLevel.warn,
          'node',
          'GET $route?$shownParams failed via $id after ${sw.elapsedMilliseconds}ms (attempt ${attempt + 1}/2)',
          error: error,
        );
        _health[id]!
          ..fails += 1
          ..ok = false;
        await _maybeFailover('unreachable');
        if (_active == id) break;
      }
    }
    throw lastError ?? Exception('no server node available');
  }

  Future<Map<String, dynamic>> getJson(
    String route, {
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final result = await request(route, params: params, timeout: timeout);
    final data = result.data;
    if (data is Map) return data.map((key, value) => MapEntry(key.toString(), value));
    return <String, dynamic>{};
  }

  void dispose() {
    _timer?.cancel();
    _events.close();
    _client.close();
  }
}

class NodeHttpException implements Exception {
  NodeHttpException(this.message, this.status);
  final String message;
  final int status;

  @override
  String toString() => message;
}
