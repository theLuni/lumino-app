import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'design.dart';

class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key, required this.state, this.mobile = false});
  final AppState state;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final items = <(int, Track)>[];
    for (var i = 0; i < state.queue.length; i++) {
      final track = state.byId[state.queue[i]];
      if (track != null) items.add((i, track));
    }
    final size = MediaQuery.of(context).size;
    final light = ThemeScope.of(context).light;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      top: mobile ? 8 : 62,
      bottom: mobile ? 8 : 92,
      left: mobile ? 8 : null,
      right: mobile ? 8 : 16,
      width: mobile ? null : 320,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 240),
        opacity: state.queueOpen ? 1 : 0,
        child: IgnorePointer(
          ignoring: !state.queueOpen,
          child: Transform.translate(
            offset: Offset(state.queueOpen ? 0 : size.width * 0.12, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 14, 10, 14),
                decoration: BoxDecoration(
                  color:
                      light ? const Color(0xF8FFFFFF) : const Color(0xE00E0E14),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: light
                          ? const Color(0x1F17181C)
                          : const Color(0x14FFFFFF)),
                ),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 4, 10),
                        child: Row(children: [
                          const Expanded(
                            child: Text('Queue',
                                style: TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700)),
                          ),
                          IconAction(
                            icon: 'close',
                            size: 30,
                            iconSize: 15,
                            tooltip: 'Close queue',
                            onTap: state.toggleQueue,
                          ),
                        ]),
                      ),
                      Expanded(
                        child: items.isEmpty
                            ? Center(
                                child: Text('Queue is empty',
                                    style: TextStyle(
                                        fontSize: 14,
                                        color: ThemeScope.of(context)
                                            .mutedForeground)),
                              )
                            : ListView.builder(
                                padding: EdgeInsets.zero,
                                itemCount: items.length,
                                itemBuilder: (context, index) {
                                  final (position, track) = items[index];
                                  return _QueueRow(
                                    state: state,
                                    track: track,
                                    index: position,
                                    current: position == state.qi,
                                  );
                                },
                              ),
                      ),
                    ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueRow extends StatefulWidget {
  const _QueueRow({
    required this.state,
    required this.track,
    required this.index,
    required this.current,
  });

  final AppState state;
  final Track track;
  final int index;
  final bool current;

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final track = widget.track;
    final light = ThemeScope.of(context).light;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => state.jumpTo(widget.index),
        child: Container(
          height: 52,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: _hovered
                ? (light ? const Color(0x0D000000) : const Color(0x0FFFFFFF))
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(children: [
            SizedBox(
              width: 38,
              height: 38,
              child: CoverArt(
                track: track,
                radius: 6,
                child: widget.current
                    ? Container(
                        color: const Color(0x80000000),
                        child: Center(
                          child: LIcon(state.playing ? 'pause' : 'play',
                              size: 14, color: Colors.white),
                        ),
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 1),
                  ArtistsText(
                    artists: track.artists,
                    onArtist: (name) => state.go('artist', arg: name),
                    style: TextStyle(
                        fontSize: 12,
                        color: ThemeScope.of(context).mutedForeground,
                        height: 1.2),
                  ),
                ],
              ),
            ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: _hovered || widget.current ? 0.85 : 0,
              child: IconAction(
                icon: 'close',
                size: 26,
                iconSize: 14,
                color: Colors.white,
                onTap: () => state.queueRemove(widget.index),
                tooltip: 'Remove from queue',
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
