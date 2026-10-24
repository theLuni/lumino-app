import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/app_log.dart';
import '../core/performance_monitor.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path_drawing/path_drawing.dart';

import '../core/models.dart';
import '../core/utils.dart';

// ---------------------------------------------------------------------------
// Design tokens (taken from the Electron stylesheet)
// ---------------------------------------------------------------------------

const Color kBg = Color(0xFF080808);
const Color kText = Color(0xFFF4F5F8);
const Color kMuted = Color(0x8FFFFFFF);
const Color kStroke = Color(0x1AFFFFFF);
const List<Color> kMixColors = [
  Color(0xFF19F0E0),
  Color(0xFFC6F432),
  Color(0xFFFF9B4A),
  Color(0xFFFF6FAE),
  Color(0xFFB39BFF),
];

const List<BoxShadow> kPanelShadow = [
  BoxShadow(color: Color(0x59000000), blurRadius: 32, offset: Offset(0, 10)),
];

class ThemeScope extends InheritedWidget {
  const ThemeScope(
      {super.key,
      required this.light,
      required this.black,
      this.openArtwork = true,
      required super.child});
  final bool light;
  final bool black;
  final bool openArtwork;

  Color get foreground => light ? const Color(0xFF17181C) : kText;
  Color get mutedForeground => light ? const Color(0xFF686B73) : kMuted;
  Color get surface =>
      light ? const Color(0xF7FFFFFF) : const Color(0xE6080808);
  Color get stroke => light ? const Color(0x1F17181C) : kStroke;

  static ThemeScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    return scope ??
        const ThemeScope(light: false, black: false, child: SizedBox.shrink());
  }

  @override
  bool updateShouldNotify(ThemeScope oldWidget) =>
      light != oldWidget.light ||
      black != oldWidget.black ||
      openArtwork != oldWidget.openArtwork;
}

class LuminoBadge extends StatelessWidget {
  const LuminoBadge({super.key, this.size = 16});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: ThemeScope.of(context).light
              ? const Color(0x3317181C)
              : const Color(0x80FFFFFF),
          width: 1.2,
        ),
      ),
      child: Image.asset('assets/logo.png', fit: BoxFit.cover),
    );
  }
}

/// Kept as a wrapper so callers can opt images out of app-surface styling.
class OriginalColors extends StatelessWidget {
  const OriginalColors({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

// ---------------------------------------------------------------------------
// Icons (the exact path data from the Electron renderer)
// ---------------------------------------------------------------------------

const Map<String, String> kIconPaths = {
  'home': 'M3 11.5 12 4l9 7.5 M5.5 10v9.5h13V10 M10 19.5v-5h4v5',
  'search': 'M17.5 11a6.5 6.5 0 1 1-13 0 6.5 6.5 0 0 1 13 0 Z M20 20l-4.2-4.2',
  'library': 'M5 4h4v16H5z M11 4h4v16h-4z M17 5.5l3.6 1-3.4 13.6-3.6-1z',
  'chats': 'M4 5.5h16v11H9l-5 4v-15z M8 10h8 M8 13.5h5',
  'gear':
      'M12 8.8a3.2 3.2 0 1 0 0 6.4 3.2 3.2 0 0 0 0-6.4z M19.4 13.5a7.7 7.7 0 0 0 0-3l1.9-1.5-1.9-3.3-2.3.9a7.6 7.6 0 0 0-2.6-1.5L14.2 2.6h-3.8l-.4 2.5a7.6 7.6 0 0 0-2.6 1.5l-2.3-.9-1.9 3.3 1.9 1.5a7.7 7.7 0 0 0 0 3l-1.9 1.5 1.9 3.3 2.3-.9a7.6 7.6 0 0 0 2.6 1.5l.4 2.5h3.8l.4-2.5a7.6 7.6 0 0 0 2.6-1.5l2.3.9 1.9-3.3z',
  'play': 'M7 4.5v15l13-7.5z',
  'pause':
      'M7 4.5h2a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1v-13a1 1 0 0 1 1-1z M15 4.5h2a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-2a1 1 0 0 1-1-1v-13a1 1 0 0 1 1-1z',
  'prev': 'M18 5v14L8.5 12z M5 5h2.4v14H5z',
  'next': 'M6 5v14l9.5-7z M16.6 5H19v14h-2.4z',
  'heart':
      'M12 20s-7.5-4.6-7.5-10.2A4.3 4.3 0 0 1 12 7.2a4.3 4.3 0 0 1 7.5 2.6C19.5 15.4 12 20 12 20z',
  'shuffle':
      'M3 17h3c3 0 4-2 5.5-5S15 7 18 7h3 M3 7h3c1.6 0 2.8.7 3.7 1.8 M14.3 15.2c.9 1.1 2.1 1.8 3.7 1.8h3 M19 4.5l2.5 2.5L19 9.5 M19 14.5l2.5 2.5-2.5 2.5',
  'repeat':
      'M17 3.5 20.5 7 17 10.5 M3.5 11V9.5A2.5 2.5 0 0 1 6 7h14.5 M7 20.5 3.5 17 7 13.5 M20.5 13v1.5a2.5 2.5 0 0 1-2.5 2.5H3.5',
  'repeat1':
      'M17 3.5 20.5 7 17 10.5 M3.5 11V9.5A2.5 2.5 0 0 1 6 7h14.5 M7 20.5 3.5 17 7 13.5 M20.5 13v1.5a2.5 2.5 0 0 1-2.5 2.5H3.5 M11 10.5l1.5-.8v4.6',
  'volume':
      'M4 9.5v5h3.5l5 4v-13l-5 4z M16 9a4 4 0 0 1 0 6 M18.5 6.5a8 8 0 0 1 0 11',
  'expand': 'M14 4h6v6 M10 20H4v-6 M20 4l-7 7 M4 20l7-7',
  'panel':
      'M6.5 4.5h11a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3h-11a3 3 0 0 1-3-3v-9a3 3 0 0 1 3-3z M14 4.5v15',
  'kebab':
      'M12 5a1.8 1.8 0 1 1 0 0z M12 12a1.8 1.8 0 1 1 0 0z M12 19a1.8 1.8 0 1 1 0 0z',
  'plus': 'M12 5v14 M5 12h14',
  'folderPlus':
      'M3.5 7.5a2 2 0 0 1 2-2h3.8l2 2.2h7.2a2 2 0 0 1 2 2v7.8a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z M12 10.8v5 M9.5 13.3h5',
  'share':
      'M13 5.5 20 12l-7 6.5v-3.8c-4.2 0-6.7 1.4-8.5 4.3.5-4.6 3.2-8.3 8.5-8.8z',
  'sun':
      'M12 4.5a7.5 7.5 0 1 0 0 15 7.5 7.5 0 0 0 0-15z M12 1.5v1.7 M12 20.8v1.7 M4.57 4.57l1.2 1.2 M18.23 18.23l1.2 1.2 M1.5 12h1.7 M20.8 12h1.7 M4.57 19.43l1.2-1.2 M18.23 5.77l1.2-1.2',
  'sunrise':
      'M3 18.5h18 M5 16a7 7 0 0 1 14 0 M12 2v5 M4.9 7l3.2 3.2 M19.1 7l-3.2 3.2 M2 11h4 M18 11h4',
  'chevL': 'M15 5l-7 7 7 7',
  'chevR': 'M9 5l7 7-7 7',
  'chevD': 'M5 9l7 7 7-7',
  'back': 'M19 12H5 M11 6l-6 6 6 6',
  'arrowUp': 'M12 19V5 M5.5 11.5 12 5l6.5 6.5',
  'exit': 'M10 17l5-5-5-5 M15 12H3 M21 4v16',
  'min': 'M5.5 12h13',
  'max':
      'M7.5 5.5h9a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-9a2 2 0 0 1-2-2v-9a2 2 0 0 1 2-2z',
  'restore':
      'M5 8.5h8.5a2 2 0 0 1 2 2V19a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2z M9 8.5V7a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2h-1.5',
  'close': 'M6 6l12 12 M18 6 6 18',
  'trash': 'M4 7h16 M10 11v6 M14 11v6 M6 7l1 14h10l1-14 M9 7V4h6v3',
  'clock': 'M20 12a8 8 0 1 1-16 0 8 8 0 0 1 16 0z M12 7.5V12l3 2',
  'calendar':
      'M7 3v3 M17 3v3 M4 6h16v15H4z M4 10h16 M8 14h1 M12 14h1 M16 14h1 M8 18h1 M12 18h1',
  'bolt': 'M13 2 4 14h6l-1 8 10-13h-6z',
  'edit': 'M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4.5 1.5L4 16z M14.5 5.5l4 4',
  'spark':
      'M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z',
  'flame':
      'M12 3c1 3.5 5 5.5 5 10a5 5 0 0 1-10 0c0-2 1-3.2 2-4.2.2 1.5.8 2.2 1.5 2.7C10.2 8 10.5 5.5 12 3z',
  'list': 'M4 7h11 M4 12h11 M4 17h7 M18 14v6 M15 17h6',
  'playnext': 'M5 5v14l8-7z M17 5v14',
  'user':
      'M15.5 8a3.5 3.5 0 1 1-7 0 3.5 3.5 0 0 1 7 0z M5 20c.8-3.8 3.6-5.5 7-5.5s6.2 1.7 7 5.5',
  'note':
      'M9 18V6l10-2v12 M9 18a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0z M19 16a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0z',
  'check': 'M5 12.5l4.5 4.5L19 7.5',
  'camera':
      'M5.8 7h12.4a2.6 2.6 0 0 1 2.6 2.6v7.3a2.6 2.6 0 0 1-2.6 2.6H5.8a2.6 2.6 0 0 1-2.6-2.6V9.6A2.6 2.6 0 0 1 5.8 7z M12 16.6a3.4 3.4 0 1 1 0-6.8 3.4 3.4 0 0 1 0 6.8z M8.3 7 9.7 4.6h4.6L15.7 7',
  'mail': 'M3.5 6.5h17v11h-17z M3.5 6.8l8.5 7 8.5-7',
  'lock': 'M6 10.5h12v9H6z M8.5 10.5V7.8a3.5 3.5 0 0 1 7 0v2.7',
  'eye':
      'M2.5 12S6.7 6 12 6s9.5 6 9.5 6-4.2 6-9.5 6S2.5 12 2.5 12z M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
  'eyeOff':
      'M2.5 12S6.7 6 12 6s9.5 6 9.5 6-4.2 6-9.5 6S2.5 12 2.5 12z M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z M4 4l16 16',
  'imageOff':
      'M3.5 5.5h17v13h-17z M3.5 15l4.5-4.5 3.5 3.5 2-2 7 6.5 M8 8h.01 M4 4l16 16',
};

const Set<String> _filledIcons = {
  'play',
  'pause',
  'prev',
  'next',
  'kebab',
  'spark',
  'flame',
  'bolt'
};

class LIcon extends StatelessWidget {
  const LIcon(this.name, {super.key, this.size = 20, this.color, this.filled});
  final String name;
  final double size;
  final Color? color;
  final bool? filled;

  @override
  Widget build(BuildContext context) {
    final scope = ThemeScope.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _IconPainter(
          kIconPaths[name] ?? '',
          color ?? scope.foreground,
          filled ?? _filledIcons.contains(name),
          size,
        ),
        size: Size(size, size),
      ),
    );
  }
}

final Map<String, Path> _iconPathCache = {};

Path _pathFor(String data) =>
    _iconPathCache.putIfAbsent(data, () => parseSvgPathData(data));

class _IconPainter extends CustomPainter {
  _IconPainter(this.pathData, this.color, this.filled, this.size);
  final String pathData;
  final Color color;
  final bool filled;
  final double size;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final scale = canvasSize.width / 24;
    canvas.save();
    canvas.scale(scale);
    final paint = Paint()
      ..color = color
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = filled ? 1.2 : 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final path = _pathFor(pathData);
    canvas.drawPath(path, paint);
    if (filled) {
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_IconPainter old) =>
      old.pathData != pathData ||
      old.color != color ||
      old.filled != filled ||
      old.size != size;
}

class BoltIcon extends StatelessWidget {
  const BoltIcon({super.key, this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _BoltPainter(), size: Size(size, size)),
    );
  }
}

