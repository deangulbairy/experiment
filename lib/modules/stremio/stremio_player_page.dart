import 'dart:async';
import 'dart:io' show Platform;

import 'package:dart_cast/dart_cast.dart' show CastDevice;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mangayomi/services/stremio_addon_service.dart';
import 'package:mangayomi/services/stremio_library_service.dart';
import 'package:mangayomi/services/torrent_server.dart';
import 'package:mangayomi/modules/stremio/cast/cast_controller.dart';
import 'package:mangayomi/modules/stremio/cast/cast_media_builder.dart';
import 'package:mangayomi/modules/stremio/cast/cast_sheet.dart';
import 'package:mangayomi/repositories/settings_repository.dart';
import 'package:mangayomi/utils/platform_utils.dart';
import 'package:mangayomi/utils/system_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shiori/shiori.dart';

class StremioPlayerRequest {
  const StremioPlayerRequest({
    required this.stream,
    required this.title,
    required this.mediaType,
    required this.mediaId,
    required this.parentId,
    required this.parentTitle,
    required this.poster,
    this.episodeTitle,
    this.initialPosition = Duration.zero,
  });

  final StremioStream stream;
  final String title;
  final StremioMediaType mediaType;
  final String mediaId;
  final String parentId;
  final String parentTitle;
  final String poster;
  final String? episodeTitle;
  final Duration initialPosition;
}

class StremioPlayerPage extends StatefulWidget {
  const StremioPlayerPage({
    super.key,
    required this.stream,
    required this.title,
    required this.mediaType,
    required this.mediaId,
    required this.parentId,
    required this.parentTitle,
    required this.poster,
    this.episodeTitle,
    this.initialPosition = Duration.zero,
  });

  final StremioStream stream;
  final String title;
  final StremioMediaType mediaType;
  final String mediaId;
  final String parentId;
  final String parentTitle;
  final String poster;
  final String? episodeTitle;
  final Duration initialPosition;

  @override
  State<StremioPlayerPage> createState() => _StremioPlayerPageState();
}

class _StremioPlayerPageState extends State<StremioPlayerPage> {
  final Player _player = Player();
  final CastController _cast = CastController.instance;
  late final VideoController _controller = VideoController(
    _player,
    configuration: VideoControllerConfiguration(
      hwdec: settingsRepository.current.hwdecMode ?? 'auto',
      enableHardwareAcceleration:
          settingsRepository.current.enableHardwareAcceleration ??
          !(Platform.isMacOS || Platform.isWindows),
      vo: Platform.isAndroid ? 'gpu' : 'libmpv',
    ),
  );
  bool _loading = true;
  String? _error;
  String? _torrentHash;
  String? _playbackUrl;
  Map<String, String>? _playbackHeaders;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<String>? _errorSubscription;
  Timer? _progressTimer;
  bool _addedToLibrary = false;

