import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../actions.dart';
import '../design.dart';

class ChatShareArg {
  const ChatShareArg(this.track, this.nonce);

  final Track track;
  final int nonce;
}

Map<String, dynamic> _trackMessageData(Track track) => {
      'id': track.id,
      'title': track.title,
      'artists': track.artists,
      'album': track.album,
      'cover': track.cover,
      'duration': track.duration,
      'releaseType': track.releaseType,
    };

Future<void> shareTrackInChat(
    BuildContext context, AppState state, Track track) async {
  final confirmed = await confirmDialog(
    context,
    title: 'Share track?',
    message: 'Choose a chat to share this track with.',
    confirmLabel: 'Continue',
  );
  if (confirmed != true || !context.mounted) return;
  if (state.fullScreen) state.closeFull();
  state.go(
    'chats',
    arg: ChatShareArg(track, DateTime.now().microsecondsSinceEpoch),
  );
}

class ChatsPage extends StatefulWidget {
  const ChatsPage({super.key, required this.state, this.sharedTrack});

  final AppState state;
  final ChatShareArg? sharedTrack;

  @override
  State<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<ChatsPage> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<Map<String, dynamic>> _chats = [];
  List<Map<String, dynamic>> _messages = [];
  Map<String, dynamic>? _me;
  String? _selectedChat;
  Timer? _pollTimer;
  bool _loading = true;
  bool _shareDialogOpen = false;
  int? _promptedShareNonce;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_refresh(silent: true));
    });
  }

  @override
  void didUpdateWidget(covariant ChatsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sharedTrack?.nonce != widget.sharedTrack?.nonce &&
        widget.sharedTrack != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_chooseShareChat(widget.sharedTrack!.track));
      });
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    try {
      final response = await widget.state.auth.chatChats();
      final chats = (response['chats'] as List? ?? const [])
          .whereType<Map>()
          .map((item) =>
              item.map((key, value) => MapEntry(key.toString(), value)))
          .toList();
      final user = response['user'] is Map
          ? (response['user'] as Map)
              .map((key, value) => MapEntry(key.toString(), value))
          : null;
      if (!mounted) return;
      final selectedExists = chats.any((chat) => chat['id'] == _selectedChat);
      setState(() {
        _chats
          ..clear()
          ..addAll(chats);
        _me = user;
        if (!selectedExists) {
          _selectedChat = chats.isEmpty ? null : chats.first['id'] as String?;
        }
        _loading = false;
      });
      await _loadMessages();
      final share = widget.sharedTrack;
      if (share != null &&
          share.nonce != _promptedShareNonce &&
          !_shareDialogOpen) {
        _promptedShareNonce = share.nonce;
        unawaited(_chooseShareChat(share.track));
      }
    } catch (error) {
      if (!mounted) return;
      if (!silent) widget.state.showToast('Не удалось загрузить чаты: $error');
      setState(() => _loading = false);
    }
  }

  Future<void> _loadMessages() async {
    final chatId = _selectedChat;
    if (chatId == null) {
      if (mounted && _messages.isNotEmpty) setState(() => _messages = []);
      return;
    }
    try {
      final messages = await widget.state.auth.chatMessages(chatId);
      if (mounted && chatId == _selectedChat) {
        setState(() => _messages = messages);
      }
    } catch (error) {
      if (mounted) {
        widget.state.showToast('Не удалось загрузить сообщения: $error');
      }
    }
  }

  Future<void> _selectChat(String chatId) async {
    setState(() {
      _selectedChat = chatId;
      _messages = [];
    });
    await _loadMessages();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendText() async {
    final text = _composer.text.trim();
    final chatId = _selectedChat;
    if (text.isEmpty || chatId == null) return;
    _composer.clear();
    try {
      await widget.state.auth.sendChatMessage(chatId, text: text);
      await _loadMessages();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (error) {
      _composer.text = text;
      widget.state.showToast('Не удалось отправить сообщение: $error');
    }
  }

  Future<void> _sendImage() async {
    final chatId = _selectedChat;
    if (chatId == null) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.lengthInBytes > 2 * 1024 * 1024) {
        widget.state.showToast('Изображение должно быть не больше 2 МБ');
        return;
      }
      final extension = file.extension?.toLowerCase();
      final mime = switch (extension) {
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'jpg' || 'jpeg' => 'image/jpeg',
        _ => '',
      };
      if (mime.isEmpty) {
        widget.state.showToast('Формат изображения не поддерживается');
        return;
      }
      await widget.state.auth.sendChatMessage(
        chatId,
        image: 'data:$mime;base64,${base64Encode(bytes)}',
      );
      await _loadMessages();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (error) {
      widget.state.showToast('Не удалось прикрепить изображение: $error');
    }
  }

  Future<void> _newChat({Track? shareTrack}) async {
    final user = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _NewChatDialog(state: widget.state),
    );
    if (user == null || !mounted) return;
    try {
      final id = await widget.state.auth
          .createDirectChat((user['username'] ?? '').toString());
      await _refresh(silent: true);
      await _selectChat(id);
      if (shareTrack != null) {
        await widget.state.auth.sendChatMessage(
          id,
          track: _trackMessageData(shareTrack),
        );
        await _loadMessages();
      }
    } catch (error) {
      widget.state.showToast('Не удалось создать чат: $error');
    }
  }

  Future<void> _chooseShareChat(Track track) async {
    if (_shareDialogOpen || !mounted) return;
    _shareDialogOpen = true;
    try {
      final chat = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Поделиться треком'),
          content: SizedBox(
            width: 360,
            child: _chats.isEmpty
                ? const Text('Сначала начните новый чат.')
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final item in _chats)
                        ListTile(
                          leading: _chatAvatar(item),
                          title: Text(_chatName(item)),
                          onTap: () => Navigator.pop(context, item),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                unawaited(_newChat(shareTrack: track));
              },
              child: const Text('Новый чат'),
            ),
          ],
        ),
      );
      if (chat == null) return;
      final chatId = chat['id'] as String;
      await widget.state.auth.sendChatMessage(
        chatId,
        track: _trackMessageData(track),
      );
      await _selectChat(chatId);
      widget.state.go('chats');
    } catch (error) {
      widget.state.showToast('Не удалось поделиться треком: $error');
    } finally {
      _shareDialogOpen = false;
    }
  }

  String _chatName(Map<String, dynamic> chat) {
    final peer = chat['peer'];
    if (peer is Map) {
      return (peer['display_name'] ?? peer['username'] ?? 'Личный чат')
          .toString();
    }
    return (chat['name'] ?? 'Личный чат').toString();
  }

  Widget _chatAvatar(Map<String, dynamic> chat, {double radius = 18}) {
    final peer = chat['peer'];
    final avatar = peer is Map ? (peer['avatar'] ?? '').toString() : '';
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFF32323A),
      child: ClipOval(
        child: avatar.isNotEmpty
            ? imageWidget(avatar, fit: BoxFit.cover)
            : const LIcon('user', size: 17, color: Colors.white),
      ),
    );
  }

  void _openUser(Map<String, dynamic> user) {
    widget.state.go(
      'user-profile',
      arg: user,
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = ThemeScope.of(context).mutedForeground;
    final showSidebar = MediaQuery.sizeOf(context).width >= 900;
    final selected =
        _chats.where((chat) => chat['id'] == _selectedChat).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('Чаты',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          ),
          IconAction(
            icon: 'plus',
            size: 38,
            iconSize: 18,
            tooltip: 'Новый чат',
            onTap: _newChat,
          ),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0x990D0D0F),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x1AFFFFFF)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(children: [
              if (showSidebar) ...[
                SizedBox(
                  width: 250,
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 18, 12, 12),
                      child: Row(children: [
                        Expanded(
                          child: Text('Сообщения',
                              style: TextStyle(color: muted, fontSize: 13)),
                        ),
                        IconAction(
                          icon: 'plus',
                          size: 32,
                          iconSize: 16,
                          tooltip: 'Новый чат',
                          onTap: _newChat,
                        ),
                      ]),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        children: [
                          for (final chat in _chats)
                            ListTile(
                              dense: true,
                              selected: chat['id'] == _selectedChat,
                              selectedTileColor: const Color(0x1FFFFFFF),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(11)),
                              leading: _chatAvatar(chat),
                              title: Text(_chatName(chat),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () => _selectChat(chat['id'] as String),
                            ),
                        ],
                      ),
                    ),
                  ]),
                ),
                const VerticalDivider(width: 1, color: Color(0x1AFFFFFF)),
              ],
              Expanded(
                child: Column(children: [
                  Container(
                    height: 62,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    decoration: const BoxDecoration(
                      border:
                          Border(bottom: BorderSide(color: Color(0x1AFFFFFF))),
                    ),
                    child: Row(children: [
                      if (selected != null) ...[
                        _chatAvatar(selected),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          selected == null
                              ? 'Выберите чат'
                              : _chatName(selected),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (!showSidebar && selected != null)
                        PopupMenuButton<String>(
                          tooltip: 'Чаты',
                          onSelected: _selectChat,
                          itemBuilder: (_) => [
                            for (final chat in _chats)
                              PopupMenuItem(
                                value: chat['id'] as String,
                                child: Text(_chatName(chat)),
                              ),
                          ],
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: LIcon('list', size: 19),
                          ),
                        ),
                    ]),
                  ),
                  Expanded(
                    child: _loading
                        ? const Center(
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : selected == null
                            ? Center(
                                child: Text('Начните новый чат',
                                    style: TextStyle(color: muted)))
                            : ListView.builder(
                                controller: _scroll,
                                padding: const EdgeInsets.all(16),
                                itemCount: _messages.length,
                                itemBuilder: (context, index) {
                                  final message = _messages[index];
                                  final sender = message['sender'];
                                  final user = sender is Map
                                      ? sender.map((key, value) =>
                                          MapEntry(key.toString(), value))
                                      : <String, dynamic>{};
                                  return _MessageBubble(
                                    message: message,
                                    meId: _me?['username']?.toString() ?? '',
                                    onUserTap: () => _openUser(user),
                                    me: _me ?? const <String, dynamic>{},
                                    onTrackTap: (track) =>
                                        openTrackRelease(widget.state, track),
                                    onTrackPlay: widget.state.playSharedTrack,
                                  );
                                },
                              ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: Color(0x1AFFFFFF))),
                    ),
                    child: Row(children: [
                      IconAction(
                        icon: 'camera',
                        size: 38,
                        iconSize: 18,
                        tooltip: 'Прикрепить изображение',
                        onTap: selected == null ? null : _sendImage,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _composer,
                          enabled: selected != null,
                          minLines: 1,
                          maxLines: 1,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _sendText(),
                          decoration: InputDecoration(
                            hintText: selected == null
                                ? 'Выберите чат'
                                : 'Сообщение…',
                            isDense: true,
                            filled: true,
                            fillColor: const Color(0x12FFFFFF),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 11),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconAction(
                        icon: 'next',
                        size: 38,
                        iconSize: 18,
                        tooltip: 'Отправить',
                        onTap: selected == null ? null : _sendText,
                      ),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _NewChatDialog extends StatefulWidget {
  const _NewChatDialog({required this.state});
  final AppState state;

  @override
  State<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<_NewChatDialog> {
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _users = [];
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _search(String value) {
    _debounce?.cancel();
    if (value.trim().length < 2) {
      setState(() => _users = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      setState(() => _searching = true);
      try {
        final result = await widget.state.auth.searchChatUsers(value.trim());
        if (mounted) setState(() => _users = result);
      } catch (_) {
        if (mounted) setState(() => _users = []);
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Новый чат'),
        content: SizedBox(
          width: 360,
          height: 360,
          child: Column(children: [
            TextField(
              controller: _query,
              onChanged: _search,
              decoration: const InputDecoration(
                hintText: 'Найти пользователя по нику',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 10),
            if (_searching) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView(
                children: [
                  for (final user in _users)
                    ListTile(
                      leading: _userAvatar(user),
                      title: Text(
                          (user['display_name'] ?? user['username'] ?? '')
                              .toString()),
                      subtitle: Text('@${user['username'] ?? ''}'),
                      onTap: () => Navigator.pop(context, user),
                    ),
                  if (!_searching &&
                      _query.text.trim().length >= 2 &&
                      _users.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Пользователи не найдены'),
                    ),
                ],
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена')),
        ],
      );

  Widget _userAvatar(Map<String, dynamic> user) {
    final avatar = (user['avatar'] ?? '').toString();
    return CircleAvatar(
      radius: 18,
      backgroundColor: const Color(0xFF32323A),
      child: ClipOval(
        child: avatar.isEmpty
            ? const LIcon('user', size: 17, color: Colors.white)
            : imageWidget(avatar, fit: BoxFit.cover),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.meId,
    required this.onUserTap,
    required this.me,
    required this.onTrackTap,
    required this.onTrackPlay,
  });

  final Map<String, dynamic> message;
  final String meId;
  final VoidCallback onUserTap;
  final Map<String, dynamic> me;
  final void Function(Track track) onTrackTap;
  final Future<void> Function(Track track) onTrackPlay;

  @override
  Widget build(BuildContext context) {
    final sender = message['sender'] is Map
        ? (message['sender'] as Map)
            .map((key, value) => MapEntry(key.toString(), value))
        : <String, dynamic>{};
    final username = (sender['username'] ?? '').toString();
    final mine = username.isNotEmpty && username == meId;
    final avatar = (mine ? me['avatar'] : sender['avatar'] ?? '').toString();
    final label =
        (sender['display_name'] ?? sender['username'] ?? 'Пользователь')
            .toString();
    final trackData = message['track'] is Map
        ? (message['track'] as Map)
            .map((key, value) => MapEntry(key.toString(), value))
        : null;
    final track = trackData == null ? null : Track.fromJson(trackData);
    final image = (message['image'] ?? '').toString();
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 460),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: mine ? const Color(0xFF34343D) : const Color(0xFF1D1D22),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine)
            GestureDetector(
              onTap: onUserTap,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Color(0x99FFFFFF),
                        fontWeight: FontWeight.w600)),
              ),
            ),
          if ((message['text'] ?? '').toString().isNotEmpty)
            Text((message['text']).toString(),
                style: const TextStyle(fontSize: 14)),
          if (image.isNotEmpty) ...[
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                width: 280,
                height: 210,
                child: imageWidget(image, fit: BoxFit.cover),
              ),
            ),
          ],
          if (track != null) ...[
            const SizedBox(height: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTrackTap(track),
              child: Container(
                width: 300,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0x18FFFFFF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(children: [
                  CoverArt(
                      track: track,
                      size: 48,
                      radius: 6,
                      openArtwork: false),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 3),
                        Text(track.artists.join(', '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0x99FFFFFF))),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconAction(
                    icon: 'play',
                    size: 30,
                    iconSize: 14,
                    tooltip: 'Воспроизвести трек',
                    onTap: () => onTrackPlay(track),
                  ),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine) ...[
            GestureDetector(
              onTap: onUserTap,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, bottom: 8),
                child: CircleAvatar(
                  radius: 15,
                  backgroundColor: const Color(0xFF32323A),
                  child: ClipOval(
                    child: avatar.isNotEmpty
                        ? imageWidget(avatar, fit: BoxFit.cover)
                        : const LIcon('user', size: 14, color: Colors.white),
                  ),
                ),
              ),
            ),
            bubble,
          ] else ...[
            bubble,
            GestureDetector(
              onTap: onUserTap,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 8),
                child: CircleAvatar(
                  radius: 15,
                  backgroundColor: const Color(0xFF32323A),
                  child: ClipOval(
                    child: avatar.isNotEmpty
                        ? imageWidget(avatar, fit: BoxFit.cover)
                        : const LIcon('user', size: 14, color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
