import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../core/share_links.dart';
import '../actions.dart';
import '../design.dart';

Map<String, dynamic> _trackMessageData(Track track) => {
      'id': track.id,
      'title': track.title,
      'artists': track.artists,
      'album': track.album,
      'cover': track.cover,
      'duration': track.duration,
      'releaseType': track.releaseType,
    };

class ChatsPage extends StatefulWidget {
  const ChatsPage({super.key, required this.state, this.sharedTrack});

  final AppState state;
  final ChatShareArg? sharedTrack;

  @override
  State<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<ChatsPage> with WidgetsBindingObserver {
  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final TextEditingController _messageSearch = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<Map<String, dynamic>> _chats = [];
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _searchResults = [];
  final Map<int, GlobalKey> _messageKeys = {};
  Set<String> _messageDays = {};
  Map<String, dynamic>? _me;
  String? _selectedChat;
  DateTime? _selectedDay;
  Timer? _pollTimer;
  bool _loading = true;
  bool _shareDialogOpen = false;
  bool _stickToBottom = true;
  bool _showScrollToLatest = false;
  bool _searchOpen = false;
  int? _promptedShareNonce;
  Timer? _searchDebounce;
  Timer? _typingHeartbeat;
  String? _typingChatId;
  bool _typingActive = false;
  bool _appResumed = true;
  bool _wasPageActive = false;

  bool get _isPageActive =>
      mounted && widget.state.pageName == 'chats' && _appResumed;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_handleScroll);
    _messageSearch.addListener(_onSearchChanged);
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(_handleStateChanged);
    _appResumed = WidgetsBinding.instance.lifecycleState !=
            AppLifecycleState.paused &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.inactive &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.detached;
    _wasPageActive = _isPageActive;
    if (_isPageActive) unawaited(_refresh());
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_isPageActive) unawaited(_refresh(silent: true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _handleStateChanged();
  }

  void _handleStateChanged() {
    if (mounted) setState(() {});
    final active = _isPageActive;
    if (active && !_wasPageActive) unawaited(_refresh(silent: true));
    _wasPageActive = active;
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
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(_handleStateChanged);
    _searchDebounce?.cancel();
    _typingHeartbeat?.cancel();
    if (_typingActive && _typingChatId != null) {
      unawaited(_setTypingStatus(_typingChatId!, false));
    }
    _composer.dispose();
    _composerFocus.dispose();
    _messageSearch
      ..removeListener(_onSearchChanged)
      ..dispose();
    _scroll.removeListener(_handleScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 280), () {
      if (mounted) unawaited(_loadSearchResults());
    });
  }

  void _handleScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.maxScrollExtent - _scroll.position.pixels < 96;
    _stickToBottom = atBottom;
    if (_showScrollToLatest == atBottom && mounted) {
      setState(() => _showScrollToLatest = !atBottom);
    }
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
      final selectedChatChanged = !selectedExists;
      setState(() {
        _chats
          ..clear()
          ..addAll(chats);
        _me = user;
        if (!selectedExists) {
          _selectedChat = chats.isEmpty ? null : chats.first['id'] as String?;
          _stickToBottom = true;
        }
        _loading = false;
      });
      if (selectedChatChanged) await _loadMessageDays();
      await _loadMessages(silent: silent);
      if (_searchOpen) await _loadSearchResults();
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

  Future<void> _loadMessages({bool silent = false}) async {
    final chatId = _selectedChat;
    if (chatId == null) {
      if (mounted && _messages.isNotEmpty) setState(() => _messages = []);
      return;
    }
    final day = _selectedDay == null ? '' : _messageDayKey(_selectedDay!);
    try {
      final messages = await widget.state.auth.chatMessages(
        chatId,
        day: day,
      );
      if (mounted &&
          chatId == _selectedChat &&
          day == (_selectedDay == null ? '' : _messageDayKey(_selectedDay!))) {
        final wasAtBottom = _stickToBottom && _selectedDay == null;
        _messageKeys.clear();
        setState(() => _messages = messages);
        if (wasAtBottom) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _scrollToBottom());
        }
      }
    } catch (error) {
      if (mounted && !silent) {
        widget.state.showToast('Не удалось загрузить сообщения: $error');
      }
    }
  }

  Future<void> _loadSearchResults() async {
    final chatId = _selectedChat;
    final query = _messageSearch.text.trim();
    if (chatId == null || query.isEmpty) {
      if (mounted && _searchResults.isNotEmpty) {
        setState(() => _searchResults = []);
      }
      return;
    }
    try {
      final results =
          await widget.state.auth.chatMessages(chatId, query: query);
      if (mounted &&
          chatId == _selectedChat &&
          query == _messageSearch.text.trim()) {
        setState(() => _searchResults = results);
      }
    } catch (error) {
      if (mounted) {
        widget.state.showToast('Не удалось найти сообщения: $error');
      }
    }
  }

  Future<void> _loadMessageDays() async {
    final chatId = _selectedChat;
    if (chatId == null) {
      if (mounted) setState(() => _messageDays = {});
      return;
    }
    try {
      final days = await widget.state.auth.chatMessageDays(chatId);
      if (mounted && chatId == _selectedChat) {
        setState(() => _messageDays = days);
      }
    } catch (error) {
      if (mounted) {
        widget.state
            .showToast('Не удалось загрузить календарь сообщений: $error');
      }
    }
  }

  Future<void> _chooseMessageDay() async {
    final days = _messageDays
        .where((day) =>
            day.startsWith('2026') ||
            (int.tryParse(day.substring(0, 4)) ?? 0) > 2026)
        .toSet();
    if (days.isEmpty) {
      widget.state.showToast('No messages available in the calendar yet');
      return;
    }
    final date = await showGlassDialog<DateTime>(
      context,
      width: 350,
      builder: (_) => _MessageCalendarDialog(
        availableDays: days,
        selectedDay:
            _selectedDay == null ? null : _messageDayKey(_selectedDay!),
      ),
    );
    if (!mounted || date == null) return;
    setState(() {
      _selectedDay = date;
      _stickToBottom = false;
    });
    await _loadMessages();
  }

  Future<void> _jumpToSearchResult(Map<String, dynamic> message) async {
    final id = int.tryParse((message['id'] ?? '').toString());
    final chatId = _selectedChat;
    if (id == null || chatId == null) return;
    try {
      final messages =
          await widget.state.auth.chatMessages(chatId, aroundId: id);
      if (!mounted || chatId != _selectedChat) return;
      setState(() {
        _selectedDay = null;
        _messages = messages;
        _messageKeys.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final key = _messageKeys[id];
        final targetContext = key?.currentContext;
        if (targetContext == null || !mounted) return;
        await Scrollable.ensureVisible(
          targetContext,
          alignment: 0.35,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    } catch (error) {
      if (mounted) {
        widget.state.showToast('Не удалось открыть сообщение: $error');
      }
    }
  }

  Future<void> _selectChat(String chatId) async {
    if (_typingActive && _typingChatId != null) {
      unawaited(_setTypingStatus(_typingChatId!, false));
    }
    _typingHeartbeat?.cancel();
    _typingActive = false;
    _typingChatId = null;
    setState(() {
      _selectedChat = chatId;
      _messages = [];
      _searchResults = [];
      _selectedDay = null;
      _messageDays = {};
      _stickToBottom = true;
      _showScrollToLatest = false;
    });
    await _loadMessageDays();
    await _loadMessages();
    await _loadSearchResults();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  Future<void> _removeChat(Map<String, dynamic> chat, bool permanently) async {
    final chatId = (chat['id'] ?? '').toString();
    if (chatId.isEmpty) return;
    final name = _chatName(chat);
    final confirmed = await confirmDialog(
      context,
      title: permanently ? 'Delete chat permanently?' : 'Hide chat?',
      message: permanently
          ? 'This permanently deletes "$name" and all of its messages for everyone.'
          : 'This removes "$name" from your chat list. Its messages will be kept.',
      confirmLabel: permanently ? 'Delete chat' : 'Hide chat',
    );
    if (confirmed != true || !mounted) return;
    try {
      if (permanently) {
        await widget.state.auth.deleteChat(chatId);
      } else {
        await widget.state.auth.hideChat(chatId);
      }
      if (_selectedChat == chatId) {
        _selectedChat = null;
        _messages = [];
        _searchResults = [];
      }
      await _refresh(silent: true);
    } catch (error) {
      if (mounted) {
        widget.state.showToast('Could not update chat: $error');
      }
    }
  }

  void _showMessageActions(Map<String, dynamic> message, Offset position) {
    if (message['sender'] is! Map) return;
    final sender = message['sender'] as Map;
    if (sender['username']?.toString() != _me?['username']?.toString()) return;
    showLuminoMenu(context, position, [
      LuminoMenuItem('Delete message', 'trash', () {
        unawaited(_deleteMessage(message));
      }, danger: true),
    ]);
  }

  Future<void> _deleteMessage(Map<String, dynamic> message) async {
    final messageId = int.tryParse((message['id'] ?? '').toString());
    final chatId = _selectedChat;
    if (messageId == null || chatId == null) return;
    final confirmed = await confirmDialog(
      context,
      title: 'Delete this message?',
      message: 'This message will be removed from the chat for everyone.',
      confirmLabel: 'Delete message',
    );
    if (confirmed != true || !mounted || chatId != _selectedChat) return;
    try {
      await widget.state.auth.deleteChatMessage(chatId, messageId);
      await _loadMessages();
      await _loadSearchResults();
      await _refresh(silent: true);
    } catch (error) {
      if (mounted) widget.state.showToast('Could not delete message: $error');
    }
  }

  void _showChatActions(Map<String, dynamic> chat, Offset position) {
    showLuminoMenu(context, position, [
      LuminoMenuItem('Hide from list', 'eyeOff', () {
        unawaited(_removeChat(chat, false));
      }),
      LuminoMenuItem('Delete chat and messages', 'close', () {
        unawaited(_removeChat(chat, true));
      }, danger: true),
    ]);
  }

  Widget _chatActions(Map<String, dynamic> chat) => Builder(
        builder: (buttonContext) => IconAction(
          icon: 'kebab',
          size: 36,
          iconSize: 18,
          active: true,
          color: const Color(0xFFE6E6E6),
          tooltip: 'Chat options',
          onTap: () {
            final box = buttonContext.findRenderObject() as RenderBox?;
            final position = box == null
                ? Offset.zero
                : box.localToGlobal(Offset(box.size.width, box.size.height));
            _showChatActions(chat, position);
          },
        ),
      );

  void _showChatList(Offset position) {
    showLuminoMenu(
      context,
      position,
      _chats
          .map((chat) => LuminoMenuItem(_chatName(chat), 'chats', () {
                final id = chat['id'];
                if (id is String) unawaited(_selectChat(id));
              }))
          .toList(),
    );
  }

  void _openChatPeer(Map<String, dynamic>? chat) {
    final peer = chat?['peer'];
    if (peer is Map) {
      _openUser(peer.map((key, value) => MapEntry(key.toString(), value)));
    }
  }

  void _toggleSearch() {
    setState(() => _searchOpen = !_searchOpen);
    if (!_searchOpen) {
      _messageSearch.clear();
      setState(() => _searchResults = []);
    }
  }

  List<Widget> _buildTimeline() {
    final items = <Widget>[];
    String? previousDay;
    for (final message in _messages) {
      final rawTrack = message['track'];
      if (rawTrack is Map) {
        final trackData = rawTrack.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        final track = widget.state.registerTrack(Track.fromJson(trackData));
        if (track.cover.isEmpty) {
          widget.state.ensureCovers([track], priority: true);
        } else if (trackData['cover'] != track.cover) {
          message['track'] = {...trackData, 'cover': track.cover};
        }
      }
      final rawDate = DateTime.tryParse(
        (message['created_at'] ?? '').toString(),
      )?.toLocal();
      final dayKey = rawDate == null
          ? ''
          : '${rawDate.year}-${rawDate.month}-${rawDate.day}';
      if (dayKey.isNotEmpty && dayKey != previousDay) {
        items.add(_ChatDateSeparator(date: rawDate!));
        previousDay = dayKey;
      }
      final sender = message['sender'];
      final user = sender is Map
          ? sender.map((key, value) => MapEntry(key.toString(), value))
          : <String, dynamic>{};
      final messageId = int.tryParse((message['id'] ?? '').toString());
      items.add(_MessageBubble(
        key: messageId == null
            ? null
            : _messageKeys.putIfAbsent(messageId, GlobalKey.new),
        message: message,
        meId: _me?['username']?.toString() ?? '',
        onUserTap: () => _openUser(user),
        me: _me ?? const <String, dynamic>{},
        onTrackPlay: widget.state.playSharedTrack,
        onShareLink: _openShareLink,
        onContextMenu: (position) => _showMessageActions(message, position),
        timeLabel: rawDate == null ? '' : _formatMessageTime(rawDate),
        isRead: message['is_read'] == true,
      ));
    }
    return items;
  }

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            _messageSearch.text.trim().isEmpty
                ? 'Type a keyword to search'
                : 'No matching messages',
            textAlign: TextAlign.center,
            style: TextStyle(color: ThemeScope.of(context).mutedForeground),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            '${_searchResults.length} matching messages',
            style: TextStyle(
              fontSize: 11,
              color: ThemeScope.of(context).mutedForeground,
            ),
          ),
        ),
        for (final message in _searchResults)
          _SearchResultTile(
            message: message,
            onTap: () => _jumpToSearchResult(message),
          ),
      ],
    );
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      _stickToBottom = true;
      if (_showScrollToLatest && mounted) {
        setState(() => _showScrollToLatest = false);
      }
    }
  }

  Future<void> _sendText() async {
    final text = _composer.text.trim();
    final chatId = _selectedChat;
    if (text.isEmpty || chatId == null) return;
    _composer.clear();
    _stopTyping();
    try {
      await widget.state.auth.sendChatMessage(chatId, text: text);
      if (_selectedDay != null) setState(() => _selectedDay = null);
      await _loadMessageDays();
      await _loadMessages();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      _retainComposerFocus();
    } catch (error) {
      _composer.text = text;
      widget.state.showToast('Не удалось отправить сообщение: $error');
      _retainComposerFocus();
    }
  }

  void _onComposerChanged(String value) {
    final chatId = _selectedChat;
    if (chatId == null) return;
    if (value.trim().isEmpty) {
      _stopTyping();
      return;
    }
    if (_typingChatId != chatId || !_typingActive) {
      _typingChatId = chatId;
      _typingActive = true;
      unawaited(_setTypingStatus(chatId, true));
      _typingHeartbeat = Timer.periodic(const Duration(seconds: 4), (_) {
        if (_typingActive && _typingChatId == chatId) {
          unawaited(_setTypingStatus(chatId, true));
        }
      });
    }
  }

  void _stopTyping() {
    _typingHeartbeat?.cancel();
    _typingHeartbeat = null;
    final chatId = _typingChatId;
    if (!_typingActive || chatId == null) return;
    _typingActive = false;
    _typingChatId = null;
    unawaited(_setTypingStatus(chatId, false));
  }

  Future<void> _setTypingStatus(String chatId, bool isTyping) async {
    try {
      await widget.state.auth.setChatTyping(chatId, isTyping);
    } catch (error) {
      if (mounted) {
        widget.state.showToast('Could not update typing status: $error');
      }
    }
  }

  void _retainComposerFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectedChat != null) {
        _composerFocus.requestFocus();
      }
    });
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
      if (_selectedDay != null) setState(() => _selectedDay = null);
      await _loadMessageDays();
      await _loadMessages();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } catch (error) {
      widget.state.showToast('Не удалось прикрепить изображение: $error');
    }
  }

  Future<void> _newChat({Track? shareTrack}) async {
    final user = await showGlassDialog<Map<String, dynamic>>(
      context,
      width: 420,
      padding: const EdgeInsets.all(22),
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
        await _loadMessageDays();
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
      final chat = await showGlassDialog<Map<String, dynamic>>(
        context,
        width: 460,
        builder: (dialogContext) {
          var query = '';
          return StatefulBuilder(
            builder: (context, updateDialog) {
              final matches = _chats.where((chat) {
                final peer = chat['peer'];
                final username =
                    peer is Map ? (peer['username'] ?? '').toString() : '';
                final needle = query.trim().toLowerCase();
                return needle.isEmpty ||
                    _chatName(chat).toLowerCase().contains(needle) ||
                    username.toLowerCase().contains(needle);
              }).toList();
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Share track',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: const Color(0x12FFFFFF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(children: [
                      CoverArt(
                          track: track,
                          size: 48,
                          radius: 8,
                          openArtwork: false),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 3),
                              Text(track.artists.join(', '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0x99FFFFFF))),
                            ]),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'Find a chat',
                      prefixIcon: const Padding(
                        padding: EdgeInsets.all(12),
                        child: LIcon('search', size: 17),
                      ),
                      isDense: true,
                      filled: true,
                      fillColor: const Color(0x12FFFFFF),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(11),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (value) => updateDialog(() => query = value),
                  ),
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: matches.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(18),
                              child: Text('No chats found. Start a new chat.'),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: matches.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 3),
                            itemBuilder: (context, index) {
                              final chat = matches[index];
                              return Material(
                                type: MaterialType.transparency,
                                child: ListTile(
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10)),
                                  leading: _chatAvatar(chat),
                                  title: Text(_chatName(chat)),
                                  subtitle: chat['peer'] is Map
                                      ? Text(
                                          '@${(chat['peer'] as Map)['username'] ?? ''}')
                                      : null,
                                  onTap: () =>
                                      Navigator.of(dialogContext).pop(chat),
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(
                      child: GhostButton(
                        label: 'Cancel',
                        onTap: () => Navigator.of(dialogContext).pop(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GhostButton(
                        label: 'New chat',
                        onTap: () =>
                            Navigator.of(dialogContext).pop({'new_chat': true}),
                      ),
                    ),
                  ]),
                ],
              );
            },
          );
        },
      );
      if (chat == null) return;
      if (chat['new_chat'] == true) {
        await _newChat(shareTrack: track);
        return;
      }
      final chatId = chat['id'] as String;
      await widget.state.auth.sendChatMessage(
        chatId,
        track: _trackMessageData(track),
      );
      await _selectChat(chatId);
      await _loadMessageDays();
      await _loadMessages();
      widget.state.go('chats');
    } catch (error) {
      if (!mounted) return;
      await showGlassDialog<void>(
        context,
        builder: (dialogContext) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Unable to share track',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(error.toString()),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: GhostButton(
                label: 'Close',
                onTap: () => Navigator.of(dialogContext).pop(),
              ),
            ),
          ],
        ),
      );
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
    final online = peer is Map && _isUserOnline(peer);
    return SizedBox(
      width: radius * 2 + 4,
      height: radius * 2 + 4,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CircleAvatar(
              radius: radius,
              backgroundColor: const Color(0xFF32323A),
              child: ClipOval(
                child: avatar.isNotEmpty
                    ? imageWidget(avatar, fit: BoxFit.cover)
                    : const LIcon('user', size: 17, color: Colors.white),
              ),
            ),
          ),
          if (online)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: const Color(0xFF59D98E),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF111114),
                    width: 2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _isUserOnline(Map peer) {
    final lastSeen = DateTime.tryParse((peer['last_seen'] ?? '').toString());
    if (lastSeen == null) return false;
    return DateTime.now().difference(lastSeen.toLocal()).inSeconds < 90;
  }

  String _peerPresence(Map peer) {
    if (peer['is_typing'] == true) return 'Typing…';
    if (_isUserOnline(peer)) return 'Online';
    final lastSeen = DateTime.tryParse((peer['last_seen'] ?? '').toString());
    if (lastSeen == null) return 'Offline';
    return 'Last seen ${_formatPresenceTime(lastSeen.toLocal())}';
  }

  Widget _chatListItem(Map<String, dynamic> chat) {
    final peer = chat['peer'];
    final lastText = (chat['last_text'] ?? '').toString().trim();
    final preview = lastText.isNotEmpty
        ? lastText
        : (chat['last_track'] ?? '').toString().isNotEmpty
            ? 'Shared a track'
            : (chat['last_image'] ?? '').toString().isNotEmpty
                ? 'Shared an image'
                : 'Start a conversation';
    final lastAt = DateTime.tryParse((chat['last_at'] ?? '').toString());
    final selected = chat['id'] == _selectedChat;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        color: selected ? const Color(0x1FFFFFFF) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _selectChat(chat['id'] as String),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(9, 9, 5, 9),
            child: Row(children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: _chatAvatar(chat, radius: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                          _chatName(chat),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (lastAt != null) ...[
                        const SizedBox(width: 4),
                        Text(
                          _formatChatListDate(lastAt.toLocal()),
                          style: const TextStyle(
                              fontSize: 9.5, color: Color(0x80FFFFFF)),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 3),
                    Text(
                      peer is Map && peer['is_typing'] == true
                          ? 'Typing…'
                          : preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: peer is Map && peer['is_typing'] == true
                            ? const Color(0xFF59D98E)
                            : ThemeScope.of(context).mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 2),
              _chatActions(chat),
            ]),
          ),
        ),
      ),
    );
  }

  void _openUser(Map<String, dynamic> user) {
    widget.state.go(
      'user-profile',
      arg: user,
    );
  }

  Future<void> _openShareLink(ShareLinkTarget target) async {
    try {
      await openShareLinkTarget(widget.state, target);
    } catch (error) {
      widget.state.showToast('Could not open link: $error');
    }
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
            child: Text('Chats',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          ),
          IconAction(
            icon: 'plus',
            size: 38,
            iconSize: 18,
            tooltip: 'New chat',
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
                  width: 280,
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 10, 10),
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            _searchOpen && _messageSearch.text.trim().isNotEmpty
                                ? 'Search results'
                                : 'Direct messages',
                            style: const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.35),
                          ),
                        ),
                        IconAction(
                          icon: 'plus',
                          size: 32,
                          iconSize: 16,
                          tooltip: 'New chat',
                          onTap: _newChat,
                        ),
                      ]),
                    ),
                    if (!_searchOpen || _messageSearch.text.trim().isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '${_chats.length} ${_chats.length == 1 ? 'conversation' : 'conversations'}',
                            style: TextStyle(
                                fontSize: 10.5,
                                color: ThemeScope.of(context).mutedForeground),
                          ),
                        ),
                      ),
                    Expanded(
                      child: _searchOpen &&
                              _messageSearch.text.trim().isNotEmpty
                          ? _buildSearchResults()
                          : ListView(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 7),
                              children: [
                                for (final chat in _chats) _chatListItem(chat),
                              ],
                            ),
                    ),
                  ]),
                ),
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
                      Expanded(
                        child: selected == null
                            ? const Text('Select a chat')
                            : GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _openChatPeer(selected),
                                child: Row(children: [
                                  _chatAvatar(selected, radius: 18),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _chatName(selected),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700),
                                        ),
                                        if (selected['peer'] is Map)
                                          Text(
                                            _peerPresence(
                                                selected['peer'] as Map),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: (selected['peer'] as Map)[
                                                              'is_typing'] ==
                                                          true ||
                                                      _isUserOnline(
                                                          selected['peer']
                                                              as Map)
                                                  ? const Color(0xFF59D98E)
                                                  : ThemeScope.of(context)
                                                      .mutedForeground,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ]),
                              ),
                      ),
                      if (selected != null)
                        IconAction(
                          icon: 'search',
                          size: 36,
                          iconSize: 17,
                          tooltip: 'Search messages',
                          active: _searchOpen,
                          onTap: _toggleSearch,
                        ),
                      if (selected != null) _chatActions(selected),
                      if (!showSidebar && selected != null)
                        Builder(
                          builder: (buttonContext) => IconAction(
                            icon: 'list',
                            size: 36,
                            iconSize: 18,
                            tooltip: 'Chats',
                            onTap: () {
                              final box = buttonContext.findRenderObject()
                                  as RenderBox?;
                              final position = box == null
                                  ? Offset.zero
                                  : box.localToGlobal(
                                      Offset(box.size.width, box.size.height));
                              _showChatList(position);
                            },
                          ),
                        ),
                    ]),
                  ),
                  if (_searchOpen && selected != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: TextField(
                        controller: _messageSearch,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: 'Search messages',
                          prefixIcon: const Padding(
                            padding: EdgeInsets.all(12),
                            child: LIcon('search', size: 18),
                          ),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Choose a date',
                                icon: const LIcon('calendar', size: 18),
                                onPressed: _chooseMessageDay,
                              ),
                              IconButton(
                                tooltip: 'Close search',
                                icon: const LIcon('close', size: 16),
                                onPressed: _toggleSearch,
                              ),
                            ],
                          ),
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0x12FFFFFF),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  if (_selectedDay != null && selected != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
                        child: InputChip(
                          label: Text(_formatShortMessageDate(
                              _messageDayKey(_selectedDay!))),
                          avatar: const LIcon('calendar', size: 14),
                          deleteIcon: const LIcon('close', size: 14),
                          onDeleted: () {
                            setState(() => _selectedDay = null);
                            unawaited(_loadMessages());
                          },
                          visualDensity: VisualDensity.compact,
                          backgroundColor: const Color(0x1AFFFFFF),
                          side: BorderSide.none,
                        ),
                      ),
                    ),
                  Expanded(
                    child: _loading
                        ? const Center(
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : selected == null
                            ? Center(
                                child: Text('Start a new chat',
                                    style: TextStyle(color: muted)))
                            : Stack(
                                children: [
                                  Positioned.fill(
                                    child: ListView(
                                      controller: _scroll,
                                      padding: EdgeInsets.symmetric(
                                        horizontal: showSidebar ? 28 : 16,
                                        vertical: 16,
                                      ),
                                      children: _buildTimeline(),
                                    ),
                                  ),
                                  Positioned(
                                    right: 18,
                                    bottom: 16,
                                    child: IgnorePointer(
                                      ignoring: !_showScrollToLatest,
                                      child: AnimatedOpacity(
                                        opacity: _showScrollToLatest ? 1 : 0,
                                        duration:
                                            const Duration(milliseconds: 160),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: const Color(0xF20D0E12),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            border: Border.all(
                                                color: const Color(0x26FFFFFF)),
                                            boxShadow: const [
                                              BoxShadow(
                                                  color: Color(0x50000000),
                                                  blurRadius: 14,
                                                  offset: Offset(0, 5)),
                                            ],
                                          ),
                                          child: IconAction(
                                            icon: 'chevD',
                                            size: 42,
                                            iconSize: 18,
                                            tooltip: 'Jump to latest',
                                            onTap: _scrollToBottom,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
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
                        tooltip: 'Attach image',
                        onTap: selected == null ? null : _sendImage,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _composer,
                          focusNode: _composerFocus,
                          enabled: selected != null,
                          minLines: 1,
                          maxLines: 1,
                          textInputAction: TextInputAction.send,
                          onChanged: _onComposerChanged,
                          onSubmitted: (_) {
                            unawaited(_sendText());
                            _retainComposerFocus();
                          },
                          decoration: InputDecoration(
                            hintText:
                                selected == null ? 'Select a chat' : 'Message…',
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
                        icon: 'arrowUp',
                        size: 38,
                        iconSize: 18,
                        tooltip: 'Send',
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
  String? _searchError;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _search(String value) {
    _debounce?.cancel();
    if (value.trim().length < 2) {
      setState(() {
        _users = [];
        _searchError = null;
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      setState(() {
        _searching = true;
        _searchError = null;
      });
      try {
        final result = await widget.state.auth.searchChatUsers(value.trim());
        if (mounted && _query.text.trim() == value.trim()) {
          setState(() => _users = result);
        }
      } catch (error) {
        if (mounted && _query.text.trim() == value.trim()) {
          setState(() {
            _users = [];
            _searchError = 'Could not search users: $error';
          });
        }
      } finally {
        if (mounted && _query.text.trim() == value.trim()) {
          setState(() => _searching = false);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0x1AFFFFFF),
                borderRadius: BorderRadius.circular(11),
              ),
              alignment: Alignment.center,
              child: const LIcon('chats', size: 19, color: Colors.white),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('New chat',
                      style:
                          TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                  SizedBox(height: 3),
                  Text('Find someone by username',
                      style: TextStyle(fontSize: 12, color: Color(0x99FFFFFF))),
                ],
              ),
            ),
            IconAction(
              icon: 'close',
              size: 34,
              iconSize: 16,
              tooltip: 'Close',
              onTap: () => Navigator.of(context).pop(),
            ),
          ]),
          const SizedBox(height: 18),
          TextField(
            controller: _query,
            autofocus: true,
            onChanged: _search,
            style: const TextStyle(fontSize: 14, color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Search by username',
              hintStyle: const TextStyle(color: Color(0x80FFFFFF)),
              prefixIcon: const Padding(
                padding: EdgeInsets.all(12),
                child: LIcon('search', size: 17),
              ),
              isDense: true,
              filled: true,
              fillColor: const Color(0x12FFFFFF),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11),
                borderSide: const BorderSide(color: Color(0x20FFFFFF)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11),
                borderSide: const BorderSide(color: Color(0x20FFFFFF)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(11),
                borderSide: const BorderSide(color: Color(0x66FFFFFF)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300, minHeight: 120),
            child: _searching
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _searchError != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _searchError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFFFF8A8A)),
                          ),
                        ),
                      )
                    : _users.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                _query.text.trim().length < 2
                                    ? 'Enter at least 2 characters to search.'
                                    : 'No users found.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0x99FFFFFF)),
                              ),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: _users.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 4),
                            itemBuilder: (context, index) {
                              final user = _users[index];
                              final name = (user['display_name'] ??
                                      user['username'] ??
                                      '')
                                  .toString();
                              return Material(
                                type: MaterialType.transparency,
                                child: ListTile(
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(11)),
                                  leading: _userAvatar(user),
                                  title: Text(name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  subtitle: Text('@${user['username'] ?? ''}'),
                                  trailing: const LIcon('chevR',
                                      size: 15, color: Color(0x99FFFFFF)),
                                  onTap: () => Navigator.of(context).pop(user),
                                ),
                              );
                            },
                          ),
          ),
          const SizedBox(height: 14),
          GhostButton(
            label: 'Cancel',
            height: 40,
            padding: 0,
            onTap: () => Navigator.of(context).pop(),
          ),
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
    super.key,
    required this.message,
    required this.meId,
    required this.onUserTap,
    required this.me,
    required this.onTrackPlay,
    required this.onShareLink,
    required this.onContextMenu,
    required this.timeLabel,
    required this.isRead,
  });

  final Map<String, dynamic> message;
  final String meId;
  final VoidCallback onUserTap;
  final Map<String, dynamic> me;
  final Future<void> Function(Track track) onTrackPlay;
  final Future<void> Function(ShareLinkTarget target) onShareLink;
  final ValueChanged<Offset> onContextMenu;
  final String timeLabel;
  final bool isRead;

  Future<void> _openImage(BuildContext context, String image) async {
    await showDialog<void>(
      context: context,
      barrierColor: const Color(0xE6000000),
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.75,
                maxScale: 4,
                child: Center(
                  child: imageWidget(image, fit: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconAction(
                icon: 'close',
                size: 38,
                iconSize: 18,
                tooltip: 'Close image',
                onTap: () => Navigator.of(dialogContext).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openTextMessage(
      BuildContext context, String sender, String text) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(sender, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

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
        (sender['display_name'] ?? sender['username'] ?? 'User').toString();
    final trackData = message['track'] is Map
        ? (message['track'] as Map)
            .map((key, value) => MapEntry(key.toString(), value))
        : null;
    final track = trackData == null ? null : Track.fromJson(trackData);
    final image = (message['image'] ?? '').toString();
    final text = (message['text'] ?? '').toString();
    final linkUri = Uri.tryParse(text.trim());
    final shareTarget = linkUri == null ? null : parseShareUri(linkUri);
    final trackLink =
        shareTarget?.kind == 'track' || shareTarget?.kind == 'short-track';
    final messageText = track != null && trackLink ? '' : text;
    final trackOnly = track != null && messageText.isEmpty && image.isEmpty;
    final bubble = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: messageText.isEmpty || track != null
          ? null
          : () {
              if (shareTarget != null) {
                unawaited(onShareLink(shareTarget));
              } else {
                unawaited(_openTextMessage(context, label, text));
              }
            },
      onSecondaryTapDown:
          mine ? (details) => onContextMenu(details.globalPosition) : null,
      child: IntrinsicWidth(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 400),
          margin: EdgeInsets.only(bottom: trackOnly ? 0 : 7),
          padding: trackOnly ? EdgeInsets.zero : const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: trackOnly
                ? Colors.transparent
                : mine
                    ? const Color(0xFF34343D)
                    : const Color(0xFF1D1D22),
            borderRadius: BorderRadius.circular(trackOnly ? 0 : 11),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!mine && !trackOnly)
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
              if (messageText.isNotEmpty)
                Text(messageText, style: const TextStyle(fontSize: 14)),
              if (image.isNotEmpty) ...[
                const SizedBox(height: 7),
                GestureDetector(
                  onTap: () => _openImage(context, image),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: SizedBox(
                      width: 280,
                      height: 210,
                      child: imageWidget(image, fit: BoxFit.cover),
                    ),
                  ),
                ),
              ],
              if (track != null) ...[
                if (!trackOnly) const SizedBox(height: 8),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => unawaited(onTrackPlay(track)),
                  child: Container(
                    width: 310,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF25272A),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: const Color(0xFF666A6D),
                        width: 7,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AspectRatio(
                            aspectRatio: 1,
                            child: CoverArt(
                              track: track,
                              size: 278,
                              radius: 0,
                              openArtwork: false,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(2, 12, 2, 3),
                            child: Text(
                              track.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
                            child: Text(
                              'Track · ${track.artists.join(', ')}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                color: Color(0xFFE1E1E1),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              if (timeLabel.isNotEmpty) ...[
                SizedBox(height: trackOnly ? 0 : 5),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(timeLabel,
                          style: const TextStyle(
                              fontSize: 10,
                              color: Color(0x80FFFFFF),
                              fontFeatures: [FontFeature.tabularFigures()])),
                      if (mine) ...[
                        const SizedBox(width: 5),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LIcon(
                              'check',
                              size: 12,
                              color: Colors.white,
                            ),
                            if (isRead)
                              Transform.translate(
                                offset: const Offset(-5, 0),
                                child: const LIcon(
                                  'check',
                                  size: 12,
                                  color: Colors.white,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
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

class _ChatDateSeparator extends StatelessWidget {
  const _ChatDateSeparator({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final label = _sameDate(date, today)
        ? 'Today'
        : _sameDate(date, today.subtract(const Duration(days: 1)))
            ? 'Yesterday'
            : date.year < 2026
                ? '${date.day} ${_monthName(date.month)}'
                : '${date.day} ${_monthName(date.month)} ${date.year}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0x1AFFFFFF),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: Color(0xB3FFFFFF))),
          ),
        ),
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({required this.message, required this.onTap});

  final Map<String, dynamic> message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sender = message['sender'] is Map
        ? (message['sender'] as Map)
        : const <dynamic, dynamic>{};
    final senderName =
        (sender['display_name'] ?? sender['username'] ?? 'User').toString();
    final track = message['track'] is Map ? message['track'] as Map : null;
    final body = (message['text'] ?? '').toString().trim();
    final preview = body.isNotEmpty
        ? body
        : track == null
            ? (message['image']?.toString().isNotEmpty == true
                ? 'Shared an image'
                : 'Message')
            : 'Shared ${track['title'] ?? 'a track'}';
    final date = _formatShortMessageDate(
        (message['created_at'] ?? '').toString().split('T').first);
    final light = ThemeScope.of(context).light;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
            decoration: BoxDecoration(
              color: light ? const Color(0x0A000000) : const Color(0x0FFFFFFF),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(
                      senderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: ThemeScope.of(context).mutedForeground,
                      ),
                    ),
                  ),
                  Text(
                    date,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xA6FFFFFF),
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ]),
                const SizedBox(height: 5),
                Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, height: 1.25),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageCalendarDialog extends StatefulWidget {
  const _MessageCalendarDialog({
    required this.availableDays,
    required this.selectedDay,
  });

  final Set<String> availableDays;
  final String? selectedDay;

  @override
  State<_MessageCalendarDialog> createState() => _MessageCalendarDialogState();
}

class _MessageCalendarDialogState extends State<_MessageCalendarDialog> {
  late DateTime _month;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    final initial = widget.selectedDay == null
        ? today
        : DateTime.tryParse(widget.selectedDay!) ?? today;
    _month = DateTime(initial.year < 2026 ? 2026 : initial.year, initial.month);
  }

  void _changeMonth(int amount) {
    final candidate = DateTime(_month.year, _month.month + amount);
    final now = DateTime.now();
    if (candidate.year < 2026 ||
        candidate.year > now.year ||
        (candidate.year == now.year && candidate.month > now.month)) {
      return;
    }
    setState(() => _month = candidate);
  }

  @override
  Widget build(BuildContext context) {
    final first = DateTime(_month.year, _month.month, 1);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final offset = first.weekday - 1;
    final today = DateTime.now();
    final lastAllowed = DateTime(today.year, today.month, today.day);
    final canGoBack = _month.year > 2026 || _month.month > 1;
    final canGoForward = _month.year < today.year ||
        (_month.year == today.year && _month.month < today.month);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          const Expanded(
            child: Text('Messages by date',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          IconAction(
            icon: 'chevL',
            size: 32,
            iconSize: 15,
            tooltip: 'Previous month',
            onTap: canGoBack ? () => _changeMonth(-1) : null,
          ),
          IconAction(
            icon: 'chevR',
            size: 32,
            iconSize: 15,
            tooltip: 'Next month',
            onTap: canGoForward ? () => _changeMonth(1) : null,
          ),
        ]),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '${_monthName(_month.month)} ${_month.year}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final day in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
              Expanded(
                child: Center(
                  child: Text(day,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0x99FFFFFF))),
                ),
              ),
          ],
        ),
        const SizedBox(height: 7),
        for (var week = 0; week < 6; week++)
          Row(
            children: [
              for (var weekday = 0; weekday < 7; weekday++)
                Expanded(
                  child: Builder(builder: (context) {
                    final dayNumber = week * 7 + weekday - offset + 1;
                    if (dayNumber < 1 || dayNumber > daysInMonth) {
                      return const SizedBox(height: 38);
                    }
                    final date = DateTime(_month.year, _month.month, dayNumber);
                    final dateKey = _messageDayKey(date);
                    final hasMessages = widget.availableDays.contains(dateKey);
                    final selected = widget.selectedDay == dateKey;
                    final allowed = hasMessages &&
                        !date.isAfter(lastAllowed) &&
                        date.year >= 2026;
                    return SizedBox(
                      height: 38,
                      child: Center(
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: allowed
                              ? () => Navigator.of(context).pop(date)
                              : null,
                          child: Container(
                            width: 32,
                            height: 32,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: selected
                                  ? Colors.white
                                  : allowed
                                      ? const Color(0xFF375D46)
                                      : Colors.transparent,
                              border: allowed && !selected
                                  ? Border.all(
                                      color: const Color(0xFF7FCB99),
                                      width: 1,
                                    )
                                  : null,
                            ),
                            child: Text(
                              '$dayNumber',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: allowed || selected
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                color: selected
                                    ? const Color(0xFF151519)
                                    : allowed
                                        ? Colors.white
                                        : const Color(0x66888888),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
            ],
          ),
        const SizedBox(height: 9),
        Row(children: [
          Container(
            width: 9,
            height: 9,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Color(0xFF7FCB99)),
          ),
          const SizedBox(width: 7),
          const Expanded(
            child: Text('Days with messages',
                style: TextStyle(fontSize: 11, color: Color(0xB3FFFFFF))),
          ),
          GhostButton(
            label: 'Cancel',
            height: 34,
            padding: 14,
            onTap: () => Navigator.of(context).pop(),
          ),
        ]),
      ],
    );
  }
}

bool _sameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _messageDayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String _formatShortMessageDate(String day) {
  final date = DateTime.tryParse(day);
  if (date == null) return '';
  return '${date.day} ${const [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][date.month - 1]}.';
}

String _formatChatListDate(DateTime date) {
  final now = DateTime.now();
  if (_sameDate(date, now)) return _formatMessageTime(date);
  return _formatShortMessageDate(_messageDayKey(date));
}

String _formatPresenceTime(DateTime date) {
  final now = DateTime.now();
  final day = _sameDate(date, now)
      ? 'today'
      : _sameDate(date, now.subtract(const Duration(days: 1)))
          ? 'yesterday'
          : _formatShortMessageDate(_messageDayKey(date));
  final year =
      date.year >= 2026 && date.year != now.year ? ' ${date.year}' : '';
  return '$day$year at ${_formatMessageTime(date)}';
}

String _formatMessageTime(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

String _monthName(int month) => const [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ][month - 1];
