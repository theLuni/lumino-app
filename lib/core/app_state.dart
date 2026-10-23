import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'audio_service.dart';
import 'auth_service.dart';
import 'catalog_service.dart';
import 'lyrics_service.dart';
import 'meta_service.dart';
import 'models.dart';
import 'node_service.dart';
import 'persistence.dart';
import 'utils.dart';

class PageRef {
  const PageRef(this.name, this.arg);
  final String name;
  final Object? arg;
}

class TasteArtist {
  const TasteArtist(this.key, this.name, this.weight);
  final String key;
  final String name;
  final double weight;
}

class DailyMix {
  const DailyMix(this.tracks, this.seed);
  final List<Track> tracks;
  final String seed;
}

class HomeReleaseItem {
  const HomeReleaseItem(this.release, this.artist, this.key);
  final Release release;
  final String artist;
  final String key;
}

class ToastMessage {
  const ToastMessage(this.id, this.message, this.actionLabel, this.onAction);
  final int id;
  final String message;
  final String? actionLabel;
  final Future<void> Function()? onAction;
}

class _HomeReleaseJob {
  const _HomeReleaseJob(this.key, this.name);
  final String key;
  final String name;
}

class AppState extends ChangeNotifier {
  AppState({
    required this.persistence,
    required this.node,
    required this.catalog,
    required this.meta,
    required this.lyricsService,
    required this.audio,
    required this.auth,
    this.registeredDisplayName,
  });

  final Persistence persistence;
  final NodeService node;
  final CatalogService catalog;
  final MetaService meta;
  final LyricsService lyricsService;
  final AudioService audio;
  final AuthService auth;

  /// The display name entered during registration on the server (if any).
  /// Used only as a fallback to pre-fill the profile nickname the first time
  /// around; after that the locally-saved/edited nickname always wins.
  final String? registeredDisplayName;

  final Map<String, Track> byId = {};
  final Set<String> liked = {};
  final List<String> queue = [];
  int qi = -1;
  bool shuffle = false;
  final Set<String> _shufflePlayed = {};
  String repeat = 'off';
  double volume = 0.7;

  String pageName = 'home';
  Object? pageArg;
  final List<PageRef> history = [];
  bool fullScreen = false;
  bool queueOpen = false;
  bool maximized = false;

  final Map<String, List<String>> lists = {};
  final Map<String, String> mixSeeds = {};
  List<Playlist> playlists = [];
  final Map<String, String> savedArtists = {};
  final Set<String> savedTrackIds = {};
  final Map<String, PlayEntry> plays = {};
  final Map<String, List<String>> similar = {};

  final Map<String, ArtistInfo> artists = {};
  final Map<String, Future<ArtistInfo>> _artistFutures = {};
  final Map<String, Future<String>> _avatarFutures = {};
  final Map<String, Future<ReleaseIndex>> _releaseIndexFutures = {};
  final Map<String, ReleaseIndex?> homeReleases = {};
  final Map<String, Future<Release?>> _releaseForTrackFutures = {};
  final Map<String, Release?> _releaseForTrack = {};
  final Map<String, Track> _releaseTrackCache = {};

  final Set<String> noCover = {};
  final Map<String, int> _coverTried = {};
  final List<Track> _coverWaiting = [];
  int _coverBusy = 0;

  List<HomeReleaseItem> homeReleaseList = [];
  List<Map<String, String>> recArtists = [];
  List<Track> recTracks = [];
  String genreRecLabel = '';
  List<Track> genreRecTracks = [];
  String _recSeedKey = '';
  bool recsDone = false;
  bool _recsRunning = false;
  Timer? _recsTimer;
  Set<String>? knownPlayable;

  AppSettings settings = AppSettings();
  Profile profile = Profile();
  SetupState setup = SetupState();

  NodeState nodeState = NodeState();
  ToastMessage? toastMessage;
  Timer? _toastTimer;
  Timer? _dayRefreshTimer;
  int _toastSeq = 0;
  int _dailySeed = 0;

  bool ready = false;
  int _startGeneration = 0;
  bool _playbackPending = false;
  bool _nodeRecovering = false;
  String? _countedId;
  int _relSession = 0;
  final Map<String, Future<Release>> _fillReleaseFutures = {};
  final ImportSearchCache _importCache = ImportSearchCache();

  final Set<String> _heldKeys = {};
  StreamSubscription<NodeChange>? _nodeSubscription;
  bool _listeningToAudio = false;
  Timer? _notifyTimer;

  /// Background loaders (covers, artwork, releases) finish dozens of items in a
  /// row. Each one used to rebuild the whole UI; coalescing them into one rebuild
  /// per short window keeps scrolling and playback responsive.
  void _notifySoon() {
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 120), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  Track? get current =>
      queue.isEmpty || qi < 0 || qi >= queue.length ? null : byId[queue[qi]];
  bool get playing => audio.playing;
  bool get playbackPending => _playbackPending;
  List<Track> availableTracks() =>
      byId.values.where((track) => track.id.isNotEmpty).toList();

  List<Track> libraryTracks() {
    final unique = <String, Track>{};
    for (final id in savedTrackIds) {
      final track = byId[id];
      if (track != null) unique[track.id] = track;
    }
    return unique.values.toList();
  }

  // -------------------------------------------------------------- lifecycle

