import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/importer.dart';
import '../core/models.dart';
import '../core/utils.dart';
import 'design.dart';

Future<void> showImporter(BuildContext context, AppState state) async {
  await showGlassDialog<void>(
    context,
    width: 580,
    padding: const EdgeInsets.all(22),
    builder: (dialogContext) => _ImporterDialog(
        state: state, onClose: () => Navigator.of(dialogContext).pop()),
  );
}

enum _Stage { pick, preview, run, done }

class _ImporterDialog extends StatefulWidget {
  const _ImporterDialog({required this.state, required this.onClose});
  final AppState state;
  final VoidCallback onClose;

  @override
  State<_ImporterDialog> createState() => _ImporterDialogState();
}

class _ImporterDialogState extends State<_ImporterDialog> {
  _Stage _stage = _Stage.pick;
  List<PlaylistImportList> _lists = [];
  final Set<int> _selected = {};
  final TextEditingController _paste = TextEditingController();
  bool _running = false;
  int _total = 0;
  int _done = 0;
  int _added = 0;
  String _error = '';
  final Map<String, List<Track>> _addedByList = {};
  final Map<String, Set<String>> _addedKeysByList = {};
  final List<String> _missing = [];
  final List<Track> _likedFound = [];
  final Set<String> _likedKeys = {};
  bool _cancelled = false;

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'json', 'txt', 'tsv'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    String text;
    try {
      text = await File(path).readAsString();
    } catch (_) {
      widget.state.showToast("Couldn't read that file");
      return;
    }
    _load(ImportParser.parse(text, picked!.files.single.name));
  }

  void _loadFromPaste() {
    final text = _paste.text.trim();
    if (text.isEmpty) return;
    _load(ImportParser.parse(text, 'Pasted list'));
  }

  void _load(List<PlaylistImportList> lists) {
    final usable = lists.where((l) => l.items.isNotEmpty).toList();
    if (usable.isEmpty) {
      widget.state.showToast('No tracks found in that file');
      return;
    }
    setState(() {
      _lists = usable;
      _selected
        ..clear()
        ..addAll(List.generate(usable.length, (i) => i));
      _stage = _Stage.preview;
    });
  }

  Future<void> _run() async {
    final chosen =
        _lists.where((l) => _selected.contains(_lists.indexOf(l))).toList();
    if (chosen.isEmpty) return;
    setState(() {
      _stage = _Stage.run;
      _running = true;
      _cancelled = false;
      _error = '';
      _added = 0;
      _done = 0;
      _addedByList.clear();
      _addedKeysByList.clear();
      _missing.clear();
      _likedFound.clear();
      _likedKeys.clear();
      _total = chosen.fold<int>(0, (sum, list) => sum + list.items.length);
    });

    final queue = <({int listIndex, PlaylistImportItem item})>[];
    for (var i = 0; i < chosen.length; i++) {
      for (final item in chosen[i].items) {
        queue.add((listIndex: i, item: item));
      }
    }
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (!mounted || _cancelled) return;
        if (next >= queue.length) return;
        final job = queue[next++];
        Track? track;
        try {
          track = await widget.state.importFind(job.item);
        } catch (_) {
          track = null;
        }
        if (!mounted) return;
        if (_cancelled) return;
        if (track == null) {
          _missing.add('${job.item.artist} - ${job.item.title}'.trim());
        } else {
          final list = chosen[job.listIndex];
          if (list.kind == 'liked') {
            if (!widget.state.liked.contains(track.key) &&
                _likedKeys.add(track.key)) {
              _likedFound.add(track);
              _added++;
            }
          } else {
            final name = list.name.isEmpty ? 'Playlist' : list.name;
            final existing = widget.state.playlists
                .where((p) => norm(p.name) == norm(name))
                .firstOrNull;
            final playlistName = existing?.name ?? name;
            final seen = _addedKeysByList.putIfAbsent(norm(playlistName), () {
              return {
                if (existing != null)
                  for (final id in existing.ids)
                    if (widget.state.byId[id] != null)
                      widget.state.byId[id]!.key,
              };
            });
            if (seen.add(track.key)) {
              _addedByList.putIfAbsent(playlistName, () => []).add(track);
              _added++;
            }
          }
        }
        _done++;
        if (mounted) setState(() {});
      }
    }

    await Future.wait([worker(), worker(), worker(), worker(), worker()]);
    if (!mounted || _cancelled) return;

    // Persist only new likes and tracks not already present in each playlist.
    for (final track in _likedFound) {
      widget.state.liked.add(track.key);
      widget.state.registerTrack(track);
    }
    for (final entry in _addedByList.entries) {
      final existing = widget.state.playlists
          .where((p) => norm(p.name) == norm(entry.key))
          .firstOrNull;
      if (existing != null) {
        for (final track in entry.value) {
          final duplicate = existing.ids.contains(track.id) ||
              existing.ids.any((id) => widget.state.byId[id]?.key == track.key);
          if (!duplicate) existing.ids.add(track.id);
        }
      } else {
        widget.state.createPlaylist(entry.key);
        final playlist = widget.state.playlists.last;
        for (final track in entry.value) {
          if (!playlist.ids.contains(track.id)) playlist.ids.add(track.id);
        }
      }
    }
    widget.state.save();
    widget.state.refresh();
    setState(() {
      _running = false;
      _stage = _Stage.done;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Expanded(
            child: Text('Import music',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          IconAction(
            icon: 'close',
            size: 30,
            iconSize: 15,
            tooltip: 'Close',
            onTap: _stage == _Stage.run ? null : widget.onClose,
          ),
        ]),
        const SizedBox(height: 14),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: switch (_stage) {
            _Stage.pick => _pickStage(),
            _Stage.preview => _previewStage(),
            _Stage.run => _runStage(),
            _Stage.done => _doneStage(),
          },
        ),
      ],
    );
  }

  Widget _pickStage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x24FFFFFF)),
            color: const Color(0x08FFFFFF),
          ),
          child: Column(children: [
            const LIcon('folderPlus', size: 30, color: Color(0x8CFFFFFF)),
            const SizedBox(height: 12),
            const Text('Choose a file exported from another service',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center),
            const SizedBox(height: 6),
            const Text(
                'CSV, JSON or a plain list — one “Artist - Title” per line.',
                style: TextStyle(fontSize: 12.5, color: kMuted),
                textAlign: TextAlign.center),
            const SizedBox(height: 14),
            PlayButton(label: 'Choose file…', onTap: _pickFile),
          ]),
        ),
        const SizedBox(height: 16),
        const Text('…or paste a list',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextField(
          controller: _paste,
          maxLines: 5,
          style:
              const TextStyle(fontSize: 13.5, color: Colors.white, height: 1.4),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: 'Artist - Title\nArtist - Title',
            hintStyle: const TextStyle(color: Color(0x4DFFFFFF)),
            filled: true,
            fillColor: const Color(0x0FFFFFFF),
            contentPadding: const EdgeInsets.all(14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0x1AFFFFFF)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0x1AFFFFFF)),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: ChipButton(label: 'Preview', onTap: _loadFromPaste),
        ),
      ],
    );
  }

  Widget _previewStage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_lists.length} ${plural(_lists.length, 'list', 'lists')} · '
          '${_lists.fold<int>(0, (sum, l) => sum + l.items.length)} tracks',
          style: const TextStyle(fontSize: 13, color: kMuted),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 340),
          child: SingleChildScrollView(
            child: Column(children: [
              for (var i = 0; i < _lists.length; i++) _previewRow(i),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          GhostButton(
              label: 'Back',
              height: 38,
              padding: 16,
              onTap: () => setState(() => _stage = _Stage.pick)),
          const Spacer(),
          PlayButton(
            label:
                'Import ${_selected.length} ${plural(_selected.length, 'list', 'lists')}',
            onTap: _selected.isEmpty ? null : _run,
          ),
        ]),
      ],
    );
  }

  Widget _previewRow(int index) {
    final list = _lists[index];
    final checked = _selected.contains(index);
    final kind = list.kind == 'liked' ? 'Liked songs' : 'Playlist';
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        onTap: () => setState(() {
          if (checked) {
            _selected.remove(index);
          } else {
            _selected.add(index);
          }
        }),
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: hovered ? const Color(0x12FFFFFF) : const Color(0x08FFFFFF),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: const Color(0x0FFFFFFF)),
          ),
          child: Row(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: checked ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                    color: checked ? Colors.white : const Color(0x40FFFFFF),
                    width: 1.4),
              ),
              child: checked
                  ? const LIcon('check', size: 12, color: Color(0xFF111111))
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(list.name.isEmpty ? kind : list.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 1),
                    Text(
                        '$kind · ${list.items.length} ${plural(list.items.length, 'track', 'tracks')}',
                        style: const TextStyle(fontSize: 11.5, color: kMuted)),
                  ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _runStage() {
    final total = mathMax(1, _total);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Importing your music',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(
          _cancelled
              ? 'Cancelled'
              : '$_done of $_total tracks · $_added matched',
          style: const TextStyle(fontSize: 13, color: kMuted),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: _done / total,
            minHeight: 6,
            backgroundColor: const Color(0x14FFFFFF),
            valueColor: const AlwaysStoppedAnimation(Color(0xFFE9E9EF)),
          ),
        ),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(_error,
              style: const TextStyle(fontSize: 12.5, color: Color(0xFFFF9A9A))),
        ],
        const SizedBox(height: 16),
        Row(children: [
          const Spacer(),
          GhostButton(
            label: _running ? 'Cancel' : 'Close',
            height: 38,
            padding: 16,
            onTap: () {
              if (_running) {
                setState(() {
                  _cancelled = true;
                  _running = false;
                  _stage = _Stage.done;
                });
              } else {
                widget.onClose();
              }
            },
          ),
        ]),
      ],
    );
  }

  Widget _doneStage() {
    final playlists = _addedByList.entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
                color: Color(0x1FFFFFFF), shape: BoxShape.circle),
            alignment: Alignment.center,
            child: const LIcon('check', size: 18, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_cancelled ? 'Import stopped' : 'Import complete',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                '$_added ${plural(_added, 'track', 'tracks')} added'
                '${_likedFound.isEmpty ? '' : ' · ${_likedFound.length} liked'}',
                style: const TextStyle(fontSize: 12.5, color: kMuted),
              ),
            ]),
          ),
        ]),
        if (playlists.isNotEmpty) ...[
          const SizedBox(height: 14),
          for (final entry in playlists)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                const LIcon('list', size: 14, color: Color(0x8CFFFFFF)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(entry.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                ),
                Text('${entry.value.length}',
                    style: const TextStyle(fontSize: 12, color: kMuted)),
              ]),
            ),
        ],
        if (_missing.isNotEmpty) ...[
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: Text(
                  '${_missing.length} ${plural(_missing.length, 'track', 'tracks')} not found',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            ChipButton(
              label: 'Copy list',
              height: 28,
              fontSize: 11.5,
              ghost: true,
              onTap: () async {
                await copyToClipboard(_missing.join('\n'));
                widget.state.showToast('Missing tracks copied to clipboard');
              },
            ),
          ]),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 140),
            child: SingleChildScrollView(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in _missing)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(line,
                            style:
                                const TextStyle(fontSize: 12, color: kMuted)),
                      ),
                  ]),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(children: [
          const Spacer(),
          PlayButton(
            label: 'Done',
            onTap: () {
              widget.onClose();
              if (playlists.isNotEmpty) widget.state.go('library');
            },
          ),
        ]),
      ],
    );
  }
}

int mathMax(int a, int b) => a > b ? a : b;
