import 'package:flutter_test/flutter_test.dart';

import 'package:lumino/core/utils.dart';

void main() {
  test('looseKey ignores case, accents and doubled letters', () {
    expect(looseKey('Kai Angel'), looseKey('KAI ANGEL'));
    expect(looseKey('Café'), looseKey('Cafe'));
  });

  test('fmtDuration formats minutes and seconds', () {
    expect(fmtDuration(65), '1:05');
    expect(fmtDuration(0), '0:00');
  });

  test('levenshtein counts single-character edits', () {
    expect(levenshtein('kitten', 'sitting'), 3);
  });

  test('clampDouble keeps values inside the range', () {
    expect(clampDouble(5, 0, 1), 1.0);
    expect(clampDouble(-2, 0, 1), 0.0);
  });
}