  Future<void> init() async {
    _dailySeed = daySeed();
    _scheduleDailyRefresh();
    _nodeSubscription = node.changes.listen((change) {
      final previous = nodeState.active;
      nodeState = change.state;
      if (change.state.active.isNotEmpty &&
          change.state.active != previous &&
          const {'stream', 'unreachable', 'slow'}.contains(change.reason)) {
        showToast(
            'Slow or unstable connection: switched to ${change.state.labelFor(change.state.active)}');
      }
      notifyListeners();
    });
    try {
      nodeState = await node.state();
    } catch (_) {}
    try {
      await node.start();
      nodeState = node.snapshot();
    } catch (_) {}

    final saved = await persistence.loadState();
    final likedList = asList(saved['liked']);
    liked.addAll(likedList.map((v) => v.toString()));
    if (saved['volume'] is num) {
      volume = clampDouble(saved['volume'] as num, 0, 1);
    }
    for (final name in asList(saved['savedArtists'])) {
      final value = name.toString().trim();
      if (value.isNotEmpty) savedArtists[norm(value)] = value;
    }
    for (final raw in asList(saved['plays'])) {
      final entry = PlayEntry.fromJson(asMap(raw));
      if (entry.name.isNotEmpty && entry.count > 0) {
        plays[norm(entry.name)] = entry;
      }
    }
    for (final id in asList(saved['savedTrackIds'])) {
      if (id is String) savedTrackIds.add(id);
    }
    playlists = asList(saved['playlists'])
        .map(asMap)
        .where((p) => asString(p['id']).isNotEmpty && p['ids'] is List)
        .map(Playlist.fromJson)
        .toList();
    final playlistTrackIds = playlists.expand((p) => p.ids).toSet();

    final restoredTracks = asList(saved['savedTracks']);
    if (saved['profile'] is Map) {
      profile = Profile.fromJson(asMap(saved['profile']));
    }
    if (saved['settings'] is Map) {
      settings = AppSettings.fromJson(asMap(saved['settings']));
    }
    if (saved['settings'] is Map) {
      final eq = asMap(asMap(saved['settings'])['eq']);
      if (eq['preset'] is String) settings.eq.preset = eq['preset'].toString();
    }
    if (saved['setup'] is Map) {
      setup = SetupState.fromJson(asMap(saved['setup']));
    } else if (liked.isNotEmpty ||
        playlists.isNotEmpty ||
        plays.isNotEmpty ||
        savedArtists.isNotEmpty ||
        profile.nickname.isNotEmpty ||
        restoredTracks.isNotEmpty) {
      setup.done = true;
    }
    if (profile.nickname.isEmpty &&
        (registeredDisplayName ?? '').trim().isNotEmpty) {
      // Use the registration name as a profile default only after the legacy
      // setup check, so it cannot accidentally skip first-time onboarding.
      final trimmed = registeredDisplayName!.trim();
      profile.nickname =
          trimmed.length > 30 ? trimmed.substring(0, 30) : trimmed;
    }

    for (final raw in restoredTracks) {
      final track = Track.fromJson(asMap(raw));
      final playableSavedTrack =
          (track.source == 'catalog' || track.source == 'hitmoz') &&
              track.playable;
      if (playlistTrackIds.contains(track.id) || playableSavedTrack) {
        if (playableSavedTrack) {
          track.source = 'catalog';
        }
        byId.putIfAbsent(track.id, () => track);
      }
    }

    final restoredQueue =
        asList(saved['queue']).map((id) => id.toString()).toList();
    for (final id in restoredQueue) {
      if (byId.containsKey(id) && !queue.contains(id)) queue.add(id);
    }
    shuffle = asBool(saved['shuffle']);
    if (queue.isNotEmpty) {
      final restoredIndex =
          saved['qi'] is num ? (saved['qi'] as num).toInt() : 0;
      qi = clampInt(restoredIndex, 0, queue.length - 1);
      if (shuffle) _shufflePlayed.add(queue[qi]);
    }
    repeat = const {'off', 'all', 'one'}.contains(asString(saved['repeat']))
        ? asString(saved['repeat'])
        : 'off';

    await audio.setVolume(volume);
    await audio.setQuality(settings.quality);
    await audio.applyEqualizer(settings.eq.enabled, settings.eq.bands);
    audio.onEnded = () => next(auto: true);
    audio.onError = _onAudioError;
    if (!_listeningToAudio) {
      _listeningToAudio = true;
      audio.playingNotifier.addListener(_onPlayingChanged);
      audio.positionNotifier.addListener(_onPosition);
    }

    ready = true;
    notifyListeners();
    // Тяжёлые фоновые загрузки (сеть по всем исполнителям, рекомендации) не стартуют
    // при запуске: они запускаются, когда пользователь реально открывает нужный экран.
    if (pageName == 'home') ensureRecs();
  }

  /// Рекомендации строятся при открытии главной, а не при старте приложения.
  void ensureRecs() {
    if (recsDone || _recsRunning) return;
    scheduleRecs(800);
  }

  bool _knownStarted = false;

  /// Список «играбельных» исполнителей нужен только поиску и онбордингу.
  /// Раньше он запрашивал каталог по каждому известному исполнителю при старте.
  void ensureKnownPlayable() {
    if (_knownStarted) return;
    _knownStarted = true;
    unawaited(_loadKnownPlayable());
  }

  void _onPlayingChanged() {
    notifyListeners();
  }

  void _onPosition() {
    final track = current;
    if (track == null) return;
    if (audio.playing &&
        audio.position.inSeconds > 15 &&
        _countedId != track.id) {
      _countedId = track.id;
      recordPlay(track);
    }
  }

  @override
  void dispose() {
    _nodeSubscription?.cancel();
    _notifyTimer?.cancel();
    _toastTimer?.cancel();
    _recsTimer?.cancel();
    _dayRefreshTimer?.cancel();
    audio.positionNotifier.removeListener(_onPosition);
    audio.playingNotifier.removeListener(_onPlayingChanged);
    super.dispose();
  }

  // ------------------------------------------------------------- persistence

  Map<String, dynamic> storeSnapshot() {
    final inPlaylist = playlists.expand((p) => p.ids).toSet();
    return {
      'liked': liked.toList(),
      'volume': volume,
      'queue': queue,
      'qi': qi,
      'shuffle': shuffle,
      'repeat': repeat,
      'savedArtists': savedArtists.values.toList(),
      'savedTrackIds': savedTrackIds.toList(),
      'plays': plays.values.map((p) => p.toJson()).toList(),
      'playlists': playlists.map((p) => p.toJson()).toList(),
      'savedTracks': byId.values
          .where((t) =>
              inPlaylist.contains(t.id) ||
              (t.source == 'catalog' &&
                  (savedTrackIds.contains(t.id) || liked.contains(t.key))))
          .map((t) => t.toJson())
          .toList(),
      'profile': profile.toJson(),
      'setup': setup.toJson(),
      'settings': settings.toJson(),
    };
  }

  void save() => persistence.scheduleSave(storeSnapshot);

  Future<void> resetAll() async {
    await persistence.deleteState();
    await audio.stop();
    byId.clear();
    liked.clear();
    queue.clear();
    qi = -1;
    shuffle = false;
    _shufflePlayed.clear();
    repeat = 'off';
    lists.clear();
    mixSeeds.clear();
    playlists = [];
    savedArtists.clear();
    savedTrackIds.clear();
    plays.clear();
    similar.clear();
    artists.clear();
    _artistFutures.clear();
    _avatarFutures.clear();
    _releaseIndexFutures.clear();
    homeReleases.clear();
    _releaseForTrack.clear();
    _releaseForTrackFutures.clear();
    _releaseTrackCache.clear();
    noCover.clear();
    _coverTried.clear();
    recArtists = [];
    recTracks = [];
    genreRecLabel = '';
    genreRecTracks = [];
    recsDone = false;
    _recSeedKey = '';
    settings = AppSettings();
    profile = Profile();
    setup = SetupState();
    pageName = 'home';
    pageArg = null;
    history.clear();
    fullScreen = false;
    queueOpen = false;
    _playbackPending = false;
    await audio.applyEqualizer(false, settings.eq.bands);
    await audio.setQuality(settings.quality);
    notifyListeners();
    scheduleRecs(400);
  }

  // ------------------------------------------------------------------- toasts

  void showToast(String message,
      {String? actionLabel, Future<void> Function()? onAction}) {
    _toastTimer?.cancel();
    toastMessage = ToastMessage(++_toastSeq, message, actionLabel, onAction);
    notifyListeners();
    _toastTimer =
        Timer(Duration(milliseconds: actionLabel == null ? 2200 : 9000), () {
      toastMessage = null;
      notifyListeners();
    });
  }

  void refresh() => notifyListeners();

