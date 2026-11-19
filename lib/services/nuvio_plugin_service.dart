import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:mangayomi/eval/lnreader/http.dart' as ln_http;
import 'package:mangayomi/eval/lnreader/js_cheerio.dart';
import 'package:mangayomi/eval/lnreader/js_libs.dart';
import 'package:mangayomi/eval/lnreader/js_polyfills.dart';
import 'package:mangayomi/eval/lnreader/service.dart';
import 'package:mangayomi/eval/model/m_bridge.dart';
import 'package:mangayomi/services/stremio_addon_service.dart';
import 'package:mangayomi/services/secure_storage.dart';

const _nuvioRepositoryUrlsKey = 'nuvioPluginRepositoryUrls';
const _nuvioTmdbApiKey = 'nuvioPluginTmdbApiKey';
const _nuvioScraperSettingsKey = 'nuvioPluginScraperSettings';
const _maxManifestBytes = 256 * 1024;
const _maxScraperBytes = 5 * 1024 * 1024;

class NuvioPluginRepository {
  const NuvioPluginRepository({
    required this.manifestUrl,
    required this.name,
    required this.version,
    required this.scrapers,
    this.description,
    this.error,
  });

  final String manifestUrl;
  final String name;
  final String version;
  final List<NuvioPluginScraper> scrapers;
  int get scraperCount => scrapers.length;
  final String? description;
  final String? error;
}

class NuvioPluginScraper {
  const NuvioPluginScraper({
    required this.id,
    required this.name,
    required this.filename,
    required this.supportedTypes,
    required this.hasSettings,
    required this.enabled,
  });

  final String id;
  final String name;
  final String filename;
  final List<String> supportedTypes;
  final bool hasSettings;
  final bool enabled;
}

class NuvioPluginException implements Exception {
  const NuvioPluginException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Loads native Nuvio JavaScript scraper repositories and adapts their
/// getStreams results to the app's shared Stremio stream model.
class NuvioPluginService {
  NuvioPluginService._();

  static final NuvioPluginService instance = NuvioPluginService._();

  final Map<String, String> _tmdbIdCache = {};

  Future<List<String>> installedRepositoryUrls() async {
    final value = await secureStorage.read(key: _nuvioRepositoryUrlsKey);
    if (value == null || value.isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) return const [];
      return decoded.map((entry) => entry.toString()).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> addRepository(String value) async {
    final url = normalizeRepositoryUrl(value);
    final manifest = await _fetchManifest(url);
    final scrapers = _scrapersFrom(manifest);
    if (manifest['name']?.toString().trim().isEmpty != false ||
        manifest['version']?.toString().trim().isEmpty != false ||
        scrapers.isEmpty) {
      throw const NuvioPluginException(
        'The URL did not return a Nuvio plugin manifest with a name, version, and scrapers.',
      );
    }

    final urls = await installedRepositoryUrls();
    if (!urls.contains(url)) {
      urls.add(url);
      await _saveRepositoryUrls(urls);
    }
  }

  Future<void> removeRepository(String url) async {
    final urls = await installedRepositoryUrls();
    urls.remove(url);
    await _saveRepositoryUrls(urls);
  }

  Future<void> _saveRepositoryUrls(List<String> urls) => secureStorage.write(
    key: _nuvioRepositoryUrlsKey,
    value: jsonEncode(urls),
  );

  String normalizeRepositoryUrl(String value) {
    var input = value.trim().replaceFirst(
      RegExp(r'^(?:nuvio|stremio)://', caseSensitive: false),
      'https://',
    );
    final uri = Uri.tryParse(input);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const NuvioPluginException(
        'Enter an HTTP or HTTPS Nuvio plugin manifest URL.',
      );
    }
    if (uri.path.toLowerCase().endsWith('.json')) return uri.toString();
    final path = '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/manifest.json';
    return uri.replace(path: path).toString();
  }