class _BoltPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    canvas.drawCircle(const Offset(12, 12), 11, Paint()..color = Colors.white);
    final path = parseSvgPathData('M13 5 8 13h3.5L10.5 19 16 11h-3.5z');
    canvas.drawPath(path, Paint()..color = const Color(0xFF111111));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class VerifiedIcon extends StatelessWidget {
  const VerifiedIcon({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _VerifiedPainter(), size: Size(size, size)),
    );
  }
}

class _VerifiedPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    canvas.drawCircle(
        const Offset(12, 12), 11, Paint()..color = const Color(0xFF1D9BF0));
    final path = parseSvgPathData('M7 12.5l3.2 3.2L17 9');
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// Surfaces
// ---------------------------------------------------------------------------

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 12,
    this.dark = false,
    this.blur =
        0, // BackdropFilter re-blurs every frame; only opt in when needed
    this.padding = EdgeInsets.zero,
    this.borderColor,
    this.shadows,
  });

  final Widget child;
  final double radius;
  final bool dark;
  final double blur;
  final EdgeInsets padding;
  final Color? borderColor;
  final List<BoxShadow>? shadows;

  @override
  Widget build(BuildContext context) {
    final light = ThemeScope.of(context).light;
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: light
            ? const [Color(0xF7FFFFFF), Color(0xF0F1F2F5)]
            : dark
                ? const [Color(0xD118181E), Color(0xD10A0A0E)]
                : const [Color(0x1AFFFFFF), Color(0x09FFFFFF)],
      ),
      border: Border.all(
        color: borderColor ??
            (light
                ? const Color(0x1F17181C)
                : (dark ? const Color(0x12FFFFFF) : kStroke)),
      ),
      boxShadow: shadows ??
          (light
              ? const [
                  BoxShadow(
                      color: Color(0x16000000),
                      blurRadius: 24,
                      offset: Offset(0, 8))
                ]
              : kPanelShadow),
    );
    final content =
        Container(padding: padding, decoration: decoration, child: child);
    if (blur <= 0) return content;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: content,
      ),
    );
  }
}

class HoverBuilder extends StatefulWidget {
  const HoverBuilder(
      {super.key,
      required this.builder,
      this.cursor = SystemMouseCursors.click});
  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor cursor;

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(context, _hovered),
    );
  }
}

class TapArea extends StatelessWidget {
  const TapArea({
    super.key,
    required this.child,
    this.onTap,
    this.cursor = SystemMouseCursors.click,
    this.tooltip,
  });

  final Widget child;
  final VoidCallback? onTap;
  final MouseCursor cursor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final light = ThemeScope.of(context).light;
    Widget content = MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    );
    if (tooltip != null && tooltip!.isNotEmpty) {
      content = Tooltip(
        message: tooltip!,
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: light ? const Color(0xFFFDFDFE) : const Color(0xF01A1A1E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: light ? const Color(0x1F17181C) : const Color(0x1AFFFFFF)),
        ),
        textStyle: TextStyle(
            color: light ? const Color(0xFF17181C) : Colors.white,
            fontSize: 12),
        child: content,
      );
    }
    return content;
  }
}

// ---------------------------------------------------------------------------
// Images, covers, avatars
// ---------------------------------------------------------------------------

