import 'package:flutter_test/flutter_test.dart';

import 'package:lumino/core/app_log.dart';

void main() {
  test('shortUrl drops the query string so tokens and search text never reach the log', () {
    expect(
      AppLog.shortUrl('https://fascind.theluni.ru/api/search?q=secret&limit=50'),
      'fascind.theluni.ru/api/search',
    );
  });

  test('clip shortens long values and flattens newlines', () {
    expect(AppLog.clip('a\nb', 10), 'a b');
    expect(AppLog.clip('x' * 100, 10), '${'x' * 10}…');
    expect(AppLog.clip(null), '');
  });
}
