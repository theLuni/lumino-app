import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/app_state.dart';
import '../core/models.dart';

/// Высота одной строки трека. Строки фиксированной высоты, поэтому окно
/// видимых строк считается арифметикой, без измерения каждой строки.
const double kTrackRowExtent = 60;

/// Сколько строк держать сверху и снизу от видимой области.
const int kRowBuffer = 10;

/// Виртуализированный список строк внутри обычного родительского скролла.
///
/// Строится только окно: видимые строки ± [kRowBuffer]. Остальное — пустые
/// заглушки нужной высоты, чтобы скролл и раскладка не менялись. Обложки
/// ставятся в очередь только для строк из окна, поэтому запросов к внешним
/// сервисам идёт ровно столько, сколько пользователь реально видит.
class LazyTrackRows extends StatefulWidget {
  const LazyTrackRows({
    super.key,
    required this.state,
    required this.tracks,
    required this.rowBuilder,
  });

  final AppState state;
  final List<Track> tracks;
  final Widget Function(BuildContext context, int index) rowBuilder;

  @override
  State<LazyTrackRows> createState() => _LazyTrackRowsState();
}

class _LazyTrackRowsState extends State<LazyTrackRows> {
  ScrollPosition? _position;
  int _first = 0;
  int _last = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_onScroll);
      _position = position;
      _position?.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_onScroll);
    super.dispose();
  }

  /// Окно [первая, последняя] строка включительно, либо null если ещё не разложено.
  (int, int)? _window() {
    final n = widget.tracks.length;
    if (n == 0) return null;
    final box = context.findRenderObject();
    final position = _position;
    if (box is! RenderBox || !box.attached || position == null || !position.hasPixels) {
      return null;
    }
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;

    // Смещение начала списка внутри прокручиваемого контента.
    final listTop = viewport.getOffsetToReveal(box, 0).offset;
    final top = position.pixels - listTop;
    final bottom = top + position.viewportDimension;

    final first = (top / kTrackRowExtent).floor() - kRowBuffer;
    final last = (bottom / kTrackRowExtent).ceil() + kRowBuffer;
    return (first.clamp(0, n - 1), last.clamp(0, n - 1));
  }

  void _onScroll() {
    final window = _window();
    if (window == null) return;
    if (window.$1 != _first || window.$2 != _last) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.tracks.length;
    if (n == 0) return const SizedBox.shrink();

    // До первой раскладки окно неизвестно: берём начало списка.
    final window = _window() ?? (0, math.min(n - 1, kRowBuffer * 2));
    _first = window.$1;
    _last = window.$2;

    widget.state.ensureCovers(widget.tracks.sublist(_first, _last + 1), priority: true);

    final children = <Widget>[
      if (_first > 0) SizedBox(height: _first * kTrackRowExtent),
      for (var i = _first; i <= _last; i++)
        SizedBox(height: kTrackRowExtent, child: widget.rowBuilder(context, i)),
      if (_last < n - 1) SizedBox(height: (n - 1 - _last) * kTrackRowExtent),
    ];
    return Column(children: children);
  }
}