  Future<List<NuvioPluginRepository>> loadRepositories() async {
    final urls = await installedRepositoryUrls();
    return Future.wait(urls.map((url) async {
      try {
        final manifest = await _fetchManifest(url);
        return NuvioPluginRepository(
          manifestUrl: url,
          name: manifest['name']?.toString() ?? Uri.parse(url).host,
          version: manifest['version']?.toString() ?? '',
          scrapers: _scrapersFrom(manifest).map(_toScraper).toList(),
          description: manifest['description']?.toString(),
        );
      } catch (error) {
        return NuvioPluginRepository(
          manifestUrl: url,
          name: Uri.tryParse(url)?.host ?? url,
          version: '',
          scrapers: const [],
          error: error.toString(),
        );
      }
    }));
  }

  Future<String?> tmdbApiKey() => secureStorage.read(key: _nuvioTmdbApiKey);

  Future<void> setTmdbApiKey(String value) async {
    final key = value.trim();
    if (key.isEmpty) {
      await secureStorage.delete(key: _nuvioTmdbApiKey);
    } else {
      await secureStorage.write(key: _nuvioTmdbApiKey, value: key);
    }
    _tmdbIdCache.clear();
  }

  String scraperSettingsStorageId(String manifestUrl, String scraperId) =>
      '$manifestUrl::$scraperId';

  Future<Map<String, dynamic>> scraperSettings(String storageId) async {
    final value = await secureStorage.read(key: _nuvioScraperSettingsKey);
    if (value == null || value.isEmpty) return const {};
    try {
      final decoded = jsonDecode(value);
      final settings = decoded is Map ? decoded[storageId] : null;
      return settings is Map ? settings.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  Future<void> saveScraperSettings(
    String storageId,
    Map<String, dynamic> settings,
  ) async {
    final value = await secureStorage.read(key: _nuvioScraperSettingsKey);
    Map<String, dynamic> allSettings = {};
    if (value != null && value.isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) allSettings = decoded.cast<String, dynamic>();
      } catch (_) {}
    }
    allSettings[storageId] = settings;
    await secureStorage.write(
      key: _nuvioScraperSettingsKey,
      value: jsonEncode(allSettings),
    );
  }

  Future<List<Map<String, dynamic>>> loadSettingsLayout(
    String manifestUrl,
    NuvioPluginScraper scraper,
  ) async {
    if (!scraper.hasSettings) return const [];
    final codeUrl = _resolveScraperUrl(manifestUrl, scraper.filename);
    final response = await http
        .get(codeUrl)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NuvioPluginException(
        'Could not load ${scraper.name} settings (HTTP ${response.statusCode}).',
      );
    }
    if (response.bodyBytes.length > _maxScraperBytes) {
      throw const NuvioPluginException('The scraper file is too large.');
    }

    final runtime = getJavascriptRuntime();
    final cheerio = JsCheerio(runtime)..init();
    try {
      JsPolyfills(runtime).init();
      JsLibs(runtime).init();
      runtime.evaluate('''
globalThis.global = globalThis;
globalThis.window = globalThis;
globalThis.self = globalThis;
globalThis.SCRAPER_ID = ${jsonEncode(scraper.id)};
globalThis.SCRAPER_SETTINGS = {};
var module = { exports: {} };
var exports = module.exports;
var require = function(name) {
  if (name === 'cheerio' || name === 'cheerio-without-node-native') return { load: load };
  if (name === 'url') return { URL: URL, URLSearchParams: URLSearchParams };
  throw new Error('Unsupported Nuvio plugin module: ' + name);
};
''');
      final loadResult = runtime.evaluate('''
(function() {
${response.body}
})();
''');
      if (loadResult.isError) {
        throw NuvioPluginException(loadResult.stringResult);
      }
      final evaluated = await runtime.evaluateAsync('''
(async function() {
  const fn = module.exports && module.exports.onSettings || globalThis.onSettings;
  if (typeof fn !== 'function') return '[]';
  return JSON.stringify((await fn()) || []);
})()
''');
      if (evaluated.isError) {
        throw NuvioPluginException(evaluated.stringResult);
      }
      final resolved = await runtime
          .handlePromise(evaluated)
          .timeout(const Duration(seconds: 15));
      if (resolved.isError) {
        throw NuvioPluginException(resolved.stringResult);
      }
      final decoded = jsonDecode(resolved.stringResult);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((entry) => entry.cast<String, dynamic>())
          .toList();
    } finally {
      cheerio.dispose();
    }
  }

