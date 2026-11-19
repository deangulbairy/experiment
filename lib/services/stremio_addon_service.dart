import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mangayomi/services/secure_storage.dart';

const stremioCinemetaManifest =
    'https://v3-cinemeta.strem.io/manifest.json';
const _stremioManifestUrlsKey = 'stremioAddonManifestUrls';

enum StremioMediaType {
  movie('movie', 'Movies'),
  series('series', 'Series');

  const StremioMediaType(this.protocolName, this.label);
  final String protocolName;
  final String label;
}

class StremioAddon {
  const StremioAddon({required this.manifestUrl, required this.manifest});

  final String manifestUrl;
  final Map<String, dynamic> manifest;

  String get name => manifest['name']?.toString() ?? manifestUrl;
  String get id => manifest['id']?.toString() ?? manifestUrl;

  bool supportsResource(String name, StremioMediaType? type) {
    final resources = manifest['resources'];
    if (resources is! List) return false;
    for (final resource in resources) {
      if (resource == name) return _supportsType(type);
      if (resource is Map && resource['name'] == name) {
        final resourceTypes = resource['types'];
        if (resourceTypes is List &&
            type != null &&
            !resourceTypes.map((e) => e.toString()).contains(type.protocolName)) {
          continue;
        }
        return _supportsType(type);
      }
    }
    return false;
  }

  bool _supportsType(StremioMediaType? type) {
    if (type == null) return true;
    final types = manifest['types'];
    if (types is! List) return true;
    return types.map((e) => e.toString()).contains(type.protocolName);
  }

  bool supportsId(String mediaId, {String? resourceName}) {
    final resources = manifest['resources'];
    final resource = resources is List
        ? resources.whereType<Map>().where((entry) => entry['name'] == resourceName).firstOrNull
        : null;
    final prefixes = resource?['idPrefixes'] ?? manifest['idPrefixes'];
    if (prefixes is! List || prefixes.isEmpty) return true;
    return prefixes.any((prefix) => mediaId.startsWith(prefix.toString()));
  }

  Uri _resourceUri(String path) {
    final manifestUri = Uri.parse(manifestUrl);
    final slash = manifestUri.path.lastIndexOf('/');
    final basePath = manifestUri.path.substring(0, slash + 1);
    final base = manifestUri.replace(path: basePath, fragment: null);
    final endpoint = base.resolve(path);
    // Configurable add-ons can carry their token in the manifest URL query.
    // Keep it on resource requests as well as the manifest request.
    return manifestUri.hasQuery
        ? endpoint.replace(query: manifestUri.query)
        : endpoint;
  }

  Future<Map<String, dynamic>> getResource(
    String resource,
    StremioMediaType type,
    String id, {
    Map<String, String> extras = const {},
  }) async {
    // Stremio episode IDs use colons (for example tt123:1:2). Keep those as
    // literal path characters because some add-ons route on this form and do
    // not match a percent-encoded %3A path.
    final encodedId = Uri.encodeComponent(id).replaceAll('%3A', ':');
    final extraPath = extras.entries
        .map(
          (entry) =>
              '${Uri.encodeComponent(entry.key)}=${Uri.encodeComponent(entry.value)}',
        )
        .join('&');
    final path =
        '$resource/${type.protocolName}/$encodedId${extraPath.isEmpty ? '' : '/$extraPath'}.json';
    final response = await http
        .get(_resourceUri(path))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StremioAddonException(
        '$name returned HTTP ${response.statusCode} for $resource.',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw StremioAddonException('$name returned an invalid $resource response.');
    }
    return decoded.cast<String, dynamic>();
  }
}

class StremioCatalog {
  const StremioCatalog({
    required this.addon,
    required this.id,
    required this.type,
    required this.name,
    required this.definition,
  });

  final StremioAddon addon;
  final String id;
  final StremioMediaType type;
  final String name;
  final Map<String, dynamic> definition;

