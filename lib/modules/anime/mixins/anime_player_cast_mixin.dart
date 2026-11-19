part of '../anime_player_view.dart';

mixin AnimePlayerCastMixin on riv.ConsumerState<AnimeStreamPage> {
  Player get castPlayer;
  ValueNotifier<VideoPrefs?> get castVideo;
  ValueNotifier<Duration> get castCurrentPosition;
  vid.Video get castFallbackVideo;
  void Function(bool) get castPlaybackCompleted;

  final CastController _cast = CastController.instance;
  StreamSubscription<void>? _castFinishedSub;
  StreamSubscription<bool>? _castLocalPlayingSub;
  bool _wasCasting = false;
  bool _addedAnimeToLibrary = false;
  Future<void>? _addingAnimeToLibrary;

  void _initCast() {
    _cast.attach();
    _wasCasting = _cast.isCasting;
    _cast.addListener(_onCastChanged);
    _cast.position.addListener(_onCastPosition);
    _castFinishedSub = _cast.onFinished.listen(
      (_) => castPlaybackCompleted(true),
    );
    _castLocalPlayingSub = castPlayer.stream.playing.listen((playing) {
      if (playing) unawaited(_addAnimeToLibrary());
      // Keep the phone's decoder quiet while the TV owns playback. The cast
      // sheet remains the remote for play, pause, seeking, and volume.
      if (playing && _cast.isCasting) unawaited(castPlayer.pause());
    });
  }

  void _disposeCast() {
    _cast.removeListener(_onCastChanged);
    _cast.position.removeListener(_onCastPosition);
    unawaited(_castFinishedSub?.cancel());
    unawaited(_castLocalPlayingSub?.cancel());
    _cast.detach();
  }

  void _openCastSheet() {
    showCastSheet(
      context,
      controller: _cast,
      onDeviceSelected: (device) {
        Navigator.of(context).pop();
        unawaited(_castToDevice(device));
      },
      onStopCasting: () => unawaited(_cast.end()),
    );
  }

  Future<void> _castToDevice(CastDevice device) async {
    final prefs = castVideo.value;
    if (prefs?.videoTrack == null) return;
    final wasPlaying = castPlayer.state.playing;
    await castPlayer.pause();
    final started = await _cast.start(
      device,
      () => _buildAnimeCastMedia(prefs!, castCurrentPosition.value),
    );
    if (started) unawaited(_addAnimeToLibrary());
    if (!started && wasPlaying && mounted) await castPlayer.play();
  }

  Future<CastMedia> _buildAnimeCastMedia(VideoPrefs prefs, Duration start) {
    final url = prefs.videoTrack!.id;
    final video = widget.videos.firstWhere(
      (item) => (widget.isLocal ? item.originalUrl : item.url) == url,
      orElse: () => castFallbackVideo,
    );
    final series = widget.episode.manga.value?.name;
    final episode = widget.episode.name;
    final title = [series, episode]
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .join(' · ');
    return buildCastMedia(
      url: url,
      isLocal: widget.isLocal,
      headers: prefs.headers,
      title: title,
      start: start,
      subtitles: video.subtitles,
    );
  }

  Future<void> _castLoad(VideoPrefs prefs, Duration start) async {
    try {
      final media = await _buildAnimeCastMedia(prefs, start);
      if (mounted && _cast.isCasting) await _cast.load(media);
    } catch (_) {}
  }

  void _onCastPosition() {
    if (_cast.isCasting) {
      castCurrentPosition.value = _cast.position.value;
    }
  }

  void _onCastChanged() {
    final casting = _cast.isCasting;
    if (_wasCasting && !casting && mounted) {
      unawaited(castPlayer.seek(_cast.position.value));
      castCurrentPosition.value = _cast.position.value;
    }
    _wasCasting = casting;
  }

  Future<void> _addAnimeToLibrary() async {
    if (_addedAnimeToLibrary) return;
    final inFlight = _addingAnimeToLibrary;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final save = _saveAnimeToLibrary();
    _addingAnimeToLibrary = save;
    try {
      await save;
    } finally {
      _addingAnimeToLibrary = null;
    }
  }

  Future<void> _saveAnimeToLibrary() async {
    try {
      final mangaId = widget.episode.mangaId ?? widget.episode.manga.value?.id;
      if (mangaId == null) return;
      final manga = await mangaRepository.findByIdAsync(mangaId) ??
          widget.episode.manga.value;
      if (manga == null) return;
      if (manga.favorite != true || manga.dateAdded == null) {
        manga
          ..favorite = true
          ..dateAdded ??= DateTime.now().millisecondsSinceEpoch;
        await mangaRepository.save(manga);
      }
      _addedAnimeToLibrary = true;
    } catch (_) {
      // Leave it retryable if playback emits another start event.
    }
  }
}