  void dismissToast() {
    _toastTimer?.cancel();
    toastMessage = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- navigation

  void _scheduleDailyRefresh() {
    _dayRefreshTimer?.cancel();
    final now = DateTime.now();
    final nextDay = DateTime(now.year, now.month, now.day + 1);
    _dayRefreshTimer = Timer(nextDay.difference(now), () {
      final seed = daySeed();
      if (seed != _dailySeed) {
        _dailySeed = seed;
        _refreshDailyMixLists();
        notifyListeners();
      }
      _scheduleDailyRefresh();
    });
  }

  void _refreshDailyMixLists() {
    for (var i = 0; i < 5; i++) {
      lists.remove('mix$i');
      mixSeeds.remove('mix$i');
    }
    final mixes = dailyMixes();
    for (var i = 0; i < mixes.length; i++) {
      final key = reg('mix$i', mixes[i].tracks);
      mixSeeds[key] = mixes[i].seed;
    }
  }

  void go(String name, {Object? arg, bool push = true}) {
    if (push) history.add(PageRef(pageName, pageArg));
    pageName = name;
    pageArg = arg;
    // Запросы к каталогу идут только для экрана, который открыт сейчас.
    if (name == 'home') ensureRecs();
    notifyListeners();
  }

  void navTo(String name) {
    history.clear();
    go(name, push: false);
  }

  void back() {
    if (history.isNotEmpty) {
      final previous = history.removeLast();
      pageName = previous.name;
      pageArg = previous.arg;
    } else {
      pageName = 'home';
      pageArg = null;
    }
    notifyListeners();
  }

  void openFull() {
    fullScreen = true;
    audio.positionUpdateInterval = const Duration(milliseconds: 100);
    notifyListeners();
  }

  void closeFull() {
    fullScreen = false;
    audio.positionUpdateInterval = const Duration(seconds: 1);
    notifyListeners();
  }

  void toggleQueue() {
    queueOpen = !queueOpen;
    notifyListeners();
  }

  // ------------------------------------------------------------------- node

  void applyNodeState(NodeState state) {
    nodeState = state;
    notifyListeners();
  }

  Future<void> setServerNode(String id) async {
    if (id.isEmpty || id == nodeState.active) return;
    try {
      final next = await node.set(active: id);
      applyNodeState(next);
      showToast('Server: ${next.labelFor(id)}');
    } catch (_) {
      showToast('Could not switch the server');
    }
  }

  Future<void> toggleNodeAuto() async {
    try {
      applyNodeState(await node.set(autoSwitch: !nodeState.auto));
    } catch (_) {}
  }

  // ------------------------------------------------------------------- track registration

  Track registerTrack(Track track, {bool preferExisting = true}) {
    final existing = byId[track.id];
    if (existing != null && preferExisting) {
      if (track.cover.isNotEmpty &&
          (existing.cover.isEmpty ||
              (track.coverSource == 'deezer' &&
                  existing.coverSource != 'deezer'))) {
        existing.cover = track.cover;
        existing.coverSource = track.coverSource;
      }
      if (existing.src.isEmpty && track.src.isNotEmpty) {
        existing.src = track.src;
      }
      if (existing.duration == 0 && track.duration > 0) {
        existing.duration = track.duration;
      }
      if ((existing.album.isEmpty || existing.album == existing.title) &&
          track.album.isNotEmpty) {
        existing.album = track.album;
      }
      return existing;
    }
    byId[track.id] = track;
    return track;
  }

  String reg(String key, List<Track> tracks) {
    lists[key] = tracks.map((t) => t.id).toList();
    return key;
  }

  List<Track> tracksForList(String key) => (lists[key] ?? const [])
      .map((id) => byId[id])
      .whereType<Track>()
      .toList();

  bool queueIsList(List<String> ids) {
    if (ids.isEmpty || queue.length != ids.length) return false;
    for (var i = 0; i < ids.length; i++) {
      if (queue[i] != ids[i]) return false;
    }
    return true;
  }

  // ------------------------------------------------------------------- playback

  String playableSrc(String src) {
    final value = src.trim();
    if (value.isEmpty) return value;
    final base = node.base;
    if (base.isEmpty) return value;
    if (value.startsWith('/api/audio')) return '$base$value';
    if (cachedRe(r'^https:\/\/([^/]*\.)?hitmoz\.(org|com)\/',
            caseSensitive: false)
        .hasMatch(value)) {
      return '$base/api/audio?url=${Uri.encodeComponent(value)}';
    }
    return value;
  }

  Future<void> playIds(List<String> ids, [int index = 0]) async {
    if (ids.isEmpty) return;
    queue
      ..clear()
      ..addAll(ids);
    qi = clampInt(index, 0, ids.length - 1);
    _shufflePlayed.clear();
    await start();
  }

  Future<void> playSharedTrack(Track shared) async {
    final known = byId[shared.id];
    var track = shared;
    if (known != null &&
        known.playable &&
        compactKey(known.title) == compactKey(shared.title) &&
        known.artists.any((artist) => sameArtist(artist, shared.primary))) {
      track = known;
    }
    if (!track.playable) {
      final results = await catalog.search(
        '${shared.artists.isNotEmpty ? shared.artists.first : ''} ${shared.title}',
      );
      track = matchPlayableTrack(
            results,
            title: shared.title,
            artist: shared.primary,
            album: shared.album,
          ) ??
          Track.empty();
      if (!track.playable) {
        showToast('Could not find playable audio for this shared track.');
        return;
      }
    }
    final registered = registerTrack(track);
    ensureCovers([registered], priority: true);
    await playIds([registered.id]);
  }

  Future<void> start() async {
    final track = current;
    if (track == null) return;
    if (shuffle) _shufflePlayed.add(track.id);
    final generation = ++_startGeneration;
    _countedId = null;
    _playbackPending = true;
    await audio.stop();
    notifyListeners();
    if (generation != _startGeneration || current?.id != track.id) return;
    if (!track.playable) {
      _playbackPending = false;
      showToast('The catalog returned no direct audio link for this track.');
      notifyListeners();
      return;
    }
    try {
      final url = playableSrc(track.src);
      await audio.load(url, volume: volume);
      if (generation != _startGeneration) return;
      if (audio.lastError.isNotEmpty) throw Exception(audio.lastError);
      await audio.play();
      if (generation != _startGeneration) return;
      if (audio.lastError.isNotEmpty) throw Exception(audio.lastError);
      if (pageName == 'home') scheduleRecs(1800);
    } catch (error) {
      if (generation == _startGeneration) {
        await audio.stop();
        showToast(
            'Couldn’t load audio from the selected catalog. Try another search result.');
      }
    } finally {
      if (generation == _startGeneration) _playbackPending = false;
      notifyListeners();
    }
  }

  Future<void> togglePlay() async {
    final track = current;
    if (track == null) return;
    if (_playbackPending) {
      showToast('Starting playback…');
      return;
    }
    if (audio.playing) {
      await audio.pause();
    } else if (audio.position > Duration.zero && audio.lastError.isEmpty) {
      await audio.play();
    } else {
      await start();
    }
    notifyListeners();
  }

  Future<void> next({bool auto = false}) async {
    if (queue.isEmpty) return;
    if (auto && repeat == 'one') {
      await audio.seek(Duration.zero);
      await audio.play();
      return;
    }
    int index;
    if (shuffle && queue.length > 1) {
      var candidates = [
        for (var i = 0; i < queue.length; i++)
          if (i != qi && !_shufflePlayed.contains(queue[i])) i,
      ];
      if (candidates.isEmpty) {
        if (auto && repeat != 'all') {
          await audio.pause();
          await audio.seek(Duration.zero);
          notifyListeners();
          return;
        }
        _shufflePlayed
          ..clear()
          ..add(queue[qi]);
        candidates = [
          for (var i = 0; i < queue.length; i++)
            if (i != qi) i,
        ];
      }
      if (candidates.isEmpty) return;
      index = candidates[math.Random().nextInt(candidates.length)];
      _shufflePlayed.add(queue[index]);
    } else {
      index = qi + 1;
      if (index >= queue.length) {
        if (repeat == 'all' || !auto) {
          index = 0;
        } else {
          await audio.pause();
          await audio.seek(Duration.zero);
          notifyListeners();
          return;
        }
      }
    }
    qi = index;
    await start();
  }

  Future<void> prev() async {
    if (queue.isEmpty) return;
    if (audio.position.inSeconds > 3) {
      await audio.seek(Duration.zero);
      return;
    }
    qi = qi > 0 ? qi - 1 : (repeat == 'all' ? queue.length - 1 : 0);
    await start();
  }

  Future<void> seekSeconds(double seconds) {
    final maximum = duration.inMilliseconds;
    final bounded = maximum > 0
        ? seconds.clamp(0.0, maximum / 1000)
        : math.max(0.0, seconds);
    return audio.seek(
      Duration(milliseconds: (bounded * 1000).round()),
    );
  }

  Future<void> seekToFraction(double fraction) async {
    final total = duration;
    if (total.inMilliseconds <= 0) return;
    await audio.seek(Duration(
        milliseconds:
            (total.inMilliseconds * clampDouble(fraction, 0, 1)).round()));
  }

  Duration get duration {
    if (audio.duration.inMilliseconds > 0) return audio.duration;
    final track = current;
    return track != null && track.duration > 0
        ? Duration(seconds: track.duration)
        : Duration.zero;
  }

  Duration get position => audio.position;

  Future<void> setVolume(double value) async {
    volume = clampDouble(value, 0, 1);
    await audio.setVolume(volume);
    save();
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    shuffle = !shuffle;
    _shufflePlayed
      ..clear()
      ..addAll(shuffle && current != null ? [current!.id] : const []);
    save();
    notifyListeners();
  }

  Future<void> cycleRepeat() async {
    repeat = repeat == 'off' ? 'all' : (repeat == 'all' ? 'one' : 'off');
    notifyListeners();
  }

  void toggleLike(Track? track) {
    if (track == null) return;
    if (liked.contains(track.key)) {
      liked.remove(track.key);
    } else {
      liked.add(track.key);
    }
    save();
    notifyListeners();
  }

  // ------------------------------------------------------------------- queue

  Future<void> queueAdd(String id, {bool playNext = false}) async {
    if (queue.isEmpty || qi < 0) {
      await playIds([id]);
      return;
    }
    if (playNext) {
      queue.insert(qi + 1, id);
    } else {
      queue.add(id);
    }
    showToast(playNext ? 'Will play next' : 'Added to queue');
    notifyListeners();
  }

  Future<void> queueRemove(int index) async {
    if (index < 0 || index >= queue.length) return;
    final wasCurrent = index == qi;
    queue.removeAt(index);
    if (queue.isEmpty) {
      qi = -1;
      _startGeneration++;
      _playbackPending = false;
      await audio.stop();
      notifyListeners();
      return;
    }
    if (index < qi) qi--;
    if (wasCurrent) {
      qi = math.min(index, queue.length - 1);
      await start();
    } else {
      notifyListeners();
    }
  }

  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= queue.length) return;
    qi = index;
    await start();
  }

  final Set<String> _relinkedIds = {};

  Future<void> recoverOnOtherNode() async {
    final track = current;
    if (track == null || !track.playable || _nodeRecovering) return;
    final before = node.base;
    final position = audio.position;
    final wasPlaying = audio.playing;
    _nodeRecovering = true;
    NodeState? state;
    try {
      state = await node.reportStreamFailure();
    } catch (_) {}
    _nodeRecovering = false;

    final nodeChanged =
        state != null && state.base.isNotEmpty && state.base != before;
    if (nodeChanged) {
      applyNodeState(state);
    } else {
      // The node is fine, so the track's own link is the problem (it expired or the
      // upstream refused it). Ask the catalog once for a fresh link to the same song.
      if (_relinkedIds.contains(track.id)) return;
      _relinkedIds.add(track.id);
      final fresh = await _freshLink(track);
      if (fresh == null) return;
      track.src = fresh;
      save();
    }
    await audio.load(playableSrc(track.src), volume: volume);
    await audio.seek(position);
    if (wasPlaying) await audio.play();
  }

  Future<String?> _freshLink(Track track) async {
    final artist = track.artists.isNotEmpty ? track.artists.first : '';
    List<Track> results;
    try {
      results = await catalog.search('$artist ${track.title}'.trim());
    } catch (_) {
      return null;
    }
    final wanted = looseKey(track.title);
    for (final item in results) {
      if (!item.playable || item.src == track.src) continue;
      if (looseKey(item.title) == wanted) return item.src;
    }
    return null;
  }

  void _onAudioError(String message) {
    final track = current;
    if (track == null) return;
    if (cachedRe(r'/api/audio|hitmoz', caseSensitive: false)
        .hasMatch(track.src)) {
      unawaited(recoverOnOtherNode().then((_) {
        if (current?.id == track.id && audio.lastError.isNotEmpty) {
          showToast(
              'Couldn’t load audio from the selected catalog. Try another search result.');
        }
      }));
    }
  }

  // ------------------------------------------------------------------- covers

  void ensureCovers(Iterable<Track> tracks, {bool priority = false}) {
    final fresh = <Track>[];
    for (final track in tracks) {
      if (track.title.isEmpty || track.coverSource == 'deezer') continue;
      if (_coverTried.containsKey(track.id)) continue;
      _coverTried[track.id] = 0;
      fresh.add(track);
    }
    if (fresh.isEmpty) return;
    if (priority) {
      _coverWaiting.insertAll(0, fresh);
    } else {
      _coverWaiting.addAll(fresh);
    }
    _pumpCovers();
  }

  void retryMissingCovers(Iterable<Track> tracks) {
    final retry = <Track>[];
    for (final track in tracks) {
      final attempts = _coverTried[track.id] ?? 0;
      if (track.cover.isNotEmpty ||
          track.title.isEmpty ||
          track.coverSource == 'deezer' ||
          (attempts == 0 && !noCover.contains(track.id))) {
        continue;
      }
      _coverTried.remove(track.id);
      noCover.remove(track.id);
      retry.add(track);
    }
    ensureCovers(retry, priority: true);
  }

  void _pumpCovers() {
    while (_coverBusy < 1 && _coverWaiting.isNotEmpty) {
      final take = math.min(3, _coverWaiting.length);
      final chunk = _coverWaiting.sublist(0, take);
      _coverWaiting.removeRange(0, take);
      _coverBusy++;
      () async {
        var changed = false;
        await Future.wait(chunk.map((track) async {
          try {
            final cover = await meta.coverFor(
              title: track.title,
              artists: track.artists,
              album: track.album,
            );
            if (cover.isEmpty) {
              if (track.cover.isEmpty) {
                changed = noCover.add(track.id) || changed;
              }
            } else {
              track.cover = cover;
              track.coverSource = 'deezer';
              noCover.remove(track.id);
              changed = true;
            }
          } catch (_) {
            final tries = (_coverTried[track.id] ?? 0) + 1;
            _coverTried[track.id] = tries;
            if (tries <= 3) {
              Timer(Duration(seconds: 4 * tries), () {
                _coverWaiting.add(track);
                _pumpCovers();
              });
            } else if (track.cover.isEmpty) {
              changed = noCover.add(track.id) || changed;
            }
          }
        }));
        if (changed) _notifySoon();
        _coverBusy--;
        _pumpCovers();
      }();
    }
  }

  // ------------------------------------------------------------------- artist info

  Future<ArtistInfo> artistInfo(String name) {
    final key = norm(name);
    if (key.isEmpty) return Future.value(ArtistInfo.empty(name));
    return _artistFutures.putIfAbsent(key, () async {
      ArtistInfo info;
      try {
        info = await meta.getArtist(name);
      } catch (_) {
        info = ArtistInfo.empty(name);
      }
      artists[key] = info;
      _notifySoon();
      if (info.avatar.isEmpty) {
        Timer(const Duration(milliseconds: 50000), () {
          _artistFutures.remove(key);
        });
      }
      return info;
    });
  }

  Future<String> avatarOf(String name) {
    final key = norm(name);
    if (key.isEmpty) return Future.value('');
    return _avatarFutures.putIfAbsent(key, () async {
      String url;
      try {
        url = await meta.getAvatar(name);
      } catch (_) {
        url = '';
      }
      if (url.isEmpty) {
        try {
          url = (await artistInfo(name)).avatar;
        } catch (_) {
          url = '';
        }
      }
      if (url.isEmpty) {
        Timer(const Duration(milliseconds: 50000),
            () => _avatarFutures.remove(key));
      }
      return url;
    });
  }

  Future<ReleaseIndex> artistReleaseIndex(String name) {
    final key = norm(name);
    return _releaseIndexFutures.putIfAbsent(key, () async {
      try {
        return await meta.getArtistReleaseIndex(name);
      } catch (_) {
        _releaseIndexFutures.remove(key);
        return ReleaseIndex();
      }
    });
  }

  Future<List<Track>> loadArtistCatalog(List<String> names) async {
    final result = await catalog.artistTracks(names);
    var changed = false;
    for (final track in result.tracks) {
      if (!byId.containsKey(track.id)) {
        byId[track.id] = track;
        changed = true;
      }
    }
    if (changed) {
      // Обложки не ставим для всего каталога: строки запрашивают их сами, когда попадают в окно.
      _notifySoon();
    }
    return result.tracks;
  }

  Future<int?> colorFor(String url) => meta.dominantColor(url);

  // ------------------------------------------------------------------- home releases

  final List<_HomeReleaseJob> _homeRelQueue = [];
  int _homeRelBusy = 0;

  void ensureHomeReleases(Iterable<String> names) {
    for (final name in names) {
      final key = norm(name);
      if (key.isEmpty || homeReleases.containsKey(key)) continue;
      homeReleases[key] = null;
      _homeRelQueue.add(_HomeReleaseJob(key, name));
    }
    _pumpHomeReleases();
  }

  void _pumpHomeReleases() {
    while (_homeRelBusy < 2 && _homeRelQueue.isNotEmpty) {
      final job = _homeRelQueue.removeAt(0);
      _homeRelBusy++;
      () async {
        ReleaseIndex index;
        try {
          index = await meta.getArtistReleaseIndex(job.name);
        } catch (_) {
          index = ReleaseIndex();
        }
        homeReleases[job.key] = index;
        _homeRelBusy--;
        _notifySoon();
        _pumpHomeReleases();
      }();
    }
  }

  List<HomeReleaseItem> pickHomeReleases(
    List<String> names,
    Set<String> used,
    int seed, {
    int albums = 8,
    int singles = 3,
  }) {
    final albumItems = <HomeReleaseItem>[];
    final singleItems = <HomeReleaseItem>[];
    for (final name in names) {
      final index = homeReleases[norm(name)];
      if (index == null) continue;
      for (final release in index.releases) {
        final key = '${norm(name)}|${norm(release.name)}|${release.type}';
        if (used.contains(key)) continue;
        final item = HomeReleaseItem(release, name, key);
        if (release.type == 'single') {
          singleItems.add(item);
        } else {
          albumItems.add(item);
        }
      }
    }
    final out = seededShuffle(albumItems, seed).take(albums).toList();
    final singlesPicked =
        seededShuffle(singleItems, seed + 1).take(singles).toList();
    for (var i = 0; i < singlesPicked.length; i++) {
      out.insert(math.min(out.length, 2 + i * 3), singlesPicked[i]);
    }
    for (final item in out) {
      used.add(item.key);
    }
    return out;
  }

  // ------------------------------------------------------------------- taste / mixes / recs

  bool isUnknownArtist(String key) =>
      key.isEmpty ||
      cachedRe(
              r'unknownartist|неизвестныйисполнитель|unknown artist|неизвестный исполнитель')
          .hasMatch(key);

  void recordPlay(Track track) {
    for (var i = 0; i < track.artists.length; i++) {
      final name = track.artists[i];
      final key = norm(name);
      if (isUnknownArtist(key)) continue;
      final entry = plays[key] ?? PlayEntry(name: name);
      entry.count += i == 0 ? 1 : 0.5;
      entry.last = DateTime.now().millisecondsSinceEpoch;
      plays[key] = entry;
    }
    save();
    // Рекомендации нужны только на главной: во время прослушивания не делаем лишних запросов.
    if (pageName == 'home') scheduleRecs(6000);
  }

  List<TasteArtist> tasteArtists() {
    final weights = <String, TasteArtist>{};
    void add(String name, double value) {
      final key = norm(name);
      if (isUnknownArtist(key)) return;
      final existing = weights[key];
      if (existing != null) {
        weights[key] = TasteArtist(key, existing.name, existing.weight + value);
      } else {
        weights[key] = TasteArtist(key, name, value);
      }
    }

    for (final entry in plays.values) {
      add(entry.name, entry.count);
    }
    for (final track in availableTracks()) {
      if (liked.contains(track.key)) {
        for (var i = 0; i < track.artists.length; i++) {
          add(track.artists[i], i == 0 ? 3 : 1);
        }
      }
      if (savedTrackIds.contains(track.id)) add(track.primary, 2);
    }
    for (final name in savedArtists.values) {
      add(name, 4);
    }
    final list = weights.values.toList()
      ..sort((a, b) => b.weight.compareTo(a.weight));
    return list;
  }

  double _tasteWeight(Track track, Map<String, double> weights) {
    var best = 0.0;
    for (final artist in track.artists) {
      final value = weights[norm(artist)] ?? 0;
      if (value > best) best = value;
    }
    return best;
  }

  List<DailyMix> dailyMixes() {
    final pool = availableTracks()
        .where((t) => t.cover.isNotEmpty || !noCover.contains(t.id))
        .toList();
    if (pool.isEmpty) return [];
    final seed = daySeed();
    final size = math.max(3, math.min(25, (pool.length / 5).ceil()));
    final taste = tasteArtists();
    final mixes = <DailyMix>[];
    final used = <String>{};
    if (taste.isNotEmpty) {
      final weights = {for (final entry in taste) entry.key: entry.weight};
      for (final artist in taste) {
        if (mixes.length >= 5) break;
        final related = (similar[artist.key] ?? const []).map(norm).toSet();
        final free = pool.where((t) => !used.contains(t.id)).toList();
        final own = seededShuffle(
          free
              .where((t) => t.artists.any((a) => norm(a) == artist.key))
              .toList(),
          seed + mixes.length,
        );
        if (own.isEmpty) continue;
        final ownIds = own.map((t) => t.id).toSet();
        final near = seededShuffle(
          free
              .where((t) =>
                  !ownIds.contains(t.id) &&
                  t.artists.any((a) => related.contains(norm(a))))
              .toList(),
          seed + 7 + mixes.length,
        );
        final mix = <Track>[
          ...own.take((size * 0.6).ceil()),
          ...near,
        ];
        if (mix.length < size) {
          final have = mix.map((t) => t.id).toSet();
          final filler = seededShuffle(
            free.where((t) => !have.contains(t.id)).toList(),
            seed + 13 + mixes.length,
          );
          // Score each track once instead of inside the comparator.
          final fillerWeight = {
            for (final t in filler) t.id: _tasteWeight(t, weights)
          };
          filler.sort(
              (a, b) => fillerWeight[b.id]!.compareTo(fillerWeight[a.id]!));
          mix.addAll(filler);
        }
        if (mix.length < 3) continue;
        final limited =
            seededShuffle(mix.take(size).toList(), seed + mixes.length * 3);
        mixes.add(DailyMix(limited, artist.name));
        for (final track in limited) {
          used.add(track.id);
        }
      }
    }
    final left =
        seededShuffle(pool.where((t) => !used.contains(t.id)).toList(), seed);
    for (var i = 0; i < left.length && mixes.length < 5; i += size) {
      final chunk = left.skip(i).take(size).toList();
      if (chunk.length < 3 && mixes.isNotEmpty) break;
      if (chunk.isEmpty) break;
      mixes.add(DailyMix(chunk, chunk.first.primary));
    }
    return mixes;
  }

  void scheduleRecs([int delayMs = 4000]) {
    _recsTimer?.cancel();
    _recsTimer =
        Timer(Duration(milliseconds: delayMs), () => unawaited(buildRecs()));
  }

  Future<void> buildRecs() async {
    // Рекомендации строятся только пока открыта главная.
    if (pageName != 'home') return;
    if (_recsRunning) {
      scheduleRecs(5000);
      return;
    }
    final seeds = tasteArtists().take(5).toList();
    final currentTrack = current;
    if (seeds.isEmpty && currentTrack == null) {
      recsDone = true;
      notifyListeners();
      return;
    }
    final seedKey =
        '${seeds.map((s) => s.key).join('|')}|${currentTrack?.key ?? ''}';
    if (recsDone && _recSeedKey == seedKey) return;
    _recsRunning = true;
    try {
      Map<String, List<String>> map = {};
      try {
        map = await lyricsService
            .similarArtists(seeds.map((s) => s.name).toList());
      } catch (_) {}
      for (var seed in seeds) {
        final list = map[seed.name];
        if (list != null && list.isNotEmpty) similar[seed.key] = list;
      }
      final seen = seeds.map((s) => s.key).toSet();
      for (final track in libraryTracks()) {
        for (final artist in track.artists) {
          seen.add(norm(artist));
        }
      }
      final picked = <({String name, String from})>[];
      for (var round = 0; round < 4; round++) {
        for (final seed in seeds) {
          final list = similar[seed.key] ?? const <String>[];
          if (round >= list.length) continue;
          final name = list[round];
          if (name.isEmpty || seen.contains(norm(name))) continue;
          seen.add(norm(name));
          picked.add((name: name, from: seed.name));
        }
      }
      final batch = picked.take(8).toList();
      final results = List<List<Track>?>.filled(batch.length, null);
      var nextIndex = 0;
      Future<void> worker() async {
        while (nextIndex < batch.length) {
          final index = nextIndex++;
          final candidate = batch[index];
          try {
            final found = await catalog.search(candidate.name);
            results[index] = found
                .where((t) =>
                    t.playable &&
                    t.artists.any((a) => norm(a) == norm(candidate.name)))
                .take(3)
                .toList();
          } catch (_) {
            results[index] = [];
          }
        }
      }

      await Future.wait([worker(), worker()]);
      final artistsOut = <Map<String, String>>[];
      final tracksOut = <Track>[];
      for (var i = 0; i < batch.length; i++) {
        final list = results[i] ?? const <Track>[];
        if (list.isEmpty) continue;
        artistsOut.add({'name': batch[i].name, 'from': batch[i].from});
        for (final track in list) {
          final stored = registerTrack(track);
          if (!tracksOut.any((t) => t.id == stored.id)) tracksOut.add(stored);
        }
      }
      for (final seed in seeds.take(3)) {
        try {
          final found = await catalog.search(seed.name);
          for (final track in found
              .where((t) =>
                  t.playable && t.artists.any((a) => norm(a) == seed.key))
              .take(8)) {
            registerTrack(track);
          }
        } catch (_) {}
      }
      if (currentTrack != null) {
        final genreResult = await meta.genreArtistsForTrack(currentTrack);
        final genreTracks = <Track>[];
        if (genreResult != null) {
          var nextGenreArtist = 0;
          Future<void> genreWorker() async {
            while (nextGenreArtist < genreResult.artists.length &&
                genreTracks.length < 12) {
              final artist = genreResult.artists[nextGenreArtist++];
              if (currentTrack.artists.any((a) => norm(a) == norm(artist))) {
                continue;
              }
              try {
                final matches = await catalog.search(artist);
                for (final match in matches.where((track) =>
                    track.playable &&
                    track.artists.any((a) => norm(a) == norm(artist)))) {
                  final stored = registerTrack(match);
                  if (!genreTracks.any((track) => track.id == stored.id)) {
                    genreTracks.add(stored);
                    if (genreTracks.length >= 12) break;
                  }
                }
              } catch (_) {}
            }
          }

          await Future.wait([genreWorker(), genreWorker()]);
          genreRecLabel = genreResult.genre;
          genreRecTracks = genreTracks;
          ensureCovers(genreTracks);
        } else {
          genreRecLabel = '';
          genreRecTracks = [];
        }
      }
      recArtists = artistsOut;
      recTracks = tracksOut;
      _recSeedKey = seedKey;
      recsDone = true;
      ensureCovers(tracksOut);
      _notifySoon();
    } finally {
      _recsRunning = false;
      recsDone = true;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------- search / resolution

  Future<List<Track>> searchRemote(String query) async {
    final found = await catalog.search(query);
    for (final track in found) {
      registerTrack(track);
    }
    return found;
  }

  Future<String> searchErrorMessage() async {
    final status = catalog.searchStatus;
    if (!status.unavailable) return '';
    final error = status.error;
    if (cachedRe(r'direct audio links?|прямые аудиоссылки',
            caseSensitive: false)
        .hasMatch(error)) {
      return 'The catalog found pages but returned no direct audio file links.';
    }
    if (cachedRe(
            r'ERR_NAME_NOT_RESOLVED|ENOTFOUND|EAI_AGAIN|Failed host lookup',
            caseSensitive: false)
        .hasMatch(error)) {
      return 'The online catalog is unreachable (DNS error). Check your connection or DNS server.';
    }
    return 'The online catalog is not responding right now. Please try again later.';
  }

  Future<Track?> resolveCatalogTrack({
    required String title,
    required String artist,
    String album = '',
    String cover = '',
    Track? catalogTrack,
    bool quiet = false,
  }) async {
    title = title.trim();
    artist = artist.trim();
    if (title.isEmpty) return null;
    final directTrackMatches = catalogTrack != null &&
        compactKey(catalogTrack.title) == compactKey(title) &&
        catalogTrack.artists.any((name) => sameArtist(name, artist));
    if (catalogTrack != null && catalogTrack.playable && directTrackMatches) {
      final direct = catalogTrack.copy();
      direct.cover = cover;
      direct.coverSource = '';
      if (album.isNotEmpty &&
          (direct.album.isEmpty || direct.album == direct.title)) {
        direct.album = album;
      }
      final stored = registerTrack(direct);
      if (stored.coverSource != 'deezer') {
        ensureCovers([stored], priority: true);
      }
      return stored;
    }
    List<Track> results;
    try {
      results = await catalog.search('$artist $title'.trim());
    } catch (_) {
      results = [];
    }
    final match =
        matchPlayableTrack(results, title: title, artist: artist, album: album);
    if (match == null) {
      if (!quiet) {
        showToast('No playable audio was found for this track in the catalog.');
      }
      return null;
    }
    final track = match.copy();
    track.cover = cover;
    track.coverSource = '';
    if (album.isNotEmpty &&
        (track.album.isEmpty || track.album == track.title)) {
      track.album = album;
    }
    final stored = registerTrack(track);
    if (stored.coverSource != 'deezer') {
      ensureCovers([stored], priority: true);
    }
    return stored;
  }

  String releaseTrackKey(Release release, String artist, int index) =>
      '${release.deezerId}|${norm(release.name)}|${norm(artist)}|$index';

  Future<Track?> releaseTrack(Release release, String artist, int index,
      {bool quiet = false}) async {
    if (index < 0 || index >= release.tracks.length) return null;
    final song = release.tracks[index];
    final key = releaseTrackKey(release, artist, index);
    final cached = _releaseTrackCache[key];
    final wantedArtist = song.artist.isEmpty ? artist : song.artist;
    if (cached != null && byId.containsKey(cached.id)) {
      final matches = compactKey(cached.title) == compactKey(song.title) &&
          cached.artists.any((credit) => sameArtist(credit, wantedArtist));
      if (matches) return cached;
      _releaseTrackCache.remove(key);
    }
    if (!quiet) showToast('Looking for audio: ${song.title}');
    final track = await resolveCatalogTrack(
      title: song.title,
      artist: wantedArtist,
      album: release.name,
      cover: song.cover.isNotEmpty ? song.cover : release.cover,
      catalogTrack: song.catalog,
      quiet: quiet,
    );
    if (track != null) {
      _releaseTrackCache[key] = track;
      song.catalog = track;
      _notifySoon();
    }
    return track;
  }

  Future<Release> fillRelease(Release release) async {
    if (release.tracks.isNotEmpty || release.deezerId.isEmpty) {
      return _applyReleaseCorrections(release);
    }
    return _fillReleaseFutures.putIfAbsent(release.deezerId, () async {
      try {
        final filled = await meta.fillRelease(release);
        return _applyReleaseCorrections(filled);
      } catch (_) {
        return release;
      }
    });
  }

  Release _applyReleaseCorrections(Release release) {
    final artist = release.artistName;
    if (!sameArtist(artist, 'Kai Angel') ||
        compactKey(release.name) != 'damage') {
      return release;
    }

    final tracks = List<ReleaseSong>.from(release.tracks);
    final amyIndex = tracks.indexWhere((song) =>
        compactKey(song.title) == 'amy' &&
        sameArtist(song.artist.isEmpty ? artist : song.artist, 'Kai Angel'));
    final amy = amyIndex >= 0
        ? tracks.removeAt(amyIndex)
        : ReleaseSong(
            title: 'amy',
            artist: 'Kai Angel',
            album: 'damage',
            cover: release.cover,
            number: 18,
          );
    if (tracks.length < 17) return release;
    amy.number = 18;
    tracks.insert(17, amy);
    return release.copyWith(
      tracks: tracks,
      trackCount: math.max(release.trackCount, tracks.length),
    );
  }

  Future<void> playRelease(Release release, String artist,
      {int start = 0, bool strictStart = false}) async {
    if (release.tracks.isEmpty) {
      final filled = await fillRelease(release);
      release = filled;
    }
    if (release.tracks.isEmpty) {
      showToast('This release has no tracks');
      return;
    }
    final session = ++_relSession;
    final requested = clampInt(start, 0, release.tracks.length - 1);
    showToast('Looking for audio: ${release.tracks[requested].title}');
    Track? first;
    var at = requested;
    for (; at < release.tracks.length && first == null; at++) {
      if (session != _relSession) return;
      first = await releaseTrack(release, artist, at, quiet: true);
      if (strictStart) break;
    }
    if (session != _relSession) return;
    if (first == null) {
      showToast(strictStart
          ? 'No playable audio was found for "${release.tracks[requested].title}".'
          : 'No playable audio was found for this release in the catalog.');
      return;
    }
    final lead = first;
    await playIds([lead.id]);
    unawaited(() async {
      for (var i = at; i < release.tracks.length; i++) {
        if (session != _relSession || queue.isEmpty || queue.first != lead.id) {
          return;
        }
        final track = await releaseTrack(release, artist, i, quiet: true);
        if (track == null ||
            session != _relSession ||
            queue.isEmpty ||
            queue.first != lead.id) {
          continue;
        }
        if (!queue.contains(track.id)) {
          queue.add(track.id);
          if (queueOpen) notifyListeners();
        }
      }
    }());
  }

  Future<Release?> releaseForTrack(Track track) {
    final key = '${norm(track.primary)}|${norm(track.title)}';
    if (_releaseForTrack.containsKey(key)) {
      return Future.value(_releaseForTrack[key]);
    }
    return _releaseForTrackFutures.putIfAbsent(key, () async {
      Release? release;
      try {
        release = await meta.releaseForTrack(track.title, track.artists);
      } catch (_) {
        release = null;
      }
      _releaseForTrack[key] = release;
      if (release == null) {
        Timer(const Duration(seconds: 15),
            () => _releaseForTrackFutures.remove(key));
      }
      return release;
    });
  }

  // ------------------------------------------------------------------- library

  void toggleSavedArtist(String name) {
    final key = norm(name);
    if (savedArtists.containsKey(key)) {
      savedArtists.remove(key);
      showToast('Artist removed from library');
    } else {
      savedArtists[key] = name;
      showToast('Artist added to library');
    }
    save();
    notifyListeners();
  }

  void removeSavedArtist(String name) {
    savedArtists.remove(norm(name));
    save();
    notifyListeners();
    showToast('Artist removed from library');
  }

  void toggleSavedTrack(Track track) {
    if (savedTrackIds.contains(track.id)) {
      savedTrackIds.remove(track.id);
      showToast('Track removed from library');
    } else {
      savedTrackIds.add(track.id);
      showToast('Track added to library');
    }
    save();
    notifyListeners();
  }

  Playlist createPlaylist(String name, {String? firstId}) {
    final playlist = Playlist(
      id: 'pl-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
          '${math.Random().nextInt(0xFFFFFF).toRadixString(36)}',
      name: name,
      ids: firstId == null ? [] : [firstId],
      created: DateTime.now().millisecondsSinceEpoch,
    );
    playlists.add(playlist);
    save();
    notifyListeners();
    return playlist;
  }

  void deletePlaylist(Playlist playlist) {
    playlists.remove(playlist);
    save();
    notifyListeners();
  }

  void addTrackToPlaylist(Playlist playlist, String trackId) {
    if (playlist.ids.contains(trackId)) {
      showToast('Already in “${playlist.name}”');
      return;
    }
    playlist.ids.add(trackId);
    save();
    notifyListeners();
    showToast('Added to “${playlist.name}”');
  }

  void removeTrackFromPlaylist(Playlist playlist, String trackId) {
    playlist.ids.remove(trackId);
    save();
    notifyListeners();
    showToast('Removed from playlist');
  }

  // ------------------------------------------------------------------- provider bridge

  Future<Track?> importFind(PlaylistImportItem item) async {
    final track = await _importCache.find(catalog, item);
    if (track == null) return null;
    return registerTrack(track);
  }

  Future<void> _loadKnownPlayable() async {
    await Future.delayed(const Duration(seconds: 5));
    final out = <String>{};
    var next = 0;
    Future<void> worker() async {
      while (next < knownArtists.length) {
        final artist = knownArtists[next++];
        try {
          final result = await catalog.artistTracks(artist.names);
          if (!result.reliable || result.tracks.isNotEmpty) {
            out.add(looseKey(artist.name));
          }
        } catch (_) {
          out.add(looseKey(artist.name));
        }
      }
    }

    await Future.wait([worker(), worker(), worker()]);
    knownPlayable = out;
    notifyListeners();
  }

  bool isKnownPlayable(String name) =>
      knownPlayable == null || knownPlayable!.contains(looseKey(name));

  static const Set<String> browseHidden = {
    'deadlytoo',
    'atl smook',
    'silver gloria',
    'offmi',
    'magnum opus',
    'рома хикматов',
    'lil van',
    'jabo',
    'главный герой',
    'saluki',
  };

  bool isBrowseHidden(String name) =>
      browseHidden.contains(name.toLowerCase()) ||
      browseHidden.contains(looseKey(name));

  // ------------------------------------------------------------------- settings

  Future<void> setTheme(String theme) async {
    if (!const {'dark', 'light', 'black'}.contains(theme)) return;
    settings.theme = theme;
    save();
    notifyListeners();
  }

  Future<void> setQuality(String quality) async {
    if (!const {'low', 'normal', 'high'}.contains(quality)) return;
    settings.quality = quality;
    await audio.setQuality(quality);
    save();
    notifyListeners();
  }

  void setArtworkOpen(bool enabled) {
    settings.openArtwork = enabled;
    save();
    notifyListeners();
  }

  void setFullscreenArtworkBlur(bool enabled) {
    settings.blurFullscreenArtwork = enabled;
    save();
    notifyListeners();
  }

  void setFullscreenArtworkVisible(bool enabled) {
    settings.showFullscreenArtwork = enabled;
    save();
    notifyListeners();
  }

  Future<void> setEqEnabled(bool enabled) async {
    settings.eq.enabled = enabled;
    await audio.applyEqualizer(enabled, settings.eq.bands);
    save();
    notifyListeners();
  }

  Future<void> setEqBand(int index, double gain) async {
    if (index < 0 || index >= settings.eq.bands.length) return;
    settings.eq.bands[index] = clampDouble((gain * 2).round() / 2, -12, 12);
    settings.eq.preset = matchEqPreset(settings.eq.bands);
    await audio.applyEqualizer(settings.eq.enabled, settings.eq.bands);
    save();
    notifyListeners();
  }

  Future<void> applyEqPreset(EqPreset preset) async {
    settings.eq.bands = List<double>.from(preset.bands);
    settings.eq.preset = preset.name;
    await audio.applyEqualizer(settings.eq.enabled, settings.eq.bands);
    save();
    notifyListeners();
  }

  Future<void> saveCustomPreset(String rawName) async {
    final name =
        rawName.trim().substring(0, math.min(24, rawName.trim().length));
    if (name.isEmpty) {
      showToast('Give the preset a name');
      return;
    }
    if (builtInEqPresets.any((p) => norm(p.name) == norm(name))) {
      showToast('That name is taken by a built-in preset');
      return;
    }
    final existing =
        settings.eq.custom.indexWhere((p) => norm(p.name) == norm(name));
    final preset =
        EqPreset(name, List<double>.from(settings.eq.bands), custom: true);
    if (existing >= 0) {
      settings.eq.custom[existing] = preset;
    } else {
      settings.eq.custom.add(preset);
    }
    settings.eq.preset = matchEqPreset(settings.eq.bands);
    save();
    notifyListeners();
    showToast('Saved preset “$name”');
  }

  Future<void> deleteCustomPreset(String name) async {
    settings.eq.custom.removeWhere((p) => p.name == name);
    settings.eq.preset = matchEqPreset(settings.eq.bands);
    save();
    notifyListeners();
  }

  Future<void> importEqPreset(String text) async {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map || decoded['lumino'] != 'eq-preset') {
        throw const FormatException();
      }
      final bands = asList(decoded['bands']);
      if (bands.length != 10) throw const FormatException();
      final values = bands
          .map((v) => clampDouble(((v as num?)?.toDouble() ?? 0), -12, 12))
          .toList();
      var name = asString(decoded['name']).trim();
      if (name.isEmpty) name = 'Imported';
      name = name.substring(0, math.min(24, name.length));
      if (builtInEqPresets.any((p) => norm(p.name) == norm(name))) {
        name = '${name.substring(0, math.min(15, name.length))} (imported)';
        name = name.substring(0, math.min(24, name.length));
      }
      final existing =
          settings.eq.custom.indexWhere((p) => norm(p.name) == norm(name));
      final preset = EqPreset(name, values, custom: true);
      if (existing >= 0) {
        settings.eq.custom[existing] = preset;
      } else {
        settings.eq.custom.add(preset);
      }
      settings.eq.bands = values;
      settings.eq.preset = matchEqPreset(values);
      await audio.applyEqualizer(settings.eq.enabled, settings.eq.bands);
      save();
      notifyListeners();
      showToast('Imported “$name”');
    } catch (_) {
      showToast('That isn’t a Lumino preset file');
    }
  }

  String exportEqPreset() {
    final name = settings.eq.preset.isEmpty ? 'My preset' : settings.eq.preset;
    return const JsonEncoder.withIndent('  ').convert({
      'lumino': 'eq-preset',
      'version': 1,
      'name': name,
      'bands': settings.eq.bands,
    });
  }

  // ------------------------------------------------------------------- onboarding

  Future<void> finishSetup({
    required List<String> artistsPicked,
    required String nickname,
    required String avatar,
  }) async {
    for (final name in artistsPicked) {
      savedArtists[norm(name)] = name;
    }
    profile.nickname =
        nickname.trim().substring(0, math.min(30, nickname.trim().length));
    profile.avatar = avatar;
    setup.done = true;
    setup.profile = 'done';
    recsDone = false;
    _recSeedKey = '';
    genreRecLabel = '';
    genreRecTracks = [];
    save();
    notifyListeners();
    scheduleRecs(800);
  }

  // ------------------------------------------------------------------- keyboard reset combo

  void resetHeldKeys() => _heldKeys.clear();

  bool registerKey(String code) {
    _heldKeys.add(code);
    return _heldKeys.contains('ControlLeft') &&
        _heldKeys.contains('AltLeft') &&
        _heldKeys.contains('ShiftLeft');
  }

  void unregisterKey(String code) => _heldKeys.remove(code);
}

