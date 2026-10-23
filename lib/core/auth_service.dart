import 'dart:convert';

import 'package:http/http.dart' as http;

import 'server_status.dart';

/// Client for the Lumino server (/api/auth/*, /api/state).
/// Same host as the track node: https://fascind.theluni.ru
class AuthService {
  AuthService({
    http.Client? client,
    this.base = 'https://fascind.theluni.ru',
    this.onToken,
    this.status,
  }) : _client = client ?? http.Client();

  static const String sessionCookie = 'lumino_session';

  final String base;
  final http.Client _client;

  /// Called whenever the session token changes (login, logout, server reset).
  /// The app uses it to keep the token on disk, so the account survives restarts.
  void Function(String? token)? onToken;

  /// Gets every answer (or failure) of the server, so the UI can show the outage page.
  final ServerStatus? status;

  String? _token;
  String? username;
  String? displayName;

  String? get token => _token;
  bool get isSignedIn => _token != null && _token!.isNotEmpty;

  /// Puts back a token that was saved earlier. Does not call [onToken].
  void restore(String? token) {
    _token = (token == null || token.isEmpty) ? null : token;
  }

  Future<void> register({
    required String username,
    required String password,
    required String email,
    required String displayName,
  }) async {
    await _post('/api/auth/register', {
      'username': username,
      'password': password,
      'email': email,
      'display_name': displayName,
    });
  }

  Future<void> verify({required String email, required String code}) async {
    final data =
        await _post('/api/auth/verify', {'email': email, 'code': code});
    _setUser(data['user']);
  }

  Future<void> resend({required String email}) async {
    await _post('/api/auth/resend', {'email': email});
  }

  Future<void> login(
      {required String username, required String password}) async {
    final data = await _post(
        '/api/auth/login', {'username': username, 'password': password});
    _setUser(data['user']);
  }

  Future<void> logout() async {
    try {
      await _post('/api/auth/logout', {});
    } catch (_) {
      // Session is dropped locally regardless.
    }
    _setToken(null);
    username = null;
    displayName = null;
  }

  Future<void> forgot({required String email}) async {
    await _post('/api/auth/forgot', {'email': email});
  }

