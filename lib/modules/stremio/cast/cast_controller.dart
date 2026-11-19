// Adapted from https://github.com/IStoleThis/chromecast-testing (Apache-2.0).
import 'dart:async';

import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'cast_discovery.dart';

enum CastStatus { idle, searching, connecting, casting }

/// App-wide Chromecast state.
///
/// It is a singleton so a cast session outlives a single player screen: when
/// "play next episode" replaces the player, the new screen finds the session
/// still open and loads the next episode onto the same TV.
///
/// Playback position and duration are separate [ValueNotifier]s because they
/// tick every second, and most listeners only care about the structural state
/// (device list, connecting, casting, errors) that [notifyListeners] reports.
class CastController extends ChangeNotifier {
  CastController._();

  static final CastController instance = CastController._();

  late final CastService _service = CastService(
    discoveryProviders: [
      ChromecastDiscoveryProvider(
        mdnsLookup: useNativeDiscovery ? bonsoirLookup : null,
      ),
    ],
    sessionFactory: (device) => ChromecastSession(device: device),
  );

  /// Where the TV is in the media, while casting.
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  /// How long the media on the TV is, once the receiver has reported it.
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);

  final StreamController<void> _finished = StreamController<void>.broadcast();

  /// Fires when the media on the TV plays through to its end.
  Stream<void> get onFinished => _finished.stream;

  CastStatus _status = CastStatus.idle;
  List<CastDevice> _devices = const [];
  CastDevice? _device;
  CastSession? _session;
  SessionState _sessionState = SessionState.disconnected;
  double? _volume;
  String? _error;
  Duration _lastLivePosition = Duration.zero;

  StreamSubscription<List<CastDevice>>? _discoverySub;
  Timer? _searchTimer;
  final List<StreamSubscription<dynamic>> _sessionSubs = [];

  int _attachedViews = 0;
  Timer? _orphanTimer;

  CastStatus get status => _status;
  bool get isCasting => _status == CastStatus.casting;
  bool get isBusy =>
      _status == CastStatus.connecting || _status == CastStatus.casting;
  List<CastDevice> get devices => _devices;
  CastDevice? get device => _device;
  double? get volume => _volume;
  String? get error => _error;
  bool get isPlaying =>
      _sessionState == SessionState.playing ||
      _sessionState == SessionState.buffering ||
      _sessionState == SessionState.loading;

  // ---------------------------------------------------------------------------
  // Player screens come and go; the session is dropped once none is left.
  // ---------------------------------------------------------------------------

  /// A player screen started using the controller.
  void attach() {
    _attachedViews++;
    _orphanTimer?.cancel();
    _orphanTimer = null;
  }

  /// A player screen is done. If it was the last one and a session is open,
  /// the session ends after a short grace period, which lets the next
  /// episode's screen take it over instead.
  void detach() {
    if (_attachedViews > 0) _attachedViews--;
    if (_attachedViews > 0) return;
    if (_session == null) {
      _stopSearching();
      return;
    }
    _orphanTimer?.cancel();
    _orphanTimer = Timer(const Duration(seconds: 6), () {
      if (_attachedViews == 0) unawaited(end());
    });
  }

  // ---------------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------------

  /// Looks for Chromecasts on the local network for a few seconds.
  Future<void> discover() async {
    if (isBusy) return;
    await _discoverySub?.cancel();
    _discoverySub = null;
    _searchTimer?.cancel();

    _devices = const [];
    _error = null;
    _status = CastStatus.searching;
    notifyListeners();

    const timeout = Duration(seconds: 15);
    try {
      _discoverySub = _service
          .startDiscovery(
            protocols: {CastProtocol.chromecast},
            timeout: timeout,
          )
          .listen(
            (found) {
              _devices = [...found]
                ..sort(
                  (a, b) =>
                      a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                );
              notifyListeners();
            },
            onError: (Object error) {
              _error = 'Could not search for devices: $error';
              _endSearch();
            },
            onDone: _endSearch,
          );
      // Discovery should close itself at the timeout; this is the backstop.
      _searchTimer = Timer(timeout + const Duration(seconds: 2), _endSearch);
    } catch (error) {
      _error = 'Could not search for devices: $error';
      _endSearch();
    }
  }

  void _endSearch() {
    _searchTimer?.cancel();
    _searchTimer = null;
    if (_status == CastStatus.searching) {
      _status = CastStatus.idle;
      notifyListeners();
    }
  }

  void _stopSearching() {
    unawaited(_discoverySub?.cancel());
    _discoverySub = null;
    _service.stopDiscovery();
    _endSearch();
  }

  // ---------------------------------------------------------------------------
  // Session
  // ---------------------------------------------------------------------------

  /// Connects to [device] and starts the media [buildMedia] returns on it.
  /// Returns whether it worked; on failure [error] says why.
  ///
  /// The media is built once connected so the "connecting" state shows while
  /// the stream is being inspected, which can take a few seconds.
  Future<bool> start(
    CastDevice device,
    Future<CastMedia> Function() buildMedia,
  ) async {
    _orphanTimer?.cancel();
    _stopSearching();

    _error = null;
    _device = device;
    _status = CastStatus.connecting;
    notifyListeners();

    try {
      final session = await _service.connect(device);
      _bind(session);
      final media = await buildMedia();
      _resetProgress(media);
      await session.loadMedia(media);
      _status = CastStatus.casting;
      unawaited(WakelockPlus.enable());
      notifyListeners();
      return true;
    } catch (error) {
      await _abort('Could not cast to ${device.name}: $error');
      return false;
    }
  }

  /// Switches the TV to [media] on the open session, e.g. for the next
  /// episode or another quality.
  Future<bool> load(CastMedia media) async {
    final session = _session;
    if (session == null) return false;
    try {
      _resetProgress(media);
      await session.loadMedia(media);
      _error = null;
      notifyListeners();
      return true;
    } catch (error) {
      _error = 'The TV could not play this: $error';
      notifyListeners();
      return false;
    }
  }

  Future<void> play() => _command((s) => s.play());

  Future<void> pause() => _command((s) => s.pause());

  Future<void> togglePlayPause() => isPlaying ? pause() : play();

  Future<void> seek(Duration to) async {
    final total = duration.value;
    var target = to < Duration.zero ? Duration.zero : to;
    if (total > Duration.zero && target > total) target = total;
    position.value = target;
    await _command((s) => s.seek(target));
  }

  Future<void> seekBy(Duration delta) => seek(position.value + delta);

  Future<void> setVolume(double value) {
    final volume = value.clamp(0.0, 1.0).toDouble();
    _volume = volume;
    notifyListeners();
    return _command((s) => s.setVolume(volume));
  }

  /// Stops what is playing on the TV and disconnects from it.
  Future<void> end() async {
    final session = _session;
    await _release();
    if (session == null) return;
    try {
      await session.stop();
    } catch (_) {}
    try {
      await session.disconnect();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _bind(CastSession session) {
    _session = session;
    _sessionState = session.state;
    _volume = null;
    _sessionSubs
      ..add(session.stateStream.listen(_onSessionState))
      ..add(
        session.positionStream.listen((value) {
          position.value = value;
          if (_sessionState == SessionState.playing) _lastLivePosition = value;
        }),
      )
      ..add(session.durationStream.listen((value) => duration.value = value))
      ..add(
        session.volumeStream.listen((value) {
          _volume = value;
          notifyListeners();
        }),
      );
  }

  void _resetProgress(CastMedia media) {
    position.value = media.startPosition ?? Duration.zero;
    duration.value = Duration.zero;
    _lastLivePosition = position.value;
  }

  void _onSessionState(SessionState next) {
    final previous = _sessionState;
    _sessionState = next;

    if (next == SessionState.disconnected) {
      // The TV (or the network) ended the session.
      if (_session != null) unawaited(_release());
      return;
    }

    final wasPlaying =
        previous == SessionState.playing ||
        previous == SessionState.buffering ||
        previous == SessionState.paused;
    if (next == SessionState.idle &&
        wasPlaying &&
        _status == CastStatus.casting &&
        _endedNearTheEnd()) {
      _finished.add(null);
    }
    notifyListeners();
  }

  bool _endedNearTheEnd() {
    final total = duration.value;
    return total > Duration.zero &&
        _lastLivePosition >= total - const Duration(seconds: 15);
  }

  Future<void> _command(Future<void> Function(CastSession session) run) async {
    final session = _session;
    if (session == null) return;
    try {
      await run(session);
    } catch (error) {
      _error = 'The TV did not respond: $error';
      notifyListeners();
    }
  }

  /// Gives up on a session that failed to start, remembering [message].
  Future<void> _abort(String message) async {
    final session = _session;
    await _release();
    _error = message;
    notifyListeners();
    try {
      await session?.disconnect();
    } catch (_) {}
  }

  Future<void> _release() async {
    for (final sub in _sessionSubs) {
      unawaited(sub.cancel());
    }
    _sessionSubs.clear();
    _session = null;
    _device = null;
    _sessionState = SessionState.disconnected;
    _status = CastStatus.idle;
    unawaited(WakelockPlus.disable());
    notifyListeners();
  }
}

