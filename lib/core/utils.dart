import 'dart:math' as math;

/// Small helpers shared by the whole app. They mirror the helpers used by the
/// Electron renderer so saved data and behaviour stay compatible.

String norm(Object? value) =>
    (value ?? '').toString().toLowerCase().replaceAll(cachedRe(r'\s+'), ' ').trim();

const Map<String, String> _diacritics = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', 'ă': 'a', 'ą': 'a',
  'ç': 'c', 'ć': 'c', 'č': 'c', 'ĉ': 'c', 'ċ': 'c',
  'ď': 'd', 'đ': 'd', 'ð': 'd',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ė': 'e', 'ę': 'e', 'ě': 'e',
  'ĝ': 'g', 'ğ': 'g', 'ġ': 'g', 'ģ': 'g',
  'ĥ': 'h', 'ħ': 'h',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'į': 'i', 'ı': 'i',
  'ĵ': 'j', 'ķ': 'k', 'ĺ': 'l', 'ļ': 'l', 'ľ': 'l', 'ł': 'l',
  'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o', 'ő': 'o', 'ǒ': 'o',
  'ŕ': 'r', 'ř': 'r', 'ś': 's', 'š': 's', 'ş': 's', 'ș': 's',
  'ť': 't', 'ţ': 't', 'ț': 't', 'þ': 't',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ů': 'u', 'ű': 'u', 'ų': 'u',
  'ŵ': 'w', 'ý': 'y', 'ÿ': 'y', 'ŷ': 'y', 'ź': 'z', 'ž': 'z', 'ż': 'z',
  'ё': 'е', 'Ё': 'Е',
};

String _foldDiacritics(String input) {
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_diacritics[char] ?? char);
  }
  return buffer.toString();
}

/// Spelling-tolerant artist key: case, spaces, punctuation, accents and
/// doubled letters are ignored ("Kai Angel" == "KAI ANGEL" == "kaiangel").
String looseKey(Object? value) {
  var text = _foldDiacritics((value ?? '').toString().toLowerCase());
  text = text.replaceAll(cachedRe(r'[^a-z0-9а-яё]'), '');
  return text.replaceAllMapped(cachedRe(r'(.)\1+'), (m) => m.group(1)!);
}

/// Compact key without doubled-letter collapsing, used by the importer.
String compactKey(Object? value) {
  var text = _foldDiacritics((value ?? '').toString().toLowerCase());
  return text.replaceAll(cachedRe(r'[^a-z0-9а-яё]'), '');
}

const Map<String, String> displayNames = {
  'lilmorty': 'LIL MORTY',
  'august': 'AUGUST',
  'n01r': 'n01r',
};

String displayName(String name) => displayNames[looseKey(name)] ?? name;

bool sameArtist(String? a, String? b) {
  final x = looseKey(a);
  final y = looseKey(b);
  return x.isNotEmpty && x == y;
}

String canonicalTrackTitle(String artist, String title, {String album = ''}) {
  if (!sameArtist(artist, 'Kai Angel')) return title;
  final albumKey = compactKey(album);
  final titleKey = compactKey(title);
  if (albumKey == 'damage' &&
      const {'naive', 'slavetotherhythm'}.contains(titleKey)) {
    return 'slave to the rhythm';
  }
  if (albumKey == 'mm' &&
      const {'mm', 'marilynmanson'}.contains(titleKey)) {
    return 'MARILYN MANSON';
  }
  if (albumKey == 'angelmaycry' &&
      const {'kylie', 'kylieminogue'}.contains(titleKey)) {
    return 'KYLIE MINOGUE';
  }
  return title;
}

String fmtDuration(num? seconds) {
  final total = math.max(0, (seconds ?? 0).floor());
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

String fmtNum(num? value) {
  final n = (value ?? 0).toDouble();
  if (n >= 1000000) {
    final text = (n / 1000000).toStringAsFixed(2);
    return '${text.replaceFirst(cachedRe(r'\.?0+$'), '')}M';
  }
  if (n >= 1000) {
    final text = (n / 1000).toStringAsFixed(1);
    return '${text.replaceFirst(cachedRe(r'\.0$'), '')}K';
  }
  return n.toInt().toString();
}

int hashString(Object? value) {
  var hash = 0;
  for (final rune in (value ?? '').toString().runes) {
    hash = ((hash * 31) + rune) & 0x7fffffff;
  }
  return hash;
}

double clampDouble(num value, num low, num high) =>
    value < low ? low.toDouble() : (value > high ? high.toDouble() : value.toDouble());

int clampInt(num value, int low, int high) => value < low ? low : (value > high ? high : value.toInt());

String plural(int n, String one, String many) => n == 1 ? one : many;

String greetingPhrase([DateTime? now]) {
  final hour = (now ?? DateTime.now()).hour;
  if (hour >= 5 && hour < 12) return 'Good morning';
  if (hour >= 12 && hour < 18) return 'Good afternoon';
  return 'Good evening';
}

int daySeed([DateTime? now]) {
  final d = now ?? DateTime.now();
  return d.year * 400 + d.month * 31 + d.day;
}

List<T> seededShuffle<T>(List<T> source, int seed) {
  final list = List<T>.from(source);
  var state = seed == 0 ? 1 : seed;
  double rnd() {
    state = (state * 1664525 + 1013904223) % 4294967296;
    return state / 4294967296;
  }

  for (var i = list.length - 1; i > 0; i--) {
    final j = (rnd() * (i + 1)).floor();
    final tmp = list[i];
    list[i] = list[j];
    list[j] = tmp;
  }
  return list;
}

int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty || b.isEmpty) return math.max(a.length, b.length);
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0);
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      current[j] = math.min(math.min(previous[j] + 1, current[j - 1] + 1), substitution);
    }
    previous = current;
  }
  return previous[b.length];
}

double similarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  return 1 - levenshtein(a, b) / math.max(a.length, b.length);
}

String fmtBytes(num bytes) {
  var n = bytes.toDouble();
  if (n < 1024) return '${n.toInt()} B';
  const units = ['KB', 'MB', 'GB'];
  var index = -1;
  do {
    n /= 1024;
    index++;
  } while (n >= 1024 && index < 2);
  return '${n.toStringAsFixed(n < 10 ? 1 : 0)} ${units[index]}';
}

String safeFileName(String value) =>
    value.replaceAll(cachedRe(r'[\\/:*?"<>|]'), '').trim();

String formatDb(num gain) {
  final rounded = (gain * 2).round() / 2;
  final text = rounded == rounded.roundToDouble()
      ? rounded.round().toString()
      : rounded.toStringAsFixed(1);
  return rounded > 0 ? '+$text' : text;
}

List<String> splitCredits(String value) {
  return value
      .split(cachedRe(r'\s*(?:,|;|&|×|\bfeat\.?\s|\bft\.?\s|\bfeaturing\b)\s*', caseSensitive: false))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

final Map<String, RegExp> _regexCache = {};

/// Compiles each pattern once. Helpers such as [norm] and [looseKey] run inside
/// sorts and per-track loops; compiling a RegExp on every call made the UI lag.
RegExp cachedRe(String pattern, {bool caseSensitive = true, bool unicode = false}) {
  final key = '${caseSensitive ? 1 : 0}${unicode ? 1 : 0}$pattern';
  return _regexCache.putIfAbsent(
    key,
    () => RegExp(pattern, caseSensitive: caseSensitive, unicode: unicode),
  );
}