  Future<String?> resolveTmdbId(
    StremioMeta meta,
    StremioMediaType mediaType,
  ) async {
    final directId = meta.tmdbId;
    if (directId != null) return directId;

    final imdbId = meta.id.split(':').first;
    if (!RegExp(r'^tt\d+$').hasMatch(imdbId)) return null;
    final apiKey = (await tmdbApiKey())?.trim();
    if (apiKey == null || apiKey.isEmpty) return null;
    final cacheKey = '$imdbId:${mediaType.protocolName}';
    final cached = _tmdbIdCache[cacheKey];
    if (cached != null) return cached;

    final uri = Uri.https('api.themoviedb.org', '/3/find/$imdbId', {
      'external_source': 'imdb_id',
      'api_key': apiKey,
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final data = jsonDecode(response.body);
    if (data is! Map) return null;
    final bucket = mediaType == StremioMediaType.movie
        ? 'movie_results'
        : 'tv_results';
    final results = data[bucket];
    if (results is! List || results.isEmpty || results.first is! Map) {
      return null;
    }
    final tmdbId = results.first['id']?.toString();
    if (tmdbId == null || !RegExp(r'^\d+$').hasMatch(tmdbId)) return null;
    _tmdbIdCache[cacheKey] = tmdbId;
    return tmdbId;
  }

  Future<List<StremioStream>> loadStreams({
    required String tmdbId,
    required StremioMediaType mediaType,
    int? season,
    int? episode,
  }) async {
    if (tmdbId.isEmpty) return const [];
    final urls = await installedRepositoryUrls();
    if (urls.isEmpty) return const [];

    final scraperJobs =
        <({String name, String code, String id, Map<String, dynamic> settings})>[];
    for (final url in urls) {
      try {
        final manifest = await _fetchManifest(url);
        final repoName = manifest['name']?.toString() ?? Uri.parse(url).host;
        for (final scraper in _scrapersFrom(manifest)) {
          if (scraper['enabled'] == false) continue;
          if (!_supportsPlatform(scraper)) continue;
          if (!_supportsMediaType(scraper, mediaType)) continue;
          final parsedScraper = _toScraper(scraper);
          if (parsedScraper.filename.isEmpty) continue;
          try {
            final codeUrl = _resolveScraperUrl(url, parsedScraper.filename);
            final response = await http
                .get(codeUrl)
                .timeout(const Duration(seconds: 20));
            if (response.statusCode < 200 || response.statusCode >= 300) {
              continue;
            }
            if (response.bodyBytes.length > _maxScraperBytes) continue;
            scraperJobs.add((
              name: '${parsedScraper.name} · $repoName',
              code: response.body,
              id: parsedScraper.id,
              settings: await scraperSettings(
                scraperSettingsStorageId(url, parsedScraper.id),
              ),
            ));
          } catch (_) {}
        }
      } catch (_) {}
    }

    final streams = <StremioStream>[];
    final apiKey = await tmdbApiKey() ?? '';
    const batchSize = 4;
    for (var index = 0; index < scraperJobs.length; index += batchSize) {
      final batch = scraperJobs.skip(index).take(batchSize);
      final results = await Future.wait(batch.map((job) async {
        try {
          final entries = await _executeScraper(
            job.code,
            scraperId: job.id,
            tmdbId: tmdbId,
            mediaType: mediaType == StremioMediaType.movie ? 'movie' : 'tv',
            settings: job.settings,
            season: season,
            episode: episode,
            apiKey: apiKey,
          );
          return entries
              .map((entry) => StremioStream.fromJson(
                    entry,
                    addonName: 'Nuvio · ${job.name}',
                  ))
              .where((stream) =>
                  (stream.url?.isNotEmpty ?? false) ||
                  (stream.infoHash?.isNotEmpty ?? false))
              .toList();
        } catch (_) {
          return <StremioStream>[];
        }
      }));
      streams.addAll(results.expand((result) => result));
    }
    return streams;
  }

  Future<List<Map<String, dynamic>>> _executeScraper(
    String code, {
    required String scraperId,
    required String tmdbId,
    required String mediaType,
    required String apiKey,
    required Map<String, dynamic> settings,
    int? season,
    int? episode,
  }) async {
    final runtime = getJavascriptRuntime();
    final cheerio = JsCheerio(runtime)..init();
    try {
      JsPolyfills(runtime).init();
      ln_http.JsHttpClient(runtime).init();
      JsLibs(runtime).init();
      runtime.onMessage('nuvio_sleep', (dynamic args) async {
        final requested = args is List && args.isNotEmpty
            ? num.tryParse(args.first.toString())?.toInt() ?? 0
            : 0;
        await Future<void>.delayed(
          Duration(milliseconds: requested.clamp(0, 60000).toInt()),
        );
        return null;
      });
      runtime.onMessage('nuvio_cryptojs_aes_decrypt', (dynamic args) {
        return MBridge.decryptAESCryptoJS(
          args[0]?.toString() ?? '',
          args[1]?.toString() ?? '',
        );
      });
      runtime.onMessage('nuvio_cryptojs_aes_encrypt', (dynamic args) {
        return MBridge.encryptAESCryptoJS(
          args[0]?.toString() ?? '',
          args[1]?.toString() ?? '',
        );
      });
      runtime.onMessage('nuvio_cryptojs_hash', (dynamic args) {
        final algorithm = args[0]?.toString().toLowerCase() ?? '';
        final value = utf8.encode(args[1]?.toString() ?? '');
        return switch (algorithm) {
          'sha1' => crypto.sha1.convert(value).toString(),
          'sha256' => crypto.sha256.convert(value).toString(),
          'md5' => crypto.md5.convert(value).toString(),
          _ => '',
        };
      });
      final settingsJson = jsonEncode(settings);
      final id = jsonEncode(scraperId);
      final tmdbKeySetup = apiKey.isEmpty
          ? ''
          : 'globalThis.TMDB_API_KEY = ${jsonEncode(apiKey)};';
      final moduleSetup = runtime.evaluate('''
globalThis.global = globalThis;
globalThis.window = globalThis;
globalThis.self = globalThis;
globalThis.SCRAPER_ID = $id;
globalThis.SCRAPER_SETTINGS = $settingsJson;
$tmdbKeySetup
globalThis.__nuvioTimerId = 0;
globalThis.__nuvioTimers = Object.create(null);
globalThis.__nuvioSleep = function(ms) {
  return sendMessage('nuvio_sleep', JSON.stringify([ms]));
};
globalThis.setTimeout = function(callback, delay) {
  const id = ++globalThis.__nuvioTimerId;
  const args = Array.prototype.slice.call(arguments, 2);
  globalThis.__nuvioTimers[id] = true;
  globalThis.__nuvioSleep(delay).then(function() {
    if (!globalThis.__nuvioTimers[id]) return;
    delete globalThis.__nuvioTimers[id];
    callback.apply(globalThis, args);
  });
  return id;
};
globalThis.clearTimeout = function(id) { delete globalThis.__nuvioTimers[id]; };
globalThis.setInterval = function(callback, delay) {
  const id = ++globalThis.__nuvioTimerId;
  const args = Array.prototype.slice.call(arguments, 2);
  const interval = Math.max(1, Math.min(Number(delay) || 0, 60000));
  globalThis.__nuvioTimers[id] = true;
  const tick = function() {
    globalThis.__nuvioSleep(interval).then(function() {
      if (!globalThis.__nuvioTimers[id]) return;
      callback.apply(globalThis, args);
      if (globalThis.__nuvioTimers[id]) tick();
    });
  };
  tick();
  return id;
};
globalThis.clearInterval = globalThis.clearTimeout;
globalThis.__nuvioClearTimers = function() {
  globalThis.__nuvioTimers = Object.create(null);
};
function __nuvioWordArray(value) {
  return {
    _value: value,
    toString: function(encoder) {
      if (encoder && typeof encoder.stringify === 'function') {
        return encoder.stringify(this);
      }
      return String(this._value);
    }
  };
}
function __nuvioUtf8(value) {
  try { return decodeURIComponent(escape(String(value))); }
  catch (_) { return String(value); }
}
function __nuvioBase64(value) {
  try { return btoa(unescape(encodeURIComponent(String(value)))); }
  catch (_) { return ''; }
}
globalThis.CryptoJS = {
  enc: {
    Utf8: {
      stringify: function(value) { return __nuvioUtf8(value._value); },
      parse: function(value) { return __nuvioWordArray(String(value)); }
    },
    Hex: {
      stringify: function(value) {
        const text = String(value._value);
        let hex = '';
        for (let i = 0; i < text.length; i++) {
          hex += text.charCodeAt(i).toString(16).padStart(2, '0');
        }
        return hex;
      },
      parse: function(value) { return __nuvioWordArray(String(value)); }
    },
    Base64: {
      stringify: function(value) { return __nuvioBase64(value._value); },
      parse: function(value) {
        try { return __nuvioWordArray(__nuvioUtf8(atob(String(value)))); }
        catch (_) { return __nuvioWordArray(''); }
      }
    }
  },
  AES: {
    decrypt: function(ciphertext, passphrase) {
      const result = sendMessage(
        'nuvio_cryptojs_aes_decrypt',
        JSON.stringify([String(ciphertext), String(passphrase)])
      );
      return __nuvioWordArray(result);
    },
    encrypt: function(plaintext, passphrase) {
      const result = sendMessage(
        'nuvio_cryptojs_aes_encrypt',
        JSON.stringify([String(plaintext), String(passphrase)])
      );
      return __nuvioWordArray(result);
    }
  },
  SHA1: function(value) {
    return __nuvioWordArray(sendMessage('nuvio_cryptojs_hash', JSON.stringify(['sha1', String(value)])));
  },
  SHA256: function(value) {
    return __nuvioWordArray(sendMessage('nuvio_cryptojs_hash', JSON.stringify(['sha256', String(value)])));
  },
  MD5: function(value) {
    return __nuvioWordArray(sendMessage('nuvio_cryptojs_hash', JSON.stringify(['md5', String(value)])));
  }
};
globalThis.fetch = async function(url, options) {
  const response = await fetchApi(String(url), options || {});
  const headers = response.headers || {};
  return {
    ok: response.ok,
    status: response.status,
    statusText: response.statusText,
    url: response.url || String(url),
    headers: {
      get: function(name) {
        const key = String(name).toLowerCase();
        for (const header in headers) {
          if (header.toLowerCase() === key) return headers[header];
        }
        return null;
      }
    },
    text: function() { return response.text(); },
    json: function() { return response.json(); },
    arrayBuffer: async function() {
      const text = await response.text();
      const bytes = new Uint8Array(text.length);
      for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 255;
      return bytes.buffer;
    }
  };
};
var module = { exports: {} };
var exports = module.exports;
var require = function(name) {
  if (name === 'cheerio' || name === 'cheerio-without-node-native') {
    return { load: load };
  }
  if (name === 'url') return { URL: URL, URLSearchParams: URLSearchParams };
  if (name === 'crypto-js') return globalThis.CryptoJS;
  throw new Error('Unsupported Nuvio plugin module: ' + name);
};
''');
      if (moduleSetup.isError) {
        throw NuvioPluginException(moduleSetup.stringResult);
      }
      final loadResult = runtime.evaluate('''
(function() {
$code
})();
''');
      if (loadResult.isError) {
        throw NuvioPluginException(loadResult.stringResult);
      }
      final args = jsonEncode([
        tmdbId,
        mediaType,
        season,
        episode,
      ]);
      final evaluated = await runtime.evaluateAsync('''
(async function() {
  const args = $args;
  const fn = module.exports && module.exports.getStreams || globalThis.getStreams;
  if (typeof fn !== 'function') return '[]';
  const result = await fn(args[0], args[1], args[2] == null ? undefined : args[2], args[3] == null ? undefined : args[3]);
  return JSON.stringify(result || []);
})()
''');
      if (evaluated.isError) {
        throw NuvioPluginException(evaluated.stringResult);
      }
      final resolved = await runtime
          .handlePromise(evaluated)
          .timeout(const Duration(seconds: 45));
      if (resolved.isError) {
        throw NuvioPluginException(resolved.stringResult);
      }
      final decoded = jsonDecode(resolved.stringResult);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((entry) => entry.cast<String, dynamic>())
          .toList();
    } finally {
      try {
        runtime.evaluate(
          'if (typeof __nuvioClearTimers === "function") __nuvioClearTimers();',
        );
      } catch (_) {}
      cheerio.dispose();
    }
  }

  Future<Map<String, dynamic>> _fetchManifest(String url) async {
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NuvioPluginException(
        'Manifest request failed with HTTP ${response.statusCode}.',
      );
    }
    if (response.bodyBytes.length > _maxManifestBytes) {
      throw const NuvioPluginException('The plugin manifest is too large.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const NuvioPluginException('The URL returned invalid manifest JSON.');
    }
    return decoded.cast<String, dynamic>();
  }

  List<Map<String, dynamic>> _scrapersFrom(Map<String, dynamic> manifest) =>
      (manifest['scrapers'] as List? ?? const [])
          .whereType<Map>()
          .map((entry) => entry.cast<String, dynamic>())
          .toList();

  NuvioPluginScraper _toScraper(Map<String, dynamic> value) =>
      NuvioPluginScraper(
        id: value['id']?.toString() ?? value['filename']?.toString() ?? '',
        name: value['name']?.toString() ?? 'Provider',
        filename: value['filename']?.toString() ?? '',
        supportedTypes: (value['supportedTypes'] as List? ?? const ['movie', 'tv'])
            .map((type) => type.toString())
            .toList(),
        hasSettings: value['hasSettings'] == true,
        enabled: value['enabled'] != false,
      );

  Uri _resolveScraperUrl(String manifestUrl, String filename) {
    final base = Uri.parse(manifestUrl);
    final uri = Uri.parse(filename);
    final resolved = uri.hasScheme ? uri : base.resolve(filename);
    if ((resolved.scheme != 'http' && resolved.scheme != 'https') ||
        resolved.host.isEmpty) {
      throw const NuvioPluginException('Scraper filename is not an HTTP URL.');
    }
    return resolved;
  }

  bool _supportsMediaType(
    Map<String, dynamic> scraper,
    StremioMediaType mediaType,
  ) {
    final target = mediaType == StremioMediaType.movie ? 'movie' : 'tv';
    final supported = (scraper['supportedTypes'] as List? ?? const ['movie', 'tv'])
        .map((value) => value.toString().toLowerCase())
        .map((value) => switch (value) {
              'series' || 'show' || 'other' => 'tv',
              _ => value,
            });
    return supported.contains(target);
  }

  bool _supportsPlatform(Map<String, dynamic> scraper) {
    final platform = kIsWeb
        ? 'web'
        : defaultTargetPlatform == TargetPlatform.iOS
        ? 'ios'
        : defaultTargetPlatform == TargetPlatform.android
        ? 'android'
        : defaultTargetPlatform == TargetPlatform.macOS
        ? 'macos'
        : defaultTargetPlatform == TargetPlatform.windows
        ? 'windows'
        : defaultTargetPlatform == TargetPlatform.linux
        ? 'linux'
        : 'unknown';
    final disabled = (scraper['disabledPlatforms'] as List? ?? const [])
        .map((value) => value.toString().toLowerCase());
    if (disabled.contains(platform)) return false;
    final supported = scraper['supportedPlatforms'];
    if (supported is! List || supported.isEmpty) return true;
    return supported.map((value) => value.toString().toLowerCase()).contains(platform);
  }
}