final Map<String, Uint8List> _dataUrlCache = {};
const int _imageCacheMaxBytes = 64 * 1024 * 1024;
const int _imageCacheMaxDownloadBytes = 12 * 1024 * 1024;
const int _imageCachePruneByteInterval = 16 * 1024 * 1024;
final Map<String, Future<Uint8List?>> _imageDownloads = {};
Future<Directory>? _imageCacheDirectory;
Future<void>? _imageCachePruning;
Future<void> _imageDecodeQueue = Future<void>.value();
DateTime _lastImageCachePrune = DateTime.fromMillisecondsSinceEpoch(0);
int _imageCacheBytesSincePrune = 0;

/// The same data URL used to be base64-decoded on every build. Returning the
/// identical Uint8List lets Flutter's image cache recognise it and skip decoding.
Uint8List? _decodeDataUrl(String value) {
  final cached = _dataUrlCache[value];
  if (cached != null) return cached;
  if (!value.startsWith('data:image/')) return null;
  final comma = value.indexOf(',');
  if (comma < 0) return null;
  try {
    final bytes = base64Decode(value.substring(comma + 1));
    if (_dataUrlCache.length > 300) _dataUrlCache.clear();
    _dataUrlCache[value] = bytes;
    return bytes;
  } catch (_) {
    return null;
  }
}

String _imageCacheKey(String url) {
  var high = 0xcbf29ce4;
  var low = 0x84222325;
  for (final byte in utf8.encode(url)) {
    low ^= byte;
    final lowBeforeMultiply = low;
    final product = lowBeforeMultiply * 435;
    final carry = product ~/ 0x100000000;
    low = product & 0xffffffff;
    high = (high * 435 + ((lowBeforeMultiply << 8) & 0xffffffff) + carry) &
        0xffffffff;
  }
  return '${high.toRadixString(16).padLeft(8, '0')}'
      '${low.toRadixString(16).padLeft(8, '0')}';
}

Future<Directory> _getImageCacheDirectory() =>
    _imageCacheDirectory ??= (() async {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(
          '${support.path}${Platform.pathSeparator}lumino_image_cache_v2');
      await dir.create(recursive: true);
      return dir;
    })();

Uint8List? _compressImageForCache(Uint8List source) {
  final decoded = img.decodeImage(source);
  if (decoded == null) return null;
  final resized = decoded.width > 2400 || decoded.height > 2400
      ? img.copyResize(
          decoded,
          width: decoded.width >= decoded.height ? 2400 : null,
          height: decoded.height > decoded.width ? 2400 : null,
          interpolation: img.Interpolation.linear,
        )
      : decoded;
  return Uint8List.fromList(img.encodeJpg(resized, quality: 92));
}

Future<Uint8List?> _compressImageInBackground(Uint8List source) async {
  final previous = _imageDecodeQueue;
  final turn = Completer<void>();
  _imageDecodeQueue = turn.future;
  final queueWait = Stopwatch()..start();
  await previous;
  queueWait.stop();
  final compression = Stopwatch()..start();
  try {
    return await compute(_compressImageForCache, source);
  } finally {
    compression.stop();
    try {
      PerformanceMonitor.instance.recordOperation(
        'image-decode-compress',
        compression.elapsed,
        details: 'inputKB=${(source.length / 1024).round()} '
            'queueWaitMs=${queueWait.elapsedMilliseconds}',
      );
      PerformanceMonitor.instance.recordOperation(
        'image-decode-queue',
        queueWait.elapsed,
      );
    } finally {
      turn.complete();
    }
  }
}

Future<Uint8List?> _loadCachedImage(String url) {
  return _imageDownloads.putIfAbsent(url, () async {
    try {
      final dir = await _getImageCacheDirectory();
      final file = File(
          '${dir.path}${Platform.pathSeparator}${_imageCacheKey(url)}.jpg');
      if (await file.exists()) {
        final cached = await file.readAsBytes();
        if (cached.isNotEmpty) {
          await file.setLastModified(DateTime.now());
          return cached;
        }
        await file.delete();
      }

      final response = await http.get(Uri.parse(url), headers: const {
        'Accept': 'image/*',
        'User-Agent': 'Lumino/0.3',
      }).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200 ||
          response.bodyBytes.isEmpty ||
          response.bodyBytes.length > _imageCacheMaxDownloadBytes) {
        AppLog.instance.log(
          LogLevel.warn,
          'image',
          'image cache download failed: ${AppLog.shortUrl(url)} '
              '(HTTP ${response.statusCode}, ${response.bodyBytes.length} bytes)',
        );
        return null;
      }

      final compressed = await _compressImageInBackground(response.bodyBytes);
      if (compressed == null || compressed.isEmpty) {
        AppLog.instance.log(LogLevel.warn, 'image',
            'unsupported image: ${AppLog.shortUrl(url)}');
        return null;
      }
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(compressed, flush: true);
      await temp.rename(file.path);
      _imageCacheBytesSincePrune += compressed.length;
      await _pruneImageCache(dir);
      return compressed;
    } catch (error) {
      AppLog.instance.log(
        LogLevel.warn,
        'image',
        'image cache failed: ${AppLog.shortUrl(url)}',
        error: error,
      );
      return null;
    } finally {
      _imageDownloads.remove(url);
    }
  });
}

Future<void> _pruneImageCache(Directory dir) async {
  final inProgress = _imageCachePruning;
  if (inProgress != null) {
    await inProgress;
    return;
  }
  if (_imageCacheBytesSincePrune < _imageCachePruneByteInterval &&
      DateTime.now().difference(_lastImageCachePrune) <
          const Duration(minutes: 1)) {
    return;
  }

  final bytesAtStart = _imageCacheBytesSincePrune;
  final pruning = _pruneImageCacheContents(dir);
  _imageCachePruning = pruning;
  try {
    await pruning;
  } finally {
    _lastImageCachePrune = DateTime.now();
    if (_imageCacheBytesSincePrune <= bytesAtStart) {
      _imageCacheBytesSincePrune = 0;
    } else {
      _imageCacheBytesSincePrune -= bytesAtStart;
    }
    _imageCachePruning = null;
  }
}

Future<void> _pruneImageCacheContents(Directory dir) async {
  final stopwatch = Stopwatch()..start();
  try {
    final path = dir.path;
    await Isolate.run(() => _pruneImageCacheContentsImpl(path));
  } catch (error, stack) {
    AppLog.instance.log(
      LogLevel.warn,
      'image',
      'image cache pruning failed',
      error: error,
      stack: stack,
    );
  } finally {
    stopwatch.stop();
    PerformanceMonitor.instance.recordOperation(
      'image-cache-prune-io',
      stopwatch.elapsed,
    );
  }
}

Future<void> _pruneImageCacheContentsImpl(String path) async {
  final dir = Directory(path);
  final files = <File>[];
  await for (final entry in dir.list(followLinks: false)) {
    if (entry is File && entry.path.endsWith('.jpg')) files.add(entry);
  }
  final stats = <({File file, int length, DateTime modified})>[];
  var totalBytes = 0;
  for (final file in files) {
    final stat = await file.stat();
    totalBytes += stat.size;
    stats.add((file: file, length: stat.size, modified: stat.modified));
  }
  if (totalBytes <= _imageCacheMaxBytes) return;
  stats.sort((a, b) => a.modified.compareTo(b.modified));
  for (final entry in stats) {
    if (totalBytes <= _imageCacheMaxBytes) break;
    await entry.file.delete();
    totalBytes -= entry.length;
  }
}

/// [cacheWidth] decodes the picture at a smaller size: a 1000px cover shown in a
/// 40px row costs a lot of memory and CPU when decoded in full.
Widget imageWidget(String url,
    {BoxFit fit = BoxFit.cover,
    Alignment alignment = Alignment.center,
    int? cacheWidth}) {
  if (url.startsWith('data:image/')) {
    final bytes = _decodeDataUrl(url);
    if (bytes != null) {
      return Image.memory(bytes,
          fit: fit,
          alignment: alignment,
          gaplessPlayback: true,
          cacheWidth: cacheWidth);
    }
  }
  if (url.isEmpty) return const SizedBox.expand();
  if (kIsWeb) {
    return _networkImage(url,
        fit: fit, alignment: alignment, cacheWidth: cacheWidth);
  }
  return _DiskCachedImage(
      url: url, fit: fit, alignment: alignment, cacheWidth: cacheWidth);
}

