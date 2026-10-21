import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'design.dart';

/// Скругляет углы всего окна приложения.
///
/// Окно без рамки прозрачное (см. main.dart и linux/runner), поэтому всё, что
/// вне скруглённого прямоугольника, остаётся прозрачным. В развёрнутом режиме
/// и в полноэкранном углы возвращаются прямыми.
class WindowCorners extends StatelessWidget {
  const WindowCorners({super.key, required this.child});

  final Widget child;

  static const double radius = 14;

  /// true, когда окно развёрнуто или полноэкранное: тогда углы прямые.
  static final ValueNotifier<bool> square = ValueNotifier<bool>(false);

  @override
  Widget build(BuildContext context) {
    final radius = defaultTargetPlatform == TargetPlatform.android
        ? 0.0
        : WindowCorners.radius;
    return ValueListenableBuilder<bool>(
      valueListenable: square,
      builder: (context, isSquare, _) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(isSquare ? 0 : radius),
          clipBehavior: Clip.antiAlias,
          child: ColoredBox(color: kBg, child: child),
        );
      },
    );
  }
}
