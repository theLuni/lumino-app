import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/share_links.dart';
import '../core/utils.dart';
import 'design.dart';

/// Shared context-menu and playlist actions used by the whole UI.

class _TrackShareCountdownButton extends StatelessWidget {
  const _TrackShareCountdownButton({
    super.key,
    required this.onTap,
    required this.onComplete,
    required this.label,
  });

  final VoidCallback? onTap;
  final VoidCallback onComplete;
  final String label;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(seconds: 4),
        onEnd: onComplete,
        builder: (context, progress, _) => SizedBox(
          width: 76,
          height: 34,
          child: GestureDetector(
            onTap: onTap,
            child: CustomPaint(
              foregroundPainter: _TrackShareCountdownPainter(progress),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xFF050506),
                  borderRadius: BorderRadius.all(Radius.circular(9)),
                ),
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class _TrackShareCountdownPainter extends CustomPainter {
  const _TrackShareCountdownPainter(this.progress);

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(9)));
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _TrackShareCountdownPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

Widget _shareChatAction({
  required String chatId,
  required int? messageId,
  required bool sending,
  required bool canceling,
  required bool completed,
  required Future<void> Function() onSend,
  required Future<void> Function() onCancel,
  required VoidCallback onComplete,
}) {
  if (messageId != null) {
    return _TrackShareCountdownButton(
      key: ValueKey('share-$chatId-$messageId'),
      label: canceling ? 'Canceling…' : 'Cancel',
      onTap: canceling ? null : onCancel,
      onComplete: onComplete,
    );
  }
  if (completed) {
    return const SizedBox(
      width: 76,
      height: 34,
      child: Center(
        child: Text(
          'Sent',
          style: TextStyle(color: kMuted, fontSize: 12),
        ),
      ),
    );
  }
  return SizedBox(
    width: 76,
    height: 34,
    child: FilledButton(
      onPressed: sending ? null : onSend,
      style: FilledButton.styleFrom(
        padding: EdgeInsets.zero,
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF17171B),
        disabledBackgroundColor: const Color(0xFF34343D),
        disabledForegroundColor: Colors.white70,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      child: Text(sending ? 'Sending…' : 'Send',
          style: const TextStyle(fontSize: 12)),
    ),
  );
}

Future<void> shareTrackInChat(
    BuildContext context, AppState state, Track track) async {
  if (!context.mounted) return;
  await showShareDialog(
    context,
    state,
    uri: trackShareUri(track),
    title: 'Share track',
    track: track,
  );
}

Future<void> shareProfile(
  BuildContext context,
  AppState state,
  String username,
) =>
    showShareDialog(
      context,
      state,
      uri: profileShareUri(username),
      title: 'Share profile',
    );

Future<void> sharePublicPlaylist(
  BuildContext context,
  AppState state, {
  required String username,
  required String playlistId,
}) =>
    showShareDialog(
      context,
      state,
      uri: publicPlaylistShareUri(username, playlistId),
      title: 'Share playlist',
    );

Future<void> sharePlaylist(
  BuildContext context,
  AppState state,
  Playlist playlist,
) async {
  final username = state.auth.username?.trim() ?? '';
  if (username.isEmpty) {
    state.showToast('Sign in to share this playlist.');
    return;
  }
  try {
    final uri = playlist.isPublic
        ? publicPlaylistShareUri(username, playlist.id)
        : privatePlaylistShareUri(
            await state.auth.createPrivatePlaylistShare(playlist.id));
    if (!context.mounted) return;
    await showShareDialog(
      context,
      state,
      uri: uri,
      title: 'Share playlist',
    );
  } catch (error) {
    state.showToast('Could not create playlist link: $error');
  }
}

Future<void> showShareDialog(
  BuildContext context,
  AppState state, {
  required Uri uri,
  required String title,
  Track? track,
}) async {
  if (!context.mounted) return;
  var shareUri = uri;
  if (track != null) {
    try {
      final code = await state.auth.createTrackShare(track);
      shareUri = Uri(
        scheme: 'https',
        host: shareLinkHost,
        path: '/s/$code',
      );
    } catch (error) {
      state.showToast('Could not create short track link: $error');
      return;
    }
    if (!context.mounted) return;
  }
  List<Map<String, dynamic>> chats;
  try {
    final response = await state.auth.chatChats();
    chats = (response['chats'] as List? ?? const [])
        .whereType<Map>()
        .map(
            (chat) => chat.map((key, value) => MapEntry(key.toString(), value)))
        .toList();
  } catch (error) {
    state.showToast('Could not load chats: $error');
    chats = [];
  }
  if (!context.mounted) return;

  if (track != null) {
    final shared = await _showTrackShareSheet(
      context,
      state,
      chats: chats,
      track: track,
      uri: shareUri,
      title: title,
    );
    if (shared == true) state.showToast('Shared in chat');
    return;
  }

  final chat = await showGlassDialog<Map<String, dynamic>>(
    context,
    width: 460,
    builder: (dialogContext) {
      var query = '';
      return StatefulBuilder(
        builder: (context, updateDialog) {
          final needle = query.trim().toLowerCase();
          final matches = chats.where((chat) {
            final peer = chat['peer'];
            final username =
                peer is Map ? (peer['username'] ?? '').toString() : '';
            final name = peer is Map
                ? (peer['display_name'] ?? username).toString()
                : (chat['name'] ?? 'Chat').toString();
            return needle.isEmpty ||
                name.toLowerCase().contains(needle) ||
                username.toLowerCase().contains(needle);
          }).toList();
          final visible = needle.isEmpty ? matches.take(5).toList() : matches;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextField(
                autofocus: false,
                onChanged: (value) => updateDialog(() => query = value),
                decoration: const InputDecoration(
                  hintText: 'Search chats',
                  prefixIcon: Padding(
                    padding: EdgeInsets.all(12),
                    child: LIcon('search', size: 18),
                  ),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 270),
                child: visible.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(18),
                          child: Text('No chats found'),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final item = visible[index];
                          final peer = item['peer'];
                          final name = peer is Map
                              ? (peer['display_name'] ??
                                      peer['username'] ??
                                      'Chat')
                                  .toString()
                              : (item['name'] ?? 'Chat').toString();
                          final avatar = peer is Map
                              ? (peer['avatar'] ?? '').toString()
                              : '';
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 21,
                                  backgroundColor: const Color(0xFF34343D),
                                  child: ClipOval(
                                    child: avatar.isEmpty
                                        ? const LIcon('chats', size: 18)
                                        : SizedBox.expand(
                                            child: imageWidget(
                                              avatar,
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 94,
                                  height: 38,
                                  child: FilledButton(
                                    onPressed: () =>
                                        Navigator.of(dialogContext).pop(item),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.white,
                                      foregroundColor: const Color(0xFF17171B),
                                      padding: EdgeInsets.zero,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(11),
                                      ),
                                    ),
                                    child: const Text('Send'),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Share link',
                      style: TextStyle(
                        color: kMuted,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const LIcon('share', size: 17),
                    label: const Text('Copy link'),
                    onPressed: () =>
                        Navigator.of(dialogContext).pop(<String, dynamic>{}),
                  ),
                ],
              ),
            ],
          );
        },
      );
    },
  );
  if (!context.mounted) return;
  if (chat == null) return;
  if (chat.isEmpty) {
    await Clipboard.setData(ClipboardData(text: shareUri.toString()));
    state.showToast('Link copied');
    return;
  }
  try {
    final chatId = (chat['id'] ?? '').toString();
    if (chatId.isEmpty) throw StateError('Chat id is missing.');
    await state.auth.sendChatMessage(
      chatId,
      text: shareUri.toString(),
      track: track == null
          ? null
          : {
              'id': track.id,
              'title': track.title,
              'artists': track.artists,
              'album': track.album,
              'cover': track.cover,
              'duration': track.duration,
              'releaseType': track.releaseType,
            },
    );
    state.showToast('Shared in chat');
  } catch (error) {
    state.showToast('Could not share: $error');
  }
}