const List<EqPreset> builtInEqPresets = [
  EqPreset('Flat', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  EqPreset('Bass booster', [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
  EqPreset('Bass reducer', [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
  EqPreset('Treble booster', [0, 0, 0, 0, 0, 1, 3, 5, 6, 6]),
  EqPreset('Vocal booster', [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
  EqPreset('Acoustic', [4, 4, 3, 1, 1, 1, 3, 3, 3, 2]),
  EqPreset('Electronic', [5, 4, 1, 0, -2, 2, 1, 2, 4, 5]),
  EqPreset('Rock', [5, 4, 2, -1, -2, -1, 2, 3, 4, 5]),
  EqPreset('Pop', [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
  EqPreset('Hip-hop', [5, 4, 1, 3, -1, -1, 1, -1, 2, 3]),
  EqPreset('Classical', [4, 3, 2, 2, -1, -1, 0, 2, 3, 4]),
  EqPreset('Loudness', [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
];

List<EqPreset> allEqPresets(AppState state) => [
      ...builtInEqPresets,
      ...state.settings.eq.custom,
    ];

String matchEqPreset(List<double> bands) {
  for (final preset in [...builtInEqPresets]) {
    if (preset.bands.length == bands.length) {
      var equal = true;
      for (var i = 0; i < bands.length; i++) {
        if (preset.bands[i] != bands[i]) {
          equal = false;
          break;
        }
      }
      if (equal) return preset.name;
    }
  }
  return '';
}