Widget _networkImage(String url,
        {required BoxFit fit, required Alignment alignment, int? cacheWidth}) =>
    Image.network(
      url,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      cacheWidth: cacheWidth,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          child: child,
        );
      },
      errorBuilder: (context, error, stack) {
        AppLog.instance.log(
            LogLevel.warn, 'image', 'cover failed: ${AppLog.shortUrl(url)}',
            error: error);
        return const SizedBox.expand();
      },
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : const ColoredBox(color: Color(0x11FFFFFF)),
    );

class _DiskCachedImage extends StatefulWidget {
  const _DiskCachedImage({
    required this.url,
    required this.fit,
    required this.alignment,
    this.cacheWidth,
  });

  final String url;
  final BoxFit fit;
  final Alignment alignment;
  final int? cacheWidth;

  @override
  State<_DiskCachedImage> createState() => _DiskCachedImageState();
}

class _DiskCachedImageState extends State<_DiskCachedImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _DiskCachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.url;
    final bytes = await _loadCachedImage(url);
    if (!mounted || widget.url != url) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return const ColoredBox(color: Color(0x11FFFFFF));
    return Image.memory(
      bytes,
      fit: widget.fit,
      alignment: widget.alignment,
      gaplessPlayback: true,
      cacheWidth: widget.cacheWidth,
      errorBuilder: (context, error, stack) {
        AppLog.instance.log(LogLevel.warn, 'image',
            'cached image decode failed: ${AppLog.shortUrl(widget.url)}',
            error: error);
        return const SizedBox.expand();
      },
    );
  }
}

List<Color> coverGradient(String seed) {
  final hue = (hashString(seed) % 360).toDouble();
  return [
    HSLColor.fromAHSL(1, hue, 0.55, 0.38).toColor(),
    HSLColor.fromAHSL(1, (hue + 55) % 360, 0.60, 0.18).toColor(),
  ];
}

class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    this.track,
    this.url = '',
    this.onTap,
    this.radius = 6,
    this.square = false,
    this.size,
    this.letter,
    this.seed,
    this.alignment = Alignment.center,
    this.child,
    this.openArtwork = true,
    this.cacheWidth,
  });

  final Track? track;
  final String url;
  final VoidCallback? onTap;
  final double radius;
  final bool square;
  final double? size;
  final String? letter;
  final String? seed;
  final Alignment alignment;
  final Widget? child;
  final bool openArtwork;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    final source = url.isNotEmpty ? url : (track?.cover ?? '');
    final label = letter ??
        ((track == null || track!.primary.isEmpty)
            ? '?'
            : track!.primary.characters.first.toUpperCase());
    final gradientSeed =
        seed ?? (track == null ? 'x' : '${track!.primary}${track!.album}');
    Widget content;
    if (source.isNotEmpty) {
      final displaySize = size ?? (square ? 300 : 64);
      final decodeWidth = displaySize <= 64
          ? 200
          : displaySize <= 100
              ? 400
              : math.max(1200, (displaySize * 3).ceil());
      content = OriginalColors(
          child: imageWidget(source,
              alignment: alignment, cacheWidth: cacheWidth ?? decodeWidth));
    } else {
      content = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: coverGradient(gradientSeed),
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: const Color(0x8FFFFFFF),
              fontWeight: FontWeight.w800,
              fontSize: square ? 46 : 16,
            ),
          ),
        ),
      );
    }
    Widget box = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
          fit: StackFit.expand, children: [content, if (child != null) child!]),
    );
    if (square) box = AspectRatio(aspectRatio: 1, child: box);
    if (size != null) box = SizedBox(width: size, height: size, child: box);
    final showImage = onTap ??
        (openArtwork &&
                ThemeScope.of(context).openArtwork &&
                track != null &&
                track!.cover.isNotEmpty
            ? () => showArtwork(
                  context,
                  track!.cover,
                  track!.title,
                )
            : null);
    if (showImage != null) {
      box = GestureDetector(
        onTap: showImage,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: box,
        ),
      );
    }
    return box;
  }
}

Future<void> showArtwork(BuildContext context, String url, String title) async {
  if (url.isEmpty || !ThemeScope.of(context).openArtwork) return;
  await showDialog<void>(
    context: context,
    barrierColor: const Color(0xE6000000),
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(32),
      child: Stack(
        alignment: Alignment.topRight,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760, maxHeight: 760),
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Semantics(
                      label: title,
                      child: imageWidget(url, cacheWidth: 1200),
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close artwork',
            onPressed: () => Navigator.of(context).pop(),
            icon: const LIcon('close', size: 18, color: Colors.white),
          ),
        ],
      ),
    ),
  );
}

class AvatarImage extends StatelessWidget {
  const AvatarImage({
    super.key,
    required this.name,
    this.url = '',
    this.size = 40,
    this.fontSize,
    this.border,
    this.child,
    this.fit = BoxFit.cover,
  });

  final String name;
  final String url;
  final double size;
  final double? fontSize;
  final BoxBorder? border;
  final Widget? child;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final hue = (hashString(name) % 360).toDouble();
    final fallback = HSLColor.fromAHSL(1, hue, 0.45, 0.32).toColor();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, border: border),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: fallback),
          Center(
            child: Text(
              name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: fontSize ?? size * 0.38,
              ),
            ),
          ),
          if (url.isNotEmpty)
            OriginalColors(
              child: imageWidget(url, fit: fit, cacheWidth: 320),
            ),
          if (child != null) child!,
        ],
      ),
    );
  }
}

class AvatarFromUrl extends StatefulWidget {
  const AvatarFromUrl({
    super.key,
    required this.name,
    required this.url,
    this.size = 40,
    this.fontSize,
    this.border,
    this.child,
  });

  final String name;
  final Future<String> Function() url;
  final double size;
  final double? fontSize;
  final BoxBorder? border;
  final Widget? child;

  @override
  State<AvatarFromUrl> createState() => _AvatarFromUrlState();
}

class _AvatarFromUrlState extends State<AvatarFromUrl> {
  String _url = '';
  String _loadedFor = '';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(covariant AvatarFromUrl oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Without a check here, a tile recycled at the same spot in a Wrap/Row
    // (e.g. the onboarding grid reordering, or Daily Mix cards) keeps showing
    // the previous artist's picture until something else happens to rebuild it.
    if (oldWidget.name != widget.name) _fetch();
  }