  List<Map<String, dynamic>> get extras =>
      (definition['extra'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();

  List<Map<String, dynamic>> get optionExtras => extras
      .where((extra) => extra['options'] is List && (extra['options'] as List).isNotEmpty)
      .toList();

  Map<String, String> get requiredDefaults {
    final required = definition['extraRequired'];
    if (required is! List) return const {};
    final result = <String, String>{};
    for (final entry in required) {
      final name = entry is Map ? entry['name']?.toString() : entry?.toString();
      if (name == null || name == 'search') continue;
      if (name == 'skip') {
        result[name] = '0';
        continue;
      }
      final definition = extras.where((e) => e['name'] == name).firstOrNull;
      final options = definition?['options'];
      if (options is List && options.isNotEmpty) {
        result[name] = options.first.toString();
      }
    }
    return result;
  }

  bool get supportsSearch => extras.any((e) => e['name'] == 'search') ||
      (definition['extraSupported'] as List? ?? const []).contains('search');

  String get key => '${addon.manifestUrl}::$id::$name';
}

class StremioMeta {
  const StremioMeta(this.data);

  final Map<String, dynamic> data;

  String get id => data['id']?.toString() ?? '';
  String get name => data['name']?.toString() ?? 'Untitled';
  String get description => data['description']?.toString() ?? '';
  String get poster => data['poster']?.toString() ?? '';
  String get background => data['background']?.toString() ?? '';
  String get releaseInfo => data['releaseInfo']?.toString() ?? '';
  String get runtime => data['runtime']?.toString() ?? '';
  String get type => data['type']?.toString() ?? '';
  String? get tmdbId {
    final ids = data['ids'];
    final candidates = <dynamic>[
      data['tmdbId'],
      data['tmdb_id'],
      data['tmdb'],
      if (ids is Map) ids['tmdb'],
      id,
    ];
    for (final candidate in candidates) {
      final value = candidate?.toString().trim();
      if (value == null || value.isEmpty) continue;
      final match = RegExp(
        r'^(?:tmdb:)?(?:movie:|series:|tv:)?(\d+)$',
        caseSensitive: false,
      ).firstMatch(value);
      if (match != null) return match.group(1);
    }
    return null;
  }
  List<String> get genres => (data['genres'] as List? ?? const [])
      .map((e) => e.toString())
      .toList();
  List<StremioEpisode> get episodes =>
      (data['videos'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => StremioEpisode(e.cast<String, dynamic>()))
          .toList();
}

class StremioEpisode {
  const StremioEpisode(this.data);

  final Map<String, dynamic> data;

  String get id => data['id']?.toString() ?? '';
  String get title => data['title']?.toString() ?? data['name']?.toString() ?? '';
  int get season => int.tryParse(data['season']?.toString() ?? '') ?? 0;
  int get episode => int.tryParse(data['episode']?.toString() ?? '') ?? 0;
  String get label =>
      'S${season.toString().padLeft(2, '0')} E${episode.toString().padLeft(2, '0')}${title.isEmpty ? '' : ' · $title'}';
}

class StremioStream {
  const StremioStream({
    required this.addonName,
    required this.name,
    required this.title,
    this.url,
    this.infoHash,
    this.fileIndex,
    this.trackers = const [],
    this.headers,
  });

  final String addonName;
  final String name;
  final String title;
  final String? url;
  final String? infoHash;
  final int? fileIndex;
  final List<String> trackers;
  final Map<String, String>? headers;

  bool get isTorrent => infoHash?.isNotEmpty == true || url?.startsWith('magnet:') == true;

  String get magnetUri {
    final directMagnet = url;
    final hash = infoHash;
    if ((directMagnet == null || !directMagnet.startsWith('magnet:')) &&
        (hash == null || hash.isEmpty)) {
      return '';
    }
    var magnet = directMagnet != null && directMagnet.startsWith('magnet:')
        ? directMagnet
        : 'magnet:?xt=urn:btih:${Uri.encodeComponent(hash!)}';
    final existingTrackers = {
      ...(Uri.tryParse(magnet)?.queryParametersAll['tr'] ?? const <String>[]),
    };
    for (final tracker in trackers) {
      if (existingTrackers.add(tracker)) {
        magnet += '${magnet.contains('?') ? '&' : '?'}tr=${Uri.encodeComponent(tracker)}';
      }
    }
    return magnet;
  }

  String get displayTitle => title.isNotEmpty ? title : name;

  Map<String, dynamic> toStorageJson() => {
    'addonName': addonName,
    'name': name,
    'title': title,
    'url': url,
    'infoHash': infoHash,
    'fileIndex': fileIndex,
    'trackers': trackers,
    'headers': headers,
  };

  factory StremioStream.fromStorageJson(Map<String, dynamic> json) {
    final rawHeaders = json['headers'];
    return StremioStream(
      addonName: json['addonName']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      url: json['url']?.toString(),
      infoHash: json['infoHash']?.toString(),
      fileIndex: int.tryParse(json['fileIndex']?.toString() ?? ''),
      trackers: (json['trackers'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(),
      headers: rawHeaders is Map
          ? rawHeaders.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            )
          : null,
    );
  }

  factory StremioStream.fromJson(
    Map<String, dynamic> json, {
    required String addonName,
  }) {
    final hints = json['behaviorHints'];
    final proxyHeaders = hints is Map ? hints['proxyHeaders'] : null;
    final requestHeaders = proxyHeaders is Map ? proxyHeaders['request'] : null;
    final rawHeaders = json['headers'];
    final headers = requestHeaders is Map
        ? requestHeaders.map((key, value) => MapEntry(key.toString(), value.toString()))
        : rawHeaders is Map
        ? rawHeaders.map((key, value) => MapEntry(key.toString(), value.toString()))
        : null;
    final sources = (json['sources'] as List? ?? const [])
        .whereType<String>()
        .map((e) => e.trim().replaceFirst(RegExp(r'^tracker:'), ''))
        .where(
          (e) =>
              e.startsWith('http://') ||
              e.startsWith('https://') ||
              e.startsWith('udp://'),
        )
        .toList();
    final infoHash = json['infoHash']?.toString();
    final rawUrl = json['url'];
    final urlData = rawUrl is Map ? rawUrl : null;
    final url = urlData?['url']?.toString() ?? rawUrl?.toString();
    final streamHeaders = headers ?? (urlData?['headers'] is Map
        ? (urlData!['headers'] as Map).map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          )
        : null);
    final quality = json['quality']?.toString();
    final size = json['size']?.toString();
    final language = json['language']?.toString();
    final details = [
      if (quality != null && quality.isNotEmpty) quality,
      if (size != null && size.isNotEmpty) size,
      if (language != null && language.isNotEmpty) language,
    ].join(' · ');
    final title = json['title']?.toString() ?? json['description']?.toString();
    return StremioStream(
      addonName: addonName,
      name: json['name']?.toString() ?? json['provider']?.toString() ?? '',
      title: [if (title != null && title.isNotEmpty) title, if (details.isNotEmpty) details]
          .join(' · '),
      url: url,
      infoHash: infoHash,
      fileIndex: int.tryParse(json['fileIdx']?.toString() ?? ''),
      trackers: sources,
      headers: streamHeaders,
    );
  }
}

class StremioAddonException implements Exception {
  const StremioAddonException(this.message);
  final String message;

  @override
  String toString() => message;
}

class StremioAddonService {
  Future<List<String>> installedManifestUrls() async {
    final stored = await secureStorage.read(key: _stremioManifestUrlsKey);
    final urls = stored == null
        ? <String>[]
        : (jsonDecode(stored) as List).map((e) => e.toString()).toList();
    return [
      stremioCinemetaManifest,
      ...urls.where((url) => url != stremioCinemetaManifest),
    ];
  }

  Future<void> addManifestUrl(String value) async {
    final url = normalizeManifestUrl(value);
    final manifest = await fetchManifest(url);
    if (manifest['id'] == null || manifest['name'] == null) {
      throw const StremioAddonException('The URL did not return a Stremio manifest.');
    }
    final urls = await installedManifestUrls();
    if (!urls.contains(url)) urls.add(url);
    await _saveUserUrls(urls);
  }

  Future<void> removeManifestUrl(String url) async {
    if (url == stremioCinemetaManifest) return;
    final urls = await installedManifestUrls();
    urls.remove(url);
    await _saveUserUrls(urls);
  }

  Future<void> _saveUserUrls(List<String> urls) async {
    await secureStorage.write(
      key: _stremioManifestUrlsKey,
      value: jsonEncode(urls.where((url) => url != stremioCinemetaManifest).toList()),
    );
  }

  String normalizeManifestUrl(String value) {
    var input = value.trim();
    input = input.replaceFirst(
      RegExp(r'^(?:stremio|nuvio)://', caseSensitive: false),
      'https://',
    );
    final uri = Uri.tryParse(input);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const StremioAddonException('Enter a valid HTTP or HTTPS manifest URL.');
    }
    final path = uri.path.isEmpty || uri.path.endsWith('/')
        ? '${uri.path}manifest.json'
        : uri.path.toLowerCase().endsWith('.json')
        ? uri.path
        : '${uri.path}/manifest.json';
    return uri.replace(path: path).toString();
  }

  Future<Map<String, dynamic>> fetchManifest(String url) async {
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StremioAddonException('Manifest request failed with HTTP ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const StremioAddonException('The URL returned invalid manifest JSON.');
    }
    return decoded.cast<String, dynamic>();
  }

  /// Resolve add-on redirect links before handing them to libmpv. Some
  /// add-ons return short-lived worker URLs that libmpv cannot open directly,
  /// even though a normal HTTP client follows their redirects successfully.
  /// A one-byte range keeps the probe from downloading the media body.
  Future<String> resolveStreamUrl(
    String url, {
    Map<String, String>? headers,
  }) async {
    final original = Uri.tryParse(url);
    if (original == null || (original.scheme != 'http' && original.scheme != 'https')) {
      return url;
    }
    if (!original.pathSegments.any(
      (segment) =>
          segment.toLowerCase() == 'redirect' ||
          segment.toLowerCase() == 'resolve',
    )) {
      return url;
    }

    final client = http.Client();
    var current = original;
    final requestHeaders = <String, String>{
      ...?headers,
      'Range': 'bytes=0-0',
    };
    try {
      for (var redirect = 0; redirect < 6; redirect++) {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers.addAll(requestHeaders);
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 12));
        final location = response.headers['location'];
        await response.stream.listen((_) {}).cancel();

        final isRedirect = response.statusCode == 301 ||
            response.statusCode == 302 ||
            response.statusCode == 303 ||
            response.statusCode == 307 ||
            response.statusCode == 308;
        if (!isRedirect || location == null) return current.toString();

        final next = current.resolve(location);
        if (current.origin != next.origin) {
          requestHeaders.removeWhere(
            (key, _) => const {
              'authorization',
              'cookie',
              'proxy-authorization',
              'host',
            }.contains(key.toLowerCase()),
          );
        }
        current = next;
      }
      return current.toString();
    } catch (_) {
      // Keep the original URL as a fallback for hosts that reject range
      // probes; libmpv can still try its native HTTP handling.
      return url;
    } finally {
      client.close();
    }
  }