Future<bool?> _showTrackShareSheet(
  BuildContext context,
  AppState state, {
  required List<Map<String, dynamic>> chats,
  required Track track,
  required Uri uri,
  required String title,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x80000000),
    builder: (sheetContext) {
      var query = '';
      final sentMessageIds = <String, int>{};
      final sendingChats = <String>{};
      final cancelingChats = <String>{};
      final completedChats = <String>{};
      final expiredUndoChats = <String>{};
      final chatErrors = <String, String>{};
      var sharedAny = false;

      return StatefulBuilder(
        builder: (context, updateSheet) {
          final hasPendingUndo = sentMessageIds.isNotEmpty;
          final isBusy = sendingChats.isNotEmpty || cancelingChats.isNotEmpty;
          final needle = query.trim().toLowerCase();
          final matches = chats
              .where((chat) {
                final peer = chat['peer'];
                final username =
                    peer is Map ? (peer['username'] ?? '').toString() : '';
                final name = peer is Map
                    ? (peer['display_name'] ??
                            (username.isNotEmpty ? username : 'Chat'))
                        .toString()
                    : (chat['name'] ?? 'Chat').toString();
                return needle.isEmpty ||
                    name.toLowerCase().contains(needle) ||
                    username.toLowerCase().contains(needle);
              })
              .take(8)
              .toList();

          return Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 560,
                maxHeight: MediaQuery.sizeOf(context).height * 0.82,
              ),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(
                  20,
                  14,
                  20,
                  18 + MediaQuery.viewInsetsOf(context).bottom,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xFF17171B),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 38,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0x66FFFFFF),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: Text(title,
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w700)),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () =>
                            Navigator.of(sheetContext).pop(sharedAny),
                        icon: const LIcon('close', size: 18),
                      ),
                    ]),
                    Row(children: [
                      CoverArt(
                        track: track,
                        size: 52,
                        radius: 9,
                        openArtwork: false,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            Text(track.artists.join(', '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12, color: kMuted)),
                          ],
                        ),
                      ),
                    ]),
                    const SizedBox(height: 14),
                    TextField(
                      enabled: !hasPendingUndo && !isBusy,
                      onChanged: (value) => updateSheet(() => query = value),
                      decoration: const InputDecoration(
                        hintText: 'Search chats',
                        prefixIcon: Padding(
                          padding: EdgeInsets.all(12),
                          child: LIcon('search', size: 18),
                        ),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: matches.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(18),
                                child: Text('No chats found'),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: matches.length,
                              itemBuilder: (context, index) {
                                final chat = matches[index];
                                final chatId = (chat['id'] ?? '').toString();
                                final peer = chat['peer'];
                                final username = peer is Map
                                    ? (peer['username'] ?? '').toString()
                                    : '';
                                final name = peer is Map
                                    ? (peer['display_name'] ??
                                            (username.isNotEmpty
                                                ? username
                                                : 'Chat'))
                                        .toString()
                                    : (chat['name'] ?? 'Chat').toString();
                                final avatar = peer is Map
                                    ? (peer['avatar'] ?? '').toString()
                                    : '';
                                return ListTile(
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                  leading: CircleAvatar(
                                    radius: 21,
                                    backgroundColor: const Color(0xFF34343D),
                                    child: ClipOval(
                                      child: avatar.isEmpty
                                          ? const LIcon('chats', size: 18)
                                          : SizedBox.expand(
                                              child: imageWidget(
                                                avatar,
                                                fit: BoxFit.cover,
                                              ),
                                            ),
                                    ),
                                  ),
                                  title: Text(name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  subtitle: chatErrors[chatId] != null
                                      ? Text(
                                          chatErrors[chatId]!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              color: Color(0xFFFF7B7B)),
                                        )
                                      : username.isEmpty
                                          ? null
                                          : Text('@$username'),
                                  trailing: _shareChatAction(
                                    chatId: chatId,
                                    messageId: sentMessageIds[chatId],
                                    sending: sendingChats.contains(chatId),
                                    canceling: cancelingChats.contains(chatId),
                                    completed: completedChats.contains(chatId),
                                    onSend: () async {
                                      if (chatId.isEmpty) {
                                        updateSheet(() {
                                          chatErrors[chatId] =
                                              'Chat id is missing.';
                                        });
                                        return;
                                      }
                                      updateSheet(() {
                                        sendingChats.add(chatId);
                                        completedChats.remove(chatId);
                                        chatErrors.remove(chatId);
                                      });
                                      try {
                                        final id = await state.auth
                                            .sendChatMessageWithId(
                                          chatId,
                                          text: uri.toString(),
                                          track: {
                                            'id': track.id,
                                            'title': track.title,
                                            'artists': track.artists,
                                            'album': track.album,
                                            'cover': track.cover,
                                            'duration': track.duration,
                                            'releaseType': track.releaseType,
                                          },
                                        );
                                        if (!sheetContext.mounted) return;
                                        updateSheet(() {
                                          sendingChats.remove(chatId);
                                          sentMessageIds[chatId] = id;
                                          sharedAny = true;
                                        });
                                      } catch (exception) {
                                        if (!sheetContext.mounted) return;
                                        updateSheet(() {
                                          sendingChats.remove(chatId);
                                          chatErrors[chatId] =
                                              'Could not share: $exception';
                                        });
                                      }
                                    },
                                    onCancel: () async {
                                      final id = sentMessageIds[chatId];
                                      if (id == null) return;
                                      updateSheet(() {
                                        cancelingChats.add(chatId);
                                        chatErrors.remove(chatId);
                                      });
                                      try {
                                        await state.auth
                                            .deleteChatMessage(chatId, id);
                                        if (!sheetContext.mounted) return;
                                        updateSheet(() {
                                          sentMessageIds.remove(chatId);
                                          cancelingChats.remove(chatId);
                                          completedChats.remove(chatId);
                                          expiredUndoChats.remove(chatId);
                                        });
                                      } catch (exception) {
                                        if (!sheetContext.mounted) return;
                                        updateSheet(() {
                                          cancelingChats.remove(chatId);
                                          chatErrors[chatId] =
                                              'Could not cancel: $exception';
                                          if (expiredUndoChats.remove(chatId)) {
                                            sentMessageIds.remove(chatId);
                                            completedChats.add(chatId);
                                          }
                                        });
                                      }
                                    },
                                    onComplete: () {
                                      if (sentMessageIds.containsKey(chatId) &&
                                          sheetContext.mounted) {
                                        updateSheet(() {
                                          if (cancelingChats.contains(chatId)) {
                                            expiredUndoChats.add(chatId);
                                          } else {
                                            sentMessageIds.remove(chatId);
                                            completedChats.add(chatId);
                                          }
                                        });
                                      }
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                    Center(
                      child: TextButton(
                        onPressed: isBusy || hasPendingUndo
                            ? null
                            : () async {
                                await Clipboard.setData(
                                    ClipboardData(text: uri.toString()));
                                if (sheetContext.mounted) {
                                  Navigator.of(sheetContext).pop(sharedAny);
                                }
                              },
                        child: const Text('Copy link'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

Future<void> openTrackRelease(AppState state, Track track) async {
  final release = await state.releaseForTrack(track);
  if (state.fullScreen) state.closeFull();
  if (release != null) {
    state.go(
      'release',
      arg: ReleaseArg(
        release,
        artist:
            release.artistName.isNotEmpty ? release.artistName : track.primary,
        highlightTrack: track.title,
      ),
    );
  } else if (track.primary.isNotEmpty) {
    state.go('artist', arg: track.primary);
  }
}

Future<void> openTrackMenu(
  BuildContext context,
  AppState state,
  Track track,
  Offset position, {
  String? playlistId,
}) async {
  final liked = state.liked.contains(track.key);
  final inQueue = state.queue.contains(track.id);
  final items = <LuminoMenuItem>[
    LuminoMenuItem('Play next', 'playnext', () async {
      await state.queueAdd(track.id, playNext: true);
    }),
    LuminoMenuItem(inQueue ? 'Remove from queue' : 'Add to queue', 'list',
        () async {
      if (inQueue) {
        final index = state.queue.indexOf(track.id);
        if (index >= 0) await state.queueRemove(index);
      } else {
        await state.queueAdd(track.id);
      }
    }),
    LuminoMenuItem('Add to playlist…', 'plus',
        () => showPlaylistPicker(context, state, track)),
    LuminoMenuItem(liked ? 'Remove from Liked Songs' : 'Like', 'heart', () {
      state.toggleLike(track);
    }, filled: liked),
    LuminoMenuItem('Go to artist', 'user', () {
      final artist = track.artists.isNotEmpty ? track.artists.first : '';
      if (artist.isNotEmpty) state.go('artist', arg: artist);
    }),
    LuminoMenuItem('Share', 'share', () async {
      await shareTrackInChat(context, state, track);
    }),
  ];
  if (playlistId != null) {
    items.insert(
      3,
      LuminoMenuItem('Remove from this playlist', 'close', () {
        final playlist =
            state.playlists.where((p) => p.id == playlistId).firstOrNull;
        if (playlist != null) {
          state.removeTrackFromPlaylist(playlist, track.id);
          state.showToast('Removed from ${playlist.name}');
        }
      }, danger: true),
    );
  }
  if (!context.mounted) return;
  await showLuminoMenu(context, position, items);
}

Future<bool> showPlaylistPicker(
    BuildContext context, AppState state, Track track) async {
  if (state.playlists.length == 1) {
    final playlist = state.playlists.single;
    final added = !playlist.ids.contains(track.id);
    state.addTrackToPlaylist(playlist, track.id);
    return added;
  }
  if (state.playlists.isEmpty) {
    final name = await showTextPrompt(context,
        title: 'New playlist', placeholder: 'My playlist');
    if (name == null) return false;
    if (!isPermittedPlaylistName(name)) {
      state.showToast('This name is not permitted.');
      return false;
    }
    state.createPlaylist(name, firstId: track.id);
    state.showToast('Added to $name');
    return true;
  }
  if (!context.mounted) return false;
  var createdPlaylist = false;
  final added = await showGlassDialog<bool>(
    context,
    width: 380,
    builder: (dialogContext) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Add to playlist',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('${track.artists.join(', ')} — ${track.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13, color: ThemeScope.of(context).mutedForeground)),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final playlist in state.playlists)
                  HoverBuilder(
                    builder: (context, hovered) => GestureDetector(
                      onTap: () {
                        final added = !playlist.ids.contains(track.id);
                        state.addTrackToPlaylist(playlist, track.id);
                        Navigator.of(dialogContext).pop(added);
                      },
                      child: Container(
                        height: 46,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: hovered
                              ? const Color(0x14FFFFFF)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            PlaylistCover(
                                playlist: playlist, size: 34, radius: 8),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(playlist.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500)),
                            ),
                            Text('${playlist.ids.length}',
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: ThemeScope.of(context)
                                        .mutedForeground)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () async {
            Navigator.of(dialogContext).pop();
            final name = await showTextPrompt(context,
                title: 'New playlist', placeholder: 'My playlist');
            if (name == null) return;
            if (!isPermittedPlaylistName(name)) {
              state.showToast('This name is not permitted.');
              return;
            }
            state.createPlaylist(name, firstId: track.id);
            state.showToast('Added to $name');
            createdPlaylist = true;
          },
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: const [
              LIcon('plus', size: 18, color: Colors.white),
              SizedBox(width: 12),
              Text('New playlist',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ],
    ),
  );
  return added ?? createdPlaylist;
}

Future<void> createPlaylistFlow(BuildContext context, AppState state) async {
  final name = await showTextPrompt(context,
      title: 'New playlist', placeholder: 'My playlist');
  if (name == null) return;
  if (!isPermittedPlaylistName(name)) {
    state.showToast('This name is not permitted.');
    return;
  }
  state.createPlaylist(name);
  state.showToast('Playlist created');
}

Future<void> renamePlaylistFlow(
    BuildContext context, AppState state, Playlist playlist) async {
  final name = await showTextPrompt(
    context,
    title: 'Rename playlist',
    value: playlist.name,
    okLabel: 'Save',
  );
  if (name == null) return;
  if (!isPermittedPlaylistName(name)) {
    state.showToast('This name is not permitted.');
    return;
  }
  playlist.name = name;
  state.save();
  state.refresh();
  state.showToast('Playlist renamed');
}

Future<void> deletePlaylistFlow(
    BuildContext context, AppState state, Playlist playlist) async {
  final ok = await confirmDialog(
    context,
    title: 'Delete playlist?',
    message:
        '“${playlist.name}” will be removed from your library. This cannot be undone.',
    confirmLabel: 'Delete',
    danger: true,
  );
  if (!ok) return;
  state.deletePlaylist(playlist);
  if (state.pageName == 'playlist') state.go('library', push: false);
  state.showToast('Playlist deleted');
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool danger = false,
}) async {
  final result = await showGlassDialog<bool>(
    context,
    width: 400,
    builder: (dialogContext) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(message,
            style: TextStyle(
                fontSize: 13.5,
                color: ThemeScope.of(context).mutedForeground,
                height: 1.45)),
        const SizedBox(height: 18),
        Row(children: [
          Expanded(
            child: GhostButton(
              label: 'Cancel',
              height: 40,
              padding: 0,
              onTap: () => Navigator.of(dialogContext).pop(false),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: HoverBuilder(
              builder: (context, hovered) => GestureDetector(
                onTap: () => Navigator.of(dialogContext).pop(true),
                child: Container(
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: danger
                        ? (hovered
                            ? const Color(0xFFFF8E8E)
                            : const Color(0xFFFF6F6F))
                        : (hovered ? const Color(0xFFE8E8EE) : Colors.white),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    confirmLabel,
                    style: TextStyle(
                      color: danger
                          ? const Color(0xFF1A0505)
                          : const Color(0xFF111111),
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ],
    ),
  );
  return result ?? false;
}

Future<void> shareArtist(
    BuildContext context, AppState state, String name) async {
  await copyToClipboard('${displayName(name)} — artist on Lumino');
  state.showToast('Artist link copied to clipboard');
}

/// A 34px square playlist cover that matches the renderer's `plArt` look.
class PlaylistCover extends StatelessWidget {
  const PlaylistCover(
      {super.key, required this.playlist, this.size = 34, this.radius = 8});
  final Playlist playlist;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final initial = playlist.name.isEmpty
        ? '?'
        : playlist.name.characters.first.toUpperCase();
    if (playlist.cover.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          width: size,
          height: size,
          child: imageWidget(playlist.cover),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF3A3A44), Color(0xFF16161A)],
          ),
        ),
        alignment: Alignment.center,
        child: Text(initial,
            style: TextStyle(
                fontSize: size * 0.42,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
      ),
    );
  }
}
