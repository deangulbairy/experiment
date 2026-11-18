// Adapted from https://github.com/IStoleThis/chromecast-testing (Apache-2.0).
import 'dart:async';
import 'dart:convert';

import 'package:dart_cast/dart_cast.dart';
import 'package:http/http.dart' as http;
import 'package:mangayomi/models/video.dart' as vid;

/// Builds the [CastMedia] for what the player is currently showing.
///
/// Remote streams keep the headers (Referer, cookies, ...) the source needs;
/// dart_cast's proxy adds them when the TV fetches the stream, since a
/// Chromecast can't send custom headers itself.
Future<CastMedia> buildCastMedia({
  required String url,
  required bool isLocal,
  Map<String, String>? headers,
  String? title,
  Duration? start,
  List<vid.Track>? subtitles,
}) async {
  final startPosition = (start != null && start > Duration.zero) ? start : null;

  if (isLocal) {
    return CastMedia.file(
      filePath: url,
      type: _typeFromExtension(url) ?? CastMediaType.mp4,
      title: title,
      startPosition: startPosition,
    );
  }

  final type = await detectCastType(url, headers: headers);
  final castSubtitles = _castSubtitles(subtitles);
  return CastMedia(
    url: url,
    type: type,
    httpHeaders: headers ?? const {},
    title: title,
    startPosition: startPosition,
    subtitles: castSubtitles,
    defaultSubtitle: _defaultSubtitle(castSubtitles),
  );
}

/// Works out whether [url] is an HLS playlist or a plain file.
///
/// The extension decides when it is conclusive. Some sources serve HLS from
/// URLs with no extension, so those get a tiny ranged request to look for the
/// `#EXTM3U` header; anything that can't be read is treated as an MP4.
Future<CastMediaType> detectCastType(
  String url, {
  Map<String, String>? headers,
}) async {
  final byExtension = _typeFromExtension(url);
  if (byExtension != null) return byExtension;

  try {
    final response = await http
        .get(Uri.parse(url), headers: {...?headers, 'Range': 'bytes=0-63'})
        .timeout(const Duration(seconds: 6));
    final head = utf8.decode(
      response.bodyBytes.take(64).toList(),
      allowMalformed: true,
    );
    if (head.trimLeft().startsWith('#EXTM3U')) return CastMediaType.hls;
  } catch (_) {}
  return CastMediaType.mp4;
}

CastMediaType? _typeFromExtension(String url) {
  final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
  if (path.endsWith('.m3u8') || path.contains('.m3u8/')) {
    return CastMediaType.hls;
  }
  if (path.endsWith('.mp4') || path.endsWith('.m4v')) return CastMediaType.mp4;
  if (path.endsWith('.mkv')) return CastMediaType.mkv;
  if (path.endsWith('.ts')) return CastMediaType.mpegTs;
  // A playlist hidden in the query string, e.g. `/proxy?url=...index.m3u8`.
  if (url.toLowerCase().contains('.m3u8')) return CastMediaType.hls;
  return null;
}

/// The Default Media Receiver shows WebVTT only, so SRT is converted by
/// dart_cast and styled formats like ASS can't be sent.
List<CastSubtitle> _castSubtitles(List<vid.Track>? tracks) {
  final result = <CastSubtitle>[];
  for (final track in tracks ?? const <vid.Track>[]) {
    final file = track.file;
    if (file == null || file.isEmpty) continue;
    final path = (Uri.tryParse(file)?.path ?? file).toLowerCase();
    final String format;
    if (path.endsWith('.vtt')) {
      format = 'vtt';
    } else if (path.endsWith('.srt')) {
      format = 'srt';
    } else {
      continue;
    }
    final label = (track.label == null || track.label!.isEmpty)
        ? 'Subtitles ${result.length + 1}'
        : track.label!;
    result.add(
      CastSubtitle(url: file, label: label, language: 'und', format: format),
    );
  }
  return result;
}

CastSubtitle? _defaultSubtitle(List<CastSubtitle> subtitles) {
  for (final subtitle in subtitles) {
    if (subtitle.label.toLowerCase().contains('english')) return subtitle;
  }
  return null;
}