  void _fetch() {
    final name = widget.name;
    _loadedFor = name;
    _url = '';
    widget.url().then((value) {
      if (mounted && value.isNotEmpty && _loadedFor == name) {
        setState(() => _url = value);
      }
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) => AvatarImage(
        name: widget.name,
        url: _url,
        size: widget.size,
        fontSize: widget.fontSize,
        border: widget.border,
        child: widget.child,
      );
}

class CoverFromUrl extends StatefulWidget {
  const CoverFromUrl({
    super.key,
    required this.url,
    required this.name,
    this.size = 40,
    this.radius = 6,
    this.child,
  });

  final Future<String> Function() url;
  final String name;
  final double size;
  final double radius;
  final Widget? child;

  @override
  State<CoverFromUrl> createState() => _CoverFromUrlState();
}

class _CoverFromUrlState extends State<CoverFromUrl> {
  String _url = '';
  String _loadedFor = '';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(covariant CoverFromUrl oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same fix as _AvatarFromUrlState: a recycled widget must not keep the
    // previous item's cover (this was the "every Daily Mix shows the same
    // cover" bug).
    if (oldWidget.name != widget.name) _fetch();
  }

  void _fetch() {
    final name = widget.name;
    _loadedFor = name;
    _url = '';
    widget.url().then((value) {
      if (mounted && value.isNotEmpty && _loadedFor == name) {
        setState(() => _url = value);
      }
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) => CoverArt(
        url: _url,
        letter: widget.name.isEmpty
            ? '?'
            : widget.name.characters.first.toUpperCase(),
        seed: widget.name,
        radius: widget.radius,
        size: widget.size,
        child: widget.child,
      );
}

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

class ArtistsText extends StatefulWidget {
  const ArtistsText({
    super.key,
    required this.artists,
    required this.onArtist,
    this.style,
    this.maxLines = 1,
    this.textAlign,
  });

  final List<String> artists;
  final ValueChanged<String> onArtist;
  final TextStyle? style;
  final int maxLines;
  final TextAlign? textAlign;

  @override
  State<ArtistsText> createState() => _ArtistsTextState();
}

class _ArtistsTextState extends State<ArtistsText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    final style = widget.style ??
        TextStyle(
          fontSize: 12,
          color: ThemeScope.of(context).mutedForeground,
          height: 1.25,
        );
    final spans = <InlineSpan>[];
    for (var i = 0; i < widget.artists.length; i++) {
      if (i > 0) spans.add(TextSpan(text: ', ', style: style));
      final name = widget.artists[i];
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onArtist(name);
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: displayName(name),
        style: style,
        recognizer: recognizer,
        mouseCursor: SystemMouseCursors.click,
      ));
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: widget.maxLines,
      textAlign: widget.textAlign,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class ExplicitBadge extends StatelessWidget {
  const ExplicitBadge({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0x57FFFFFF),
        borderRadius: BorderRadius.circular(3),
      ),
      child: const Text(
        'E',
        style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111111),
            height: 1),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({super.key, required this.title, this.icon});
  final String title;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 14),
      child: Row(
        children: [
          if (icon != null) ...[icon!, const SizedBox(width: 10)],
          Text(title,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2)),
        ],
      ),
    );
  }
}

class PagePadding extends StatelessWidget {
  const PagePadding(
      {super.key,
      required this.child,
      this.top = 18,
      this.horizontal = 32,
      this.bottom = 28});
  final Widget child;
  final double top;
  final double horizontal;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? math.min(horizontal, 18) : horizontal,
          top,
          compact ? math.min(horizontal, 18) : horizontal,
          bottom),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

class PlayButton extends StatelessWidget {
  const PlayButton(
      {super.key,
      required this.label,
      this.onTap,
      this.icon = true,
      this.height = 38});
  final String label;
  final VoidCallback? onTap;
  final bool icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            color: hovered ? const Color(0xFFE8E8EE) : Colors.white,
            borderRadius: BorderRadius.circular(height >= 42 ? 999 : 10),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon) ...[
              const LIcon('play', size: 14, color: Color(0xFF111111)),
              const SizedBox(width: 8)
            ],
            Text(label,
                style: const TextStyle(
                    color: Color(0xFF111111),
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5)),
          ]),
        ),
      ),
    );
  }
}