  Future<void> reset({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await _post('/api/auth/reset',
        {'email': email, 'code': code, 'new_password': newPassword});
  }

  /// Health check (GET /health). Updates [status] and returns true if the server is up.
  Future<bool> ping() async {
    try {
      final res = await _client
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 6));
      final ok = res.statusCode == 200;
      if (ok) {
        status?.markOk();
      } else {
        status?.markDown();
      }
      return ok;
    } catch (_) {
      status?.markDown();
      return false;
    }
  }

  /// Checks the saved session. Returns the user, or null if the server
  /// no longer recognises the token. Throws [AuthException] with status 0
  /// when the server cannot be reached (offline).
  Future<Map<String, dynamic>?> me() async {
    final data = await _call('GET', '/api/auth/me');
    final user = data['user'];
    if (user is Map) {
      _setUser(user);
      return user.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  }

  /// Account state saved on the server, or null if the account has none yet.
  Future<Map<String, dynamic>?> fetchState() async {
    final data = await _call('GET', '/api/state');
    final state = data['state'];
    return state is Map ? state.map((k, v) => MapEntry(k.toString(), v)) : null;
  }

  /// Replaces the account state on the server with [json] (an encoded object).
  Future<void> pushStateJson(String json) async {
    await _call('PUT', '/api/state', rawBody: json);
  }

  Future<Map<String, dynamic>> chatChats() => _call('GET', '/api/chat/chats');

  Future<Map<String, dynamic>> publicUserProfile(String username) async {
    final data = await _call(
      'GET',
      '/api/users/profile?username=${Uri.encodeQueryComponent(username)}',
    );
    final user = data['user'];
    if (user is! Map) {
      throw const FormatException('Public profile response is malformed.');
    }
    return user.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<List<Map<String, dynamic>>> searchChatUsers(String query) async {
    final data = await _call(
      'GET',
      '/api/chat/users?q=${Uri.encodeQueryComponent(query)}',
    );
    return _maps(data['users']);
  }

  Future<List<Map<String, dynamic>>> chatMessages(
    String chatId, {
    String query = '',
    String day = '',
    int? aroundId,
  }) async {
    final data = await _call(
      'GET',
      '/api/chat/messages?chat_id=${Uri.encodeQueryComponent(chatId)}'
          '&q=${Uri.encodeQueryComponent(query)}'
          '${day.isEmpty ? '' : '&day=${Uri.encodeQueryComponent(day)}'}'
          '${aroundId == null ? '' : '&around_id=$aroundId'}',
    );
    return _maps(data['messages']);
  }

  Future<Set<String>> chatMessageDays(String chatId) async {
    final data = await _call(
      'GET',
      '/api/chat/days?chat_id=${Uri.encodeQueryComponent(chatId)}',
    );
    final days = data['days'];
    return days is List ? days.whereType<String>().toSet() : <String>{};
  }

  Future<void> hideChat(String chatId) async {
    await _post('/api/chat/hide', {'chat_id': chatId});
  }

  Future<void> deleteChat(String chatId) async {
    await _post('/api/chat/delete', {'chat_id': chatId});
  }

  Future<void> deleteChatMessage(String chatId, int messageId) async {
    await _post('/api/chat/message/delete', {
      'chat_id': chatId,
      'message_id': messageId,
    });
  }

  Future<String> createDirectChat(String username) async {
    final data = await _post('/api/chat/create', {'username': username});
    return (data['chat_id'] ?? '').toString();
  }

  Future<void> sendChatMessage(
    String chatId, {
    String text = '',
    String image = '',
    Map<String, dynamic>? track,
  }) async {
    await _post('/api/chat/send', {
      'chat_id': chatId,
      'text': text,
      if (image.isNotEmpty) 'image': image,
      if (track != null) 'track': track,
    });
  }

  Future<void> setChatTyping(String chatId, bool isTyping) async {
    await _post('/api/chat/typing', {
      'chat_id': chatId,
      'is_typing': isTyping,
    });
  }

  List<Map<String, dynamic>> _maps(dynamic value) => value is List
      ? value
          .whereType<Map>()
          .map((item) =>
              item.map((key, value) => MapEntry(key.toString(), value)))
          .toList()
      : <Map<String, dynamic>>[];

  void _setUser(dynamic raw) {
    if (raw is Map) {
      username = raw['username']?.toString();
      displayName = raw['display_name']?.toString();
    }
  }

  void _setToken(String? value) {
    _token = (value == null || value.isEmpty) ? null : value;
    onToken?.call(_token);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) {
    return _call('POST', path, rawBody: jsonEncode(body));
  }

  /// One request to the server. Keeps the session cookie in sync and turns
  /// errors into [AuthException].
  Future<Map<String, dynamic>> _call(String method, String path,
      {String? rawBody}) async {
    final req = http.Request(method, Uri.parse('$base$path'));
    req.headers['Accept'] = 'application/json';
    if (rawBody != null) {
      req.headers['Content-Type'] = 'application/json; charset=utf-8';
      req.bodyBytes = utf8.encode(rawBody);
    }
    if (isSignedIn) req.headers['Cookie'] = '$sessionCookie=$_token';

    final http.Response res;
    try {
      final streamed =
          await _client.send(req).timeout(const Duration(seconds: 30));
      res = await http.Response.fromStream(streamed);
    } catch (_) {
      status?.markDown();
      throw AuthException('Нет связи с сервером', status: 0);
    }

    if (res.statusCode >= 500) {
      status?.markDown();
    } else {
      status?.markOk();
    }
    _captureSession(res.headers['set-cookie']);

    var data = <String, dynamic>{};
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map) {
        data = decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}

    if (res.statusCode >= 400 || data['ok'] == false) {
      throw AuthException(
        (data['error'] ?? 'Ошибка ${res.statusCode}').toString(),
        status: res.statusCode,
        needVerify: data['need_verify'] == true,
      );
    }
    return data;
  }

  void _captureSession(String? setCookie) {
    if (setCookie == null) return;
    final match = RegExp('$sessionCookie=([^;,\\s]*)').firstMatch(setCookie);
    if (match == null) return;
    _setToken(match.group(1) ?? '');
  }

  void dispose() => _client.close();
}

class AuthException implements Exception {
  AuthException(this.message, {this.status = 0, this.needVerify = false});

  final String message;
  final int status;
  final bool needVerify;

  /// True when the server could not be reached at all.
  bool get offline => status == 0;

  @override
  String toString() => message;
}
