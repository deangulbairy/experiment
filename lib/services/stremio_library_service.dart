import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mangayomi/services/secure_storage.dart';
import 'package:mangayomi/services/stremio_addon_service.dart';

const _stremioLibraryKey = 'stremioContinueWatching';

/// A movie or the most recently played episode of a series in the watch list.
class StremioLibraryEntry {
  const StremioLibraryEntry({
    required this.mediaType,
    required this.mediaId,
    required this.parentId,
    required this.title,
    required this.parentTitle,
    required this.poster,
    required this.episodeTitle,
    required this.stream,
    required this.position,
    required this.duration,
    required this.lastPlayedAt,
  });

  final StremioMediaType mediaType;
  final String mediaId;
  final String parentId;
  final String title;
  final String parentTitle;
  final String poster;
  final String? episodeTitle;
  final StremioStream stream;
  final Duration position;
  final Duration duration;
  final DateTime lastPlayedAt;

  /// A series occupies one library card, updated to its latest episode.
  String get libraryId =>
      mediaType == StremioMediaType.series ? parentId : mediaId;

  String get cardTitle =>
      mediaType == StremioMediaType.series ? parentTitle : title;

  String get playbackTitle => episodeTitle ?? title;

  double get progress {
    if (duration <= Duration.zero) return 0;
    return (position.inMilliseconds / duration.inMilliseconds)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  Map<String, dynamic> toJson() => {
    'mediaType': mediaType.protocolName,
    'mediaId': mediaId,
    'parentId': parentId,
    'title': title,
    'parentTitle': parentTitle,
    'poster': poster,
    'episodeTitle': episodeTitle,
    'stream': stream.toStorageJson(),
    'positionMs': position.inMilliseconds,
    'durationMs': duration.inMilliseconds,
    'lastPlayedAt': lastPlayedAt.millisecondsSinceEpoch,
  };

  factory StremioLibraryEntry.fromJson(Map<String, dynamic> json) {
    final type = json['mediaType']?.toString();
    final streamData = json['stream'];
    if (streamData is! Map) {
      throw const FormatException('Saved Stremio item is missing its stream.');
    }
    return StremioLibraryEntry(
      mediaType: type == StremioMediaType.series.protocolName
          ? StremioMediaType.series
          : StremioMediaType.movie,
      mediaId: json['mediaId']?.toString() ?? '',
      parentId: json['parentId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      parentTitle: json['parentTitle']?.toString() ?? '',
      poster: json['poster']?.toString() ?? '',
      episodeTitle: json['episodeTitle']?.toString(),
      stream: StremioStream.fromStorageJson(
        streamData.cast<String, dynamic>(),
      ),
      position: Duration(
        milliseconds: int.tryParse(json['positionMs']?.toString() ?? '') ?? 0,
      ),
      duration: Duration(
        milliseconds: int.tryParse(json['durationMs']?.toString() ?? '') ?? 0,
      ),
      lastPlayedAt: DateTime.fromMillisecondsSinceEpoch(
        int.tryParse(json['lastPlayedAt']?.toString() ?? '') ?? 0,
      ),
    );
  }
}

/// Securely persists Stremio playback so it can be resumed from the library.
class StremioLibraryService extends ChangeNotifier {
  StremioLibraryService._();

  static final StremioLibraryService instance = StremioLibraryService._();

  static const _maxEntries = 100;
  List<StremioLibraryEntry>? _entries;
  Future<void> _writeQueue = Future<void>.value();

  Future<List<StremioLibraryEntry>> getEntries() async {
    if (_entries != null) return List.unmodifiable(_entries!);
    final encoded = await secureStorage.read(key: _stremioLibraryKey);
    if (encoded == null || encoded.isEmpty) {
      _entries = const [];
      return _entries!;
    }
    try {
      final decoded = jsonDecode(encoded);
      final entries = decoded is List
          ? decoded.whereType<Map>().map((item) {
              try {
                return StremioLibraryEntry.fromJson(
                  item.cast<String, dynamic>(),
                );
              } catch (_) {
                return null;
              }
            }).whereType<StremioLibraryEntry>().toList()
          : <StremioLibraryEntry>[];
      _entries = entries
        ..sort((a, b) => b.lastPlayedAt.compareTo(a.lastPlayedAt));
    } catch (_) {
      _entries = const [];
    }
    return List.unmodifiable(_entries!);
  }

  Future<void> savePlayback({
    required StremioMediaType mediaType,
    required String mediaId,
    required String parentId,
    required String title,
    required String parentTitle,
    required String poster,
    required String? episodeTitle,
    required StremioStream stream,
    required Duration position,
    required Duration duration,
  }) async {
    final previousWrite = _writeQueue;
    final nextWrite = Completer<void>();
    _writeQueue = nextWrite.future;
    await previousWrite;
    try {
      final current = await getEntries();
      final entry = StremioLibraryEntry(
        mediaType: mediaType,
        mediaId: mediaId,
        parentId: parentId,
        title: title,
        parentTitle: parentTitle,
        poster: poster,
        episodeTitle: episodeTitle,
        stream: stream,
        position: position,
        duration: duration,
        lastPlayedAt: DateTime.now(),
      );
      _entries = [
        entry,
        ...current.where((item) => item.libraryId != entry.libraryId),
      ].take(_maxEntries).toList();
      await secureStorage.write(
        key: _stremioLibraryKey,
        value: jsonEncode(_entries!.map((item) => item.toJson()).toList()),
      );
      notifyListeners();
    } finally {
      nextWrite.complete();
    }
  }
}