class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.label,
    this.onTap,
    this.danger = false,
    this.height = 38,
    this.padding = 18,
    this.fontSize = 13.5,
    this.accent = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final double height;
  final double padding;
  final double fontSize;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final light = ThemeScope.of(context).light;
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: height,
          padding: EdgeInsets.symmetric(horizontal: padding),
          decoration: BoxDecoration(
            color: accent
                ? Colors.white
                : light
                    ? (hovered
                        ? const Color(0x16000000)
                        : const Color(0x0D000000))
                    : (hovered
                        ? const Color(0x2EFFFFFF)
                        : const Color(0x1AFFFFFF)),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: accent
                  ? const Color(0xFF17181C)
                  : (danger
                      ? const Color(0xFFFF7B7B)
                      : (light ? const Color(0xFF17181C) : Colors.white)),
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class ChipButton extends StatelessWidget {
  const ChipButton({
    super.key,
    required this.label,
    this.onTap,
    this.icon,
    this.ghost = false,
    this.height = 34,
    this.fontSize = 13,
  });
  final String label;
  final VoidCallback? onTap;
  final String? icon;
  final bool ghost;
  final double height;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final light = ThemeScope.of(context).light;
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: ghost
                ? Colors.transparent
                : light
                    ? (hovered
                        ? const Color(0x16000000)
                        : const Color(0x0D000000))
                    : (hovered
                        ? const Color(0x29FFFFFF)
                        : const Color(0x17FFFFFF)),
            borderRadius: BorderRadius.circular(999),
            border: ghost
                ? Border.all(
                    color: light
                        ? Color(hovered ? 0x5217181C : 0x2917181C)
                        : Color(hovered ? 0x52FFFFFF : 0x29FFFFFF))
                : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              LIcon(
                icon!,
                size: 14,
                color: light
                    ? (ghost && !hovered
                        ? const Color(0xFF686B73)
                        : const Color(0xFF17181C))
                    : (ghost && !hovered
                        ? const Color(0x9FFFFFFF)
                        : Colors.white),
              ),
              const SizedBox(width: 6)
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: light
                    ? (ghost && !hovered
                        ? const Color(0xFF686B73)
                        : const Color(0xFF17181C))
                    : (ghost && !hovered
                        ? const Color(0x9FFFFFFF)
                        : Colors.white),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class IconAction extends StatefulWidget {
  const IconAction({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 34,
    this.iconSize = 18,
    this.color = const Color(0x8CFFFFFF),
    this.hoverColor = Colors.white,
    this.borderRadius = 9,
    this.active = false,
    this.dot = false,
    this.tooltip,
    this.filled,
    this.animateOnTap = false,
  });

  final String icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color color;
  final Color hoverColor;
  final double borderRadius;
  final bool active;
  final bool dot;
  final String? tooltip;
  final bool? filled;
  final bool animateOnTap;

  @override
  State<IconAction> createState() => _IconActionState();
}

/// Pops the icon (like the old Like-button bounce) whenever it turns "on" --
/// i.e. `filled`/`active` flips from false to true (liking a track, etc).
class _IconActionState extends State<IconAction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.35), weight: 35),
    TweenSequenceItem(tween: Tween(begin: 1.35, end: 1.0), weight: 65),
  ]).animate(CurvedAnimation(parent: _pop, curve: Curves.easeOut));

  bool get _on => widget.filled ?? widget.active;

  @override
  void didUpdateWidget(covariant IconAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasOn = oldWidget.filled ?? oldWidget.active;
    if (_on && !wasOn) _pop.forward(from: 0);
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final light = ThemeScope.of(context).light;
    return HoverBuilder(
      builder: (context, hovered) {
        return TapArea(
          tooltip: widget.tooltip,
          onTap: () {
            if (widget.animateOnTap && !_on) _pop.forward(from: 0);
            widget.onTap?.call();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: hovered
                  ? (light ? const Color(0x12000000) : const Color(0x14FFFFFF))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(widget.borderRadius),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                ScaleTransition(
                  scale: _scale,
                  child: LIcon(
                    widget.icon,
                    size: widget.iconSize,
                    color: light
                        ? (widget.active || hovered
                            ? const Color(0xFF17181C)
                            : const Color(0xFF686B73))
                        : (widget.active || hovered
                            ? widget.hoverColor
                            : widget.color),
                    filled: widget.filled,
                  ),
                ),
                if (widget.dot)
                  Positioned(
                    bottom: 4,
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: light ? const Color(0xFF3949AB) : Colors.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class PlayMainButton extends StatelessWidget {
  const PlayMainButton(
      {super.key,
      required this.playing,
      this.onTap,
      this.size = 40,
      this.iconSize = 18,
      this.inverted = false});
  final bool playing;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (context, hovered) => TapArea(
        onTap: onTap,
        child: AnimatedScale(
          scale: hovered ? 1.06 : 1,
          duration: const Duration(milliseconds: 140),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: inverted ? Colors.transparent : Colors.white,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: LIcon(
              playing ? 'pause' : 'play',
              size: iconSize,
              color: inverted ? Colors.white : const Color(0xFF111111),
            ),
          ),
        ),
      ),
    );
  }
}

class SwitchPill extends StatelessWidget {
  const SwitchPill({super.key, required this.value, this.onTap});
  final bool value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final light = ThemeScope.of(context).light;
    return TapArea(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 46,
        height: 28,
        decoration: BoxDecoration(
          color: light
              ? (value ? const Color(0xFF3949AB) : const Color(0x2917181C))
              : (value ? Colors.white : const Color(0x29FFFFFF)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: light
                  ? Colors.white
                  : (value ? const Color(0xFF111111) : Colors.white),
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 6,
                    offset: Offset(0, 2))
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class KebabButton extends StatelessWidget {
  const KebabButton(
      {super.key,
      this.onTap,
      this.onTapAt,
      this.opacity = 0.9,
      this.saved = false});
  final VoidCallback? onTap;
  final void Function(Offset position)? onTapAt;
  final double opacity;
  final bool saved;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Builder(builder: (inner) {
        return IconAction(
          icon: 'kebab',
          size: 28,
          iconSize: 18,
          color: Colors.white,
          borderRadius: 8,
          tooltip: 'More',
          active: saved,
          onTap: () {
            if (onTapAt != null) {
              final box = inner.findRenderObject() as RenderBox?;
              final origin = box == null
                  ? Offset.zero
                  : box.localToGlobal(Offset(box.size.width, box.size.height));
              onTapAt!(origin);
            } else {
              onTap?.call();
            }
          },
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Sliders
// ---------------------------------------------------------------------------

class LSlider extends StatefulWidget {
  const LSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.height = 20,
    this.trackHeight = 4,
    this.thumbOnHover = true,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;
  final double height;
  final double trackHeight;
  final bool thumbOnHover;

  @override
  State<LSlider> createState() => _LSliderState();
}

class _LSliderState extends State<LSlider> {
  bool _hovered = false;
  bool _dragging = false;

  void _emit(Offset local, double width) {
    final fraction = clampDouble(local.dx / math.max(1, width), 0, 1);
    widget.onChanged(fraction);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              widget.onChangeStart?.call();
              _emit(details.localPosition, width);
              widget.onChangeEnd?.call();
            },
            onHorizontalDragStart: (details) {
              setState(() => _dragging = true);
              widget.onChangeStart?.call();
              _emit(details.localPosition, width);
            },
            onHorizontalDragUpdate: (details) =>
                _emit(details.localPosition, width),
            onHorizontalDragEnd: (_) {
              setState(() => _dragging = false);
              widget.onChangeEnd?.call();
            },
            onHorizontalDragCancel: () {
              setState(() => _dragging = false);
              widget.onChangeEnd?.call();
            },
            child: SizedBox(
              height: widget.height,
              width: width,
              child: CustomPaint(
                painter: _SliderPainter(
                  value: clampDouble(widget.value, 0, 1),
                  trackHeight: widget.trackHeight,
                  thumbVisible: (_hovered || _dragging) && widget.thumbOnHover,
                  light: ThemeScope.of(context).light,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter(
      {required this.value,
      required this.trackHeight,
      required this.thumbVisible,
      required this.light});
  final double value;
  final double trackHeight;
  final bool thumbVisible;
  final bool light;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final radius = Radius.circular(trackHeight / 2);
    final background = Paint()
      ..color = light ? const Color(0x3317181C) : const Color(0x33FFFFFF);
    final fill = Paint()
      ..color = light ? const Color(0xFF3949AB) : Colors.white;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(0, y - trackHeight / 2, size.width, trackHeight),
          radius),
      background,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(
              0, y - trackHeight / 2, size.width * value, trackHeight),
          radius),
      fill,
    );
    if (thumbVisible) {
      canvas.drawCircle(Offset(size.width * value, y), 5.5,
          Paint()..color = light ? const Color(0xFF3949AB) : Colors.white);
    }
  }

  @override
  bool shouldRepaint(_SliderPainter old) =>
      old.value != value ||
      old.thumbVisible != thumbVisible ||
      old.light != light;
}

// ---------------------------------------------------------------------------
// Track representations
// ---------------------------------------------------------------------------

class CurrentCoverOverlay extends StatelessWidget {
  const CurrentCoverOverlay(
      {super.key, required this.playing, this.size = 16, this.radius = 7});
  final bool playing;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x80000000),
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: LIcon(playing ? 'pause' : 'play', size: size, color: Colors.white),
    );
  }
}

class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.track,
    required this.onPlay,
    required this.onMenu,
    required this.onArtist,
    this.current = false,
    this.playing = false,
    this.durationText = '',
    this.subtitle,
    this.trailing,
    this.openArtwork = true,
  });

  final Track track;
  final VoidCallback onPlay;
  final void Function(Offset position)? onMenu;
  final ValueChanged<String> onArtist;
  final bool current;
  final bool playing;
  final String durationText;
  final Widget? subtitle;
  final Widget? trailing;
  final bool openArtwork;

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      cursor: SystemMouseCursors.basic,
      builder: (context, hovered) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPlay,
          onSecondaryTapDown: onMenu == null
              ? null
              : (details) => onMenu!(details.globalPosition),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: hovered
                  ? (ThemeScope.of(context).light
                      ? const Color(0x0D000000)
                      : const Color(0x0FFFFFFF))
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 0),
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: CoverArt(
                    track: track,
                    radius: 7,
                    openArtwork: openArtwork,
                    child:
                        current ? CurrentCoverOverlay(playing: playing) : null,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 1),
                      subtitle ??
                          Row(children: [
                            if (track.explicit) ...[
                              const ExplicitBadge(),
                              const SizedBox(width: 6)
                            ],
                            Expanded(
                              child: ArtistsText(
                                artists: track.artists,
                                onArtist: onArtist,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  color: ThemeScope.of(context).mutedForeground,
                                  height: 1.2,
                                ),
                              ),
                            ),
                          ]),
                    ],
                  ),
                ),
                if (durationText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Text(
                      durationText,
                      style: TextStyle(
                        fontSize: 13,
                        color: ThemeScope.of(context).mutedForeground,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                if (trailing != null) trailing!,
                if (onMenu != null)
                  KebabButton(onTapAt: onMenu)
                else
                  const SizedBox(width: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onPlay,
    required this.onMenu,
    required this.onArtist,
    this.current = false,
    this.playing = false,
  });

  final Track track;
  final VoidCallback onPlay;
  final void Function(Offset position)? onMenu;
  final ValueChanged<String> onArtist;
  final bool current;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final light = ThemeScope.of(context).light;
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPlay,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 50,
          padding: const EdgeInsets.only(left: 6, right: 6),
          decoration: BoxDecoration(
            color: light
                ? (hovered ? const Color(0x16000000) : const Color(0x0D000000))
                : (hovered ? const Color(0x1AFFFFFF) : const Color(0x0EFFFFFF)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            SizedBox(
              width: 38,
              height: 38,
              child: CoverArt(
                  track: track,
                  radius: 6,
                  child: current
                      ? CurrentCoverOverlay(playing: playing, size: 14)
                      : null),
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
                          fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 1),
                  Row(children: [
                    if (track.explicit) ...[
                      const ExplicitBadge(),
                      const SizedBox(width: 6)
                    ],
                    Expanded(
                      child: ArtistsText(
                        artists: track.artists,
                        onArtist: onArtist,
                        style: TextStyle(
                          fontSize: 12,
                          color: ThemeScope.of(context).mutedForeground,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
            if (onMenu != null)
              KebabButton(onTapAt: onMenu, opacity: hovered ? 1 : 0.65),
          ]),
        ),
      ),
    );
  }
}

class PlayFab extends StatelessWidget {
  const PlayFab(
      {super.key, required this.playing, this.onTap, this.visible = true});
  final bool playing;
  final VoidCallback? onTap;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: visible ? 1 : 0,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 180),
        offset: visible ? Offset.zero : const Offset(0, 0.15),
        child: SizedBox(
          width: 38,
          height: 38,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xB3000000),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0x33FFFFFF)),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 14,
                    offset: Offset(0, 6))
              ],
            ),
            child: TapArea(
                onTap: onTap,
                child: Center(
                    child: LIcon(playing ? 'pause' : 'play',
                        size: 18, color: Colors.white))),
          ),
        ),
      ),
    );
  }
}