  Future<List<StremioAddon>> loadAddons({
    void Function(String manifestUrl, Object error)? onAddonError,
  }) async {
    final urls = await installedManifestUrls();
    final results = await Future.wait(urls.map((url) async {
      try {
        return StremioAddon(manifestUrl: url, manifest: await fetchManifest(url));
      } catch (error) {
        if (url == stremioCinemetaManifest) rethrow;
        onAddonError?.call(url, error);
        return null;
      }
    }));
    return results.whereType<StremioAddon>().toList();
  }

  List<StremioCatalog> catalogs(
    List<StremioAddon> addons,
    StremioMediaType type,
  ) {
    final catalogs = <StremioCatalog>[];
    for (final addon in addons) {
      if (!addon.supportsResource('catalog', type)) continue;
      final definitions = addon.manifest['catalogs'];
      if (definitions is! List) continue;
      for (final value in definitions.whereType<Map>()) {
        final definition = value.cast<String, dynamic>();
        if (definition['type'] != type.protocolName || definition['id'] == null) {
          continue;
        }
        final catalog = StremioCatalog(
          addon: addon,
          id: definition['id'].toString(),
          type: type,
          name: definition['name']?.toString() ?? definition['id'].toString(),
          definition: definition,
        );
        final unsupportedRequired = (definition['extraRequired'] as List? ?? const [])
            .map((entry) => entry is Map ? entry['name']?.toString() : entry.toString())
            .whereType<String>()
            .where((name) =>
                name != 'search' &&
                name != 'skip' &&
                !catalog.requiredDefaults.containsKey(name));
        if (unsupportedRequired.isEmpty) catalogs.add(catalog);
      }
    }
    catalogs.sort((a, b) {
      final addonCompare = a.addon.name.compareTo(b.addon.name);
      return addonCompare != 0 ? addonCompare : a.name.compareTo(b.name);
    });
    return catalogs;
  }