  @override
  void initState() {
    super.initState();
    _cast.attach();
    _position = widget.initialPosition;
    _positionSubscription = _player.stream.position.listen((position) {
      _position = position;
    });
    _durationSubscription = _player.stream.duration.listen((duration) {
      _duration = duration;
    });
    _errorSubscription = _player.stream.error.listen((error) {
      final message = error.trim();
      if (message.isEmpty || !mounted) return;
      setState(() {
        _loading = false;
        _error = 'Playback failed: $message';
      });
    });
    _cast.position.addListener(_onCastPositionChanged);
    _cast.duration.addListener(_onCastDurationChanged);
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_saveLibraryProgress());
    });
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive));
    if (isMobile && (settingsRepository.current.forceLandscapePlayer ?? false)) {
      unawaited(SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]));
    }
    _openStream();
  }

  Future<void> _openStream() async {
    try {
      if (mounted) {
        setState(() {
          _loading = true;
          _error = null;
        });
      }
      final stream = widget.stream;
      var url = stream.url ?? '';
      if (url.startsWith('magnet:')) {
        url = await _openTorrent(stream.magnetUri);
      } else if ((url.isEmpty || !url.startsWith(RegExp(r'https?://'))) &&
          stream.infoHash?.isNotEmpty == true) {
        url = await _openTorrent(stream.magnetUri);
      }
      if (url.isEmpty) {
        throw const StremioAddonException('This stream does not contain a playable URL.');
      }
      var playbackHeaders = <String, String>{...?stream.headers};
      if (url.startsWith(RegExp(r'https?://'))) {
        final sourceUri = Uri.parse(url);
        url = await StremioAddonService().resolveStreamUrl(
          url,
          headers: playbackHeaders,
        );
        final resolvedUri = Uri.tryParse(url);
        if (resolvedUri != null && sourceUri.origin != resolvedUri.origin) {
          playbackHeaders.removeWhere(
            (key, _) => const {
              'authorization',
              'cookie',
              'proxy-authorization',
              'host',
            }.contains(key.toLowerCase()),
          );
        }
      }
      _playbackUrl = url;
      _playbackHeaders = playbackHeaders.isEmpty ? null : playbackHeaders;
      await _player.open(
        Media(
          url,
          httpHeaders: _playbackHeaders,
          start: widget.initialPosition,
        ),
        play: true,
      );
      if (!mounted) return;
      setState(() => _loading = false);
      _addedToLibrary = true;
      unawaited(_saveLibraryProgress());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<String> _openTorrent(String magnet) async {
    if (magnet.isEmpty) {
      throw const StremioAddonException('The torrent stream is missing its info hash.');
    }
    final (videos, hash) = await MTorrentServer().getTorrentPlaylist(
      magnet,
      null,
      sources: widget.stream.trackers,
    );
    if (videos.isEmpty) {
      throw const StremioAddonException('No playable video files were found in this torrent.');
    }
    _torrentHash = hash ?? widget.stream.infoHash;
    final index = widget.stream.fileIndex;
    if (index != null && index >= 0 && index < videos.length) {
      return videos[index].url;
    }
    return videos.first.url;
  }

  Future<void> _showCastSheet() => showCastSheet(
        context,
        controller: _cast,
        onDeviceSelected: (device) {
          Navigator.of(context).pop();
          unawaited(_castToDevice(device));
        },
        onStopCasting: () => unawaited(_cast.end()),
      );

  Future<void> _castToDevice(CastDevice device) async {
    final url = _playbackUrl;
    if (url == null) return;
    final started = await _cast.start(
      device,
      () => buildCastMedia(
        url: url,
        isLocal: false,
        headers: _playbackHeaders ?? widget.stream.headers,
        title: widget.title,
        start: _position,
      ),
    );
    if (started) await _player.pause();
  }

  Future<void> _saveLibraryProgress() async {
    if (!_addedToLibrary) return;
    try {
      await StremioLibraryService.instance.savePlayback(
        mediaType: widget.mediaType,
        mediaId: widget.mediaId,
        parentId: widget.parentId,
        title: widget.title,
        parentTitle: widget.parentTitle,
        poster: widget.poster,
        episodeTitle: widget.episodeTitle,
        stream: widget.stream,
        position: _position,
        duration: _duration,
      );
    } catch (_) {}
  }

  void _onCastPositionChanged() {
    if (_cast.isCasting) _position = _cast.position.value;
  }

  void _onCastDurationChanged() {
    if (_cast.isCasting && _cast.duration.value > Duration.zero) {
      _duration = _cast.duration.value;
    }
  }

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    _cast.position.removeListener(_onCastPositionChanged);
    _cast.duration.removeListener(_onCastDurationChanged);
    _progressTimer?.cancel();
    unawaited(_saveLibraryProgress());
    _cast.detach();
    restoreSystemUI();
    if (isMobile) {
      unawaited(SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]));
    }
    final infoHash = _torrentHash;
    unawaited(() async {
      await _player.stop();
      await _player.dispose();
      if (infoHash != null && infoHash.isNotEmpty) {
        await MTorrentServer().removeTorrent(infoHash);
      }
    }());
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Video(
            controller: _controller,
            fit: BoxFit.contain,
            controls: (_) => const SizedBox.shrink(),
          ),
          SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [ShioriScrim.panel, Colors.transparent],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back to streams',
                        onPressed: () => Navigator.of(context).pop(),
                        color: Colors.white,
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(color: Colors.white),
                        ),
                      ),
                      CastButton(
                        controller: _cast,
                        onPressed: _loading || _playbackUrl == null
                            ? null
                            : _showCastSheet,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_loading)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          if (_error != null)
            ColoredBox(
              color: ShioriScrim.panel,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.white,
                        size: 40,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: _openStream,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try this stream again'),
                      ),
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                        label: const Text('Back to streams'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (!_loading && _error == null)
            ListenableBuilder(
              listenable: _cast,
              builder: (context, _) => _cast.isCasting
                  ? Align(
                      alignment: Alignment.bottomCenter,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            'Casting to ${_cast.device?.name ?? 'TV'}. Tap the cast icon for playback controls.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    )
                  : Align(
                      alignment: Alignment.bottomCenter,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, ShioriScrim.panel],
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 28, 12, 8),
                          child: StreamBuilder<bool>(
                            stream: _player.stream.playing,
                            builder: (context, snapshot) {
                              final isPlaying = snapshot.data ?? false;
                              return StreamBuilder<Duration>(
                                stream: _player.stream.position,
                                builder: (context, positionSnapshot) =>
                                    StreamBuilder<Duration>(
                                  stream: _player.stream.duration,
                                  builder: (context, durationSnapshot) {
                                    final position =
                                        positionSnapshot.data ?? Duration.zero;
                                    final duration =
                                        durationSnapshot.data ?? Duration.zero;
                                    final max =
                                        duration.inMilliseconds.toDouble();
                                    final value = position.inMilliseconds
                                        .toDouble()
                                        .clamp(0, max > 0 ? max : 1)
                                        .toDouble();
                                    return Row(
                                      children: [
                                        IconButton(
                                          tooltip: isPlaying ? 'Pause' : 'Play',
                                          color: Colors.white,
                                          onPressed: () => isPlaying
                                              ? _player.pause()
                                              : _player.play(),
                                          icon: Icon(
                                            isPlaying
                                                ? Icons.pause
                                                : Icons.play_arrow,
                                          ),
                                        ),
                                        Text(
                                          _formatDuration(position),
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                        Expanded(
                                          child: Slider(
                                            min: 0,
                                            max: max > 0 ? max : 1,
                                            value: value,
                                            onChanged: duration == Duration.zero
                                                ? null
                                                : (value) => _player.seek(
                                                    Duration(
                                                      milliseconds:
                                                          value.round(),
                                                    ),
                                                  ),
                                          ),
                                        ),
                                        Text(
                                          _formatDuration(duration),
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}