class TrackCard extends StatelessWidget {
  const TrackCard({
    super.key,
    required this.track,
    required this.width,
    required this.onPlay,
    required this.onArtist,
    this.current = false,
    this.playing = false,
    this.title,
    this.subtitle,
  });

  final Track track;
  final double width;
  final VoidCallback onPlay;
  final ValueChanged<String> onArtist;
  final bool current;
  final bool playing;
  final String? title;
  final Widget? subtitle;

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (context, hovered) => SizedBox(
        width: width,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPlay,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                transform: Matrix4.translationValues(0, hovered ? -2 : 0, 0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: hovered
                      ? const [
                          BoxShadow(
                              color: Color(0x73000000),
                              blurRadius: 30,
                              offset: Offset(0, 12))
                        ]
                      : const [],
                ),
                child: Stack(children: [
                  CoverArt(
                      track: track,
                      square: true,
                      radius: 12,
                      openArtwork: false,
                      child: current
                          ? CurrentCoverOverlay(
                              playing: playing, size: 22, radius: 12)
                          : null),
                  if (!current)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: PlayFab(
                          playing: false, visible: hovered, onTap: onPlay),
                    ),
                  if (current)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: PlayFab(
                          playing: playing, visible: true, onTap: onPlay),
                    ),
                ]),
              ),
              const SizedBox(height: 10),
              Text(title ?? track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              subtitle ??
                  ArtistsText(
                    artists: track.artists,
                    onArtist: onArtist,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: ThemeScope.of(context).mutedForeground,
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class ReleaseCard extends StatelessWidget {
  const ReleaseCard({
    super.key,
    required this.release,
    required this.width,
    required this.onTap,
    this.subtitle,
  });

  final Release release;
  final double width;
  final VoidCallback onTap;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (context, hovered) => SizedBox(
        width: width,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                transform: Matrix4.translationValues(0, hovered ? -2 : 0, 0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: hovered
                      ? const [
                          BoxShadow(
                              color: Color(0x73000000),
                              blurRadius: 30,
                              offset: Offset(0, 12))
                        ]
                      : const [],
                ),
                child: CoverArt(
                  url: release.cover,
                  seed: release.name,
                  letter: release.name.isEmpty
                      ? '?'
                      : release.name.characters.first.toUpperCase(),
                  square: true,
                  radius: 12,
                ),
              ),
              const SizedBox(height: 10),
              Text(release.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                subtitle ?? '${release.kindLabel} · ${release.artistName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: ThemeScope.of(context).mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MixCover extends StatelessWidget {
  const MixCover({
    super.key,
    required this.index,
    required this.lead,
    required this.seed,
    required this.artistAvatar,
    this.onPlay,
    this.playing = false,
    this.showPlay = false,
    this.colorArt = false,
    this.collection = false,
    this.onTap,
  });

  final int index;
  final Track? lead;
  final String seed;
  final Future<String> Function(String name) artistAvatar;
  final VoidCallback? onPlay;
  final bool playing;
  final bool showPlay;
  final bool colorArt;
  final bool collection;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = kMixColors[index % kMixColors.length];
    Widget cover = AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            return Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFF111111)),
                if (lead != null && lead!.cover.isNotEmpty)
                  Stack(fit: StackFit.expand, children: [
                    ColorFiltered(
                      colorFilter: const ColorFilter.matrix([
                        0.2126,
                        0.7152,
                        0.0722,
                        0,
                        0,
                        0.2126,
                        0.7152,
                        0.0722,
                        0,
                        0,
                        0.2126,
                        0.7152,
                        0.0722,
                        0,
                        0,
                        0,
                        0,
                        0,
                        1,
                        0,
                      ]),
                      child: imageWidget(lead!.cover,
                          alignment: Alignment.topCenter),
                    ),
                    AnimatedOpacity(
                      opacity: colorArt ? 1 : 0,
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      child: imageWidget(
                        lead!.cover,
                        alignment: Alignment.topCenter,
                      ),
                    ),
                  ])
                else
                  _MixAvatar(name: seed, avatar: artistAvatar),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: const [
                        Color(0x47000000),
                        Color(0x00000000),
                        Color(0x00000000),
                        Color(0x61000000),
                      ],
                      stops: const [0, 0.28, 0.6, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: w * 0.06,
                  top: w * 0.05,
                  width: w * 0.13,
                  child: Image.asset('assets/logo.png', fit: BoxFit.contain),
                ),
                Positioned(
                  left: w * 0.045,
                  bottom: w * 0.045,
                  child: Container(
                    height: w * 0.15,
                    padding: EdgeInsets.symmetric(horizontal: w * 0.036),
                    color: color,
                    alignment: Alignment.center,
                    child: Text(
                      'Daily Mix',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w800,
                        fontSize: w * 0.084,
                        letterSpacing: -w * 0.002,
                        height: 1,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: w * 0.045,
                  bottom: w * 0.045,
                  child: Container(
                    height: w * 0.15,
                    constraints: BoxConstraints(minWidth: w * 0.20),
                    padding: EdgeInsets.symmetric(horizontal: w * 0.024),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      border: Border.all(color: color, width: w * 0.009),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      (index + 1).toString().padLeft(2, '0'),
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w800,
                        fontSize: w * 0.11,
                        letterSpacing: -w * 0.003,
                        height: 1,
                      ),
                    ),
                  ),
                ),
                if (showPlay)
                  Positioned(
                    right: 8,
                    top: 8,
                    child:
                        PlayFab(playing: playing, visible: true, onTap: onPlay),
                  ),
              ],
            );
          },
        ),
      ),
    );
    if (onTap != null) {
      cover = GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: cover,
        ),
      );
    }
    return cover;
  }
}

class _MixAvatar extends StatefulWidget {
  const _MixAvatar({required this.name, required this.avatar});
  final String name;
  final Future<String> Function(String) avatar;

  @override
  State<_MixAvatar> createState() => _MixAvatarState();
}

class _MixAvatarState extends State<_MixAvatar> {
  String _url = '';

  @override
  void initState() {
    super.initState();
    widget.avatar(widget.name).then((value) {
      if (mounted && value.isNotEmpty) setState(() => _url = value);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final hue = (hashString(widget.name) % 360).toDouble();
    final background = HSLColor.fromAHSL(1, hue, 0.45, 0.32).toColor();
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: background),
        if (_url.isNotEmpty) OriginalColors(child: imageWidget(_url)),
        if (_url.isEmpty)
          Center(
            child: Text(
              widget.name.isEmpty
                  ? '?'
                  : widget.name.characters.first.toUpperCase(),
              style: const TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
            ),
          ),
      ],
    );
  }
}

/// One-shot entrance (fade + 10px rise), staggered by [index]. The widget tree
/// shape never changes after the animation ends, so child State is preserved.
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.child, this.index = 0});
  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    final delay = math.min(index, 8) * 45;
    final total = 320 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
            offset: Offset(0, (1 - value) * 10), child: child),
      ),
    );
  }
}

class CardsRow extends StatefulWidget {
  const CardsRow({super.key, required this.children, this.cardWidth});
  final List<Widget> children;
  final double? cardWidth;