  Future<List<StremioMeta>> loadCatalog(
    StremioCatalog catalog, {
    String search = '',
    String? filterName,
    String? filterValue,
  }) async {
    final extras = <String, String>{...catalog.requiredDefaults};
    if (filterName != null && filterValue != null) {
      extras[filterName] = filterValue;
    }
    if (search.trim().isNotEmpty && catalog.supportsSearch) {
      extras['search'] = search.trim();
    }
    final response = await catalog.addon.getResource(
      'catalog',
      catalog.type,
      catalog.id,
      extras: extras,
    );
    return (response['metas'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => StremioMeta(e.cast<String, dynamic>()))
        .toList();
  }

  Future<StremioMeta> loadMeta(
    List<StremioAddon> addons,
    StremioMediaType type,
    String id,
    StremioMeta fallback,
  ) async {
    final providers = addons.where(
      (addon) =>
          addon.supportsResource('meta', type) &&
          addon.supportsId(id, resourceName: 'meta'),
    );
    StremioMeta? metaWithoutEpisodes;
    for (final addon in providers) {
      try {
        final response = await addon.getResource('meta', type, id);
        final meta = response['meta'];
        if (meta is Map && meta['id'] != null) {
          final candidate = StremioMeta(meta.cast<String, dynamic>());
          if (type != StremioMediaType.series || candidate.episodes.isNotEmpty) {
            return candidate;
          }
          metaWithoutEpisodes ??= candidate;
        }
      } catch (_) {}
    }
    return metaWithoutEpisodes ?? fallback;
  }

  Future<List<StremioStream>> loadStreams(
    List<StremioAddon> addons,
    StremioMediaType type,
    String id, {
    void Function(String addonName, Object error)? onAddonError,
  }) async {
    final providers = addons.where(
      (addon) =>
          addon.supportsResource('stream', type) &&
          addon.supportsId(id, resourceName: 'stream'),
    );
    final results = await Future.wait(providers.map((addon) async {
      try {
        final response = await addon.getResource('stream', type, id);
        return (response['streams'] as List? ?? const [])
            .whereType<Map>()
            .map((entry) => StremioStream.fromJson(
                  entry.cast<String, dynamic>(),
                  addonName: addon.name,
                ))
            .where((stream) =>
                (stream.url != null && stream.url!.isNotEmpty) ||
                (stream.infoHash != null && stream.infoHash!.isNotEmpty))
            .toList();
      } catch (error) {
        onAddonError?.call(addon.name, error);
        return <StremioStream>[];
      }
    }));
    return results.expand((streams) => streams).toList();
  }
}