  @override
  State<CardsRow> createState() => _CardsRowState();
}

class _CardsRowState extends State<CardsRow> {
  final ScrollController _controller = ScrollController();
  bool _dragging = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = widget.cardWidth ??
          ((constraints.maxWidth - 64) / 5).clamp(120.0, 260.0).toDouble();
      return MouseRegion(
        cursor:
            _dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            scrollbars: false,
            dragDevices: {
              PointerDeviceKind.mouse,
              PointerDeviceKind.touch,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.stylus,
            },
          ),
          child: GestureDetector(
            onHorizontalDragStart: (_) => setState(() => _dragging = true),
            onHorizontalDragEnd: (_) => setState(() => _dragging = false),
            child: SingleChildScrollView(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < widget.children.length; i++) ...[
                    if (i > 0) const SizedBox(width: 16),
                    SizedBox(
                        width: width,
                        child: Reveal(index: i, child: widget.children[i])),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Dialogs, menus, toasts
// ---------------------------------------------------------------------------

Future<T?> showGlassDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double width = 380,
  bool barrierDismissible = true,
  EdgeInsets padding = const EdgeInsets.all(20),
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'Close',
    barrierColor: const Color(0x80000000),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (context, animation, secondary) => const SizedBox.shrink(),
    transitionBuilder: (context, animation, secondary, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: Center(
            child: Material(
              type: MaterialType.transparency,
              child: GlassPanel(
                dark: true,
                radius: 16,
                padding: padding,
                child: SizedBox(
                  width: math.min(width,
                      math.max(0.0, MediaQuery.sizeOf(context).width - 32)),
                  child: builder(context),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

Future<String?> showTextPrompt(
  BuildContext context, {
  required String title,
  String value = '',
  String placeholder = 'Playlist name',
  String okLabel = 'Create',
  int maxLength = 80,
}) {
  final controller = TextEditingController(text: value);
  return showGlassDialog<String>(
    context,
    width: 420,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white)),
        const SizedBox(height: 14),
        TextField(
          controller: controller,
          autofocus: true,
          maxLength: maxLength,
          style: const TextStyle(color: Colors.white, fontSize: 15),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: placeholder,
            hintStyle: const TextStyle(color: Color(0x73FFFFFF)),
            counterText: '',
            filled: true,
            fillColor: const Color(0x0FFFFFFF),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0x24FFFFFF)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0x24FFFFFF)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0x73FFFFFF)),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: GhostButton(
              label: 'Cancel',
              onTap: () => Navigator.of(context).pop(),
              height: 42,
              padding: 0,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: HoverBuilder(
              builder: (context, hovered) => GestureDetector(
                onTap: () {
                  final text = controller.text.trim();
                  if (text.isEmpty) return;
                  Navigator.of(context).pop(text);
                },
                child: Container(
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: hovered ? const Color(0xFFE8E8EE) : Colors.white,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(okLabel,
                      style: const TextStyle(
                          color: Color(0xFF111111),
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                ),
              ),
            ),
          ),
        ]),
      ],
    ),
  );
}

class LuminoMenuItem {
  const LuminoMenuItem(this.label, this.icon, this.onTap,
      {this.filled = false, this.danger = false});
  final String label;
  final String icon;
  final VoidCallback onTap;
  final bool filled;
  final bool danger;
}

Future<void> showLuminoMenu(BuildContext context, Offset globalPosition,
    List<LuminoMenuItem> items) async {
  final media = MediaQuery.of(context);
  final size = media.size;
  final menuWidth = math.min(232.0, size.width - 16).clamp(1.0, 232.0);
  final menuHeight = math.min(items.length * 36.0 + 12, size.height - 16);
  var left = globalPosition.dx - menuWidth;
  var top = globalPosition.dy + 6;
  if (top + menuHeight > size.height - 8) {
    top = math.max(8, globalPosition.dy - menuHeight - 6);
  }
  left = left.clamp(8.0, math.max(8.0, size.width - menuWidth - 8)).toDouble();
  top = top.clamp(8.0, math.max(8.0, size.height - menuHeight - 8)).toDouble();
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close menu',
    barrierColor: const Color(0x66000000),
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, animation, secondary) => Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: menuWidth,
          child: Material(
            type: MaterialType.transparency,
            child: GlassPanel(
              dark: true,
              radius: 14,
              blur: 24,
              padding: const EdgeInsets.all(6),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: menuHeight),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final item in items)
                        _MenuItemRow(
                          item: item,
                          onTap: () {
                            Navigator.of(context).pop();
                            item.onTap();
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
    transitionBuilder: (context, animation, secondary, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  );
}

class _MenuItemRow extends StatelessWidget {
  const _MenuItemRow({required this.item, required this.onTap});
  final LuminoMenuItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return HoverBuilder(
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: hovered ? const Color(0x1FFFFFFF) : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(children: [
            LIcon(item.icon,
                size: 17,
                color: item.danger
                    ? const Color(0xFFFF7B7B)
                    : const Color(0xE6FFFFFF),
                filled: item.filled),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: item.danger
                      ? const Color(0xFFFF7B7B)
                      : const Color(0xF0FFFFFF),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class ToastView extends StatelessWidget {
  const ToastView(
      {super.key, required this.message, this.actionLabel, this.onAction});
  final String message;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 100,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: GlassPanel(
            dark: true,
            radius: 12,
            blur: 20,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(message,
                    style: const TextStyle(fontSize: 13, color: Colors.white)),
              ),
              if (actionLabel != null) ...[
                const SizedBox(width: 14),
                TapArea(
                  onTap: () {
                    onAction?.call();
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0x38FFFFFF)),
                      borderRadius: BorderRadius.circular(8),
                      color: const Color(0x1AFFFFFF),
                    ),
                    child: Text(actionLabel!,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// File helpers
// ---------------------------------------------------------------------------

/// Decoding and re-encoding a photo takes long enough to freeze the UI, so it
/// runs in a background isolate. Returns empty bytes when the image is unreadable.
Uint8List _squareJpeg(Uint8List bytes, int size, int quality) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return Uint8List(0);
  final side = math.min(decoded.width, decoded.height);
  final cropped = img.copyCrop(
    decoded,
    x: (decoded.width - side) ~/ 2,
    y: (decoded.height - side) ~/ 2,
    width: side,
    height: side,
  );
  final resized = img.copyResize(cropped,
      width: size, height: size, interpolation: img.Interpolation.average);
  return Uint8List.fromList(img.encodeJpg(resized, quality: quality));
}

Future<String> pickImageAsDataUrl({int size = 256, double quality = 88}) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
    withData: true,
  );
  final file = result?.files.firstOrNull;
  if (file == null) return '';
  final bytes = file.bytes;
  if (bytes == null) return '';
  final encoded =
      await Isolate.run(() => _squareJpeg(bytes, size, quality.toInt()));
  if (encoded.isEmpty) return '';
  return 'data:image/jpeg;base64,${base64Encode(encoded)}';
}

Future<void> copyToClipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));

class ShimmerBox extends StatefulWidget {
  const ShimmerBox({super.key, this.width, this.height, this.radius = 8});
  final double? width;
  final double? height;
  final double radius;

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(-1 - 2 * _controller.value, 0),
            end: Alignment(1 - 2 * _controller.value, 0),
            colors: const [
              Color(0x0DFFFFFF),
              Color(0x1FFFFFFF),
              Color(0x0DFFFFFF)
            ],
            stops: const [0.3, 0.5, 0.7],
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.text, this.left = false});
  final String text;
  final bool left;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: left ? 10 : 40),
      child: Text(
        text,
        textAlign: left ? TextAlign.left : TextAlign.center,
        style: TextStyle(
          color: ThemeScope.of(context).mutedForeground,
          fontSize: 14,
          height: 1.45,
        ),
      ),
    );
  }
}
