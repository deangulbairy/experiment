import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shiori/shiori.dart';
import 'package:mangayomi/modules/stremio/stremio_player_page.dart';
import 'package:mangayomi/services/stremio_addon_service.dart';

class MoviesTvScreen extends StatefulWidget {
  const MoviesTvScreen({super.key});

  @override
  State<MoviesTvScreen> createState() => _MoviesTvScreenState();
}

class _MoviesTvScreenState extends State<MoviesTvScreen> {
  final _service = StremioAddonService();
  final _searchController = TextEditingController();
  List<StremioAddon> _addons = const [];
  List<StremioCatalog> _catalogs = const [];
  List<StremioMeta> _items = const [];
  StremioCatalog? _selectedCatalog;
  StremioMediaType _type = StremioMediaType.movie;
  String? _filterValue;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final addons = await _service.loadAddons();
      final catalogs = _service.catalogs(addons, _type);
      final selected = catalogs.firstWhere(
        (catalog) => catalog.addon.id == 'com.linvo.cinemeta' && catalog.id == 'top',
        orElse: () => catalogs.firstOrNull ??
            (throw const StremioAddonException(
              'No movie or series catalogs are available. Add a catalog add-on to get started.',
            )),
      );
      final filterValue = _defaultFilter(selected);
      final items = await _loadItems(selected, filterValue: filterValue);
      if (!mounted) return;
      setState(() {
        _addons = addons;
        _catalogs = catalogs;
        _selectedCatalog = selected;
        _filterValue = filterValue;
        _items = items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  String? _defaultFilter(StremioCatalog catalog) {
    final required = catalog.requiredDefaults;
    for (final extra in catalog.optionExtras) {
      final name = extra['name']?.toString();
      if (name != null && required.containsKey(name)) return required[name];
    }
    return null;
  }

  Future<List<StremioMeta>> _loadItems(
    StremioCatalog catalog, {
    String? filterValue,
  }) {
    final filter = catalog.optionExtras.firstOrNull;
    return _service.loadCatalog(
      catalog,
      search: _searchController.text,
      filterName: filter?['name']?.toString(),
      filterValue: filterValue,
    );
  }

  Future<void> _selectCatalog(StremioCatalog catalog) async {
    final filterValue = _defaultFilter(catalog);
    setState(() {
      _selectedCatalog = catalog;
      _filterValue = filterValue;
      _loading = true;
      _error = null;
    });
    await _loadSelectedCatalog(filterValue: filterValue);
  }

  Future<void> _loadSelectedCatalog({String? filterValue}) async {
    final catalog = _selectedCatalog;
    if (catalog == null) return;
    try {
      final items = await _loadItems(catalog, filterValue: filterValue);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _setType(StremioMediaType type) async {
    if (_type == type) return;
    _type = type;
    await _refresh();
  }

  Future<void> _submitSearch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _loadSelectedCatalog(filterValue: _filterValue);
  }

  Future<void> _openMeta(StremioMeta preview) async {
    final catalog = _selectedCatalog;
    if (catalog == null) return;
    final meta = await _service.loadMeta(
      _addons,
      _type,
      preview.id,
      preview,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StremioDetailsPage(
          meta: meta,
          mediaType: _type,
          addons: _addons,
          service: _service,
        ),
      ),
    );
  }

  void _manageAddons() => context.push('/stremioAddons');

  @override
  Widget build(BuildContext context) {
    final catalog = _selectedCatalog;
    final optionExtra = catalog?.optionExtras.firstOrNull;
    final options = (optionExtra?['options'] as List? ?? const [])
        .map((value) => value.toString())
        .toList();
    final extraName = optionExtra?['name']?.toString();
    final isFilterRequired =
        extraName != null && catalog!.requiredDefaults.containsKey(extraName);
    final supportsSearch = catalog?.supportsSearch ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Movies & TV'),
        actions: [
          IconButton(
            tooltip: 'Manage Stremio add-ons',
            onPressed: _manageAddons,
            icon: const Icon(Icons.extension_outlined),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  SegmentedButton<StremioMediaType>(
                    segments: const [
                      ButtonSegment(
                        value: StremioMediaType.movie,
                        label: Text('Movies'),
                        icon: Icon(Icons.movie_outlined),
                      ),
                      ButtonSegment(
                        value: StremioMediaType.series,
                        label: Text('Series'),
                        icon: Icon(Icons.tv_outlined),
                      ),
                    ],
                    selected: {_type},
                    onSelectionChanged: (selection) => _setType(selection.first),
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final controls = <Widget>[
                        Expanded(
                          child: DropdownButtonFormField<StremioCatalog>(
                            value: catalog,
                            decoration: const InputDecoration(
                              labelText: 'Catalog',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: _catalogs
                                .map((item) => DropdownMenuItem(
                                      value: item,
                                      child: Text(
                                        '${item.addon.name} · ${item.name}',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ))
                                .toList(),
                            onChanged: (value) {
                              if (value != null) _selectCatalog(value);
                            },
                          ),
                        ),
                        if (options.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: DropdownButtonFormField<String?>(
                              value: _filterValue,
                              decoration: InputDecoration(
                                labelText: 'Filter',
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: [
                                if (!isFilterRequired)
                                  const DropdownMenuItem<String?>(
                                    value: null,
                                    child: Text('All'),
                                  ),
                                ...options.map((value) => DropdownMenuItem<String?>(
                                      value: value,
                                      child: Text(value, overflow: TextOverflow.ellipsis),
                                    )),
                              ],
                              onChanged: (value) {
                                setState(() {
                                  _filterValue = value;
                                  _loading = true;
                                });
                                _loadSelectedCatalog(filterValue: value);
                              },
                            ),
                          ),
                        ],
                      ];
                      if (constraints.maxWidth < 540 && options.isNotEmpty) {
                        return Column(
                          children: [
                            Row(children: [controls.first]),
                            const SizedBox(height: 8),
                            Row(children: [controls.last]),
                          ],
                        );
                      }
                      return Row(children: controls);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _searchController,
                    enabled: supportsSearch,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _submitSearch(),
                    decoration: InputDecoration(
                      hintText: supportsSearch
                          ? 'Search this catalog'
                          : 'This catalog does not support search',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: IconButton(
                        tooltip: 'Search',
                        onPressed: supportsSearch ? _submitSearch : null,
                        icon: const Icon(Icons.arrow_forward_rounded),
                      ),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildCatalogBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildCatalogBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _MessageState(
        icon: Icons.cloud_off_outlined,
        message: _error!,
        action: FilledButton.icon(
          onPressed: _refresh,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try again'),
        ),
      );
    }
    if (_items.isEmpty) {
      return const _MessageState(
        icon: Icons.search_off_rounded,
        message: 'No titles found in this catalog.',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        mainAxisExtent: 316,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return _MetaCard(
          meta: item,
          onTap: () => _openMeta(item),
        );
      },
    );
  }
}

class _MetaCard extends StatelessWidget {
  const _MetaCard({required this.meta, required this.onTap});

  final StremioMeta meta;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(ShioriShape.card),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ShioriShape.cover),
              child: SizedBox(
                width: double.infinity,
                child: meta.poster.isEmpty
                    ? ColoredBox(
                        color: context.shiori.color.ink1,
                        child: Center(child: Icon(Icons.movie_outlined, size: 40)),
                      )
                    : Image.network(
                        meta.poster,
                        fit: BoxFit.cover,
                        errorBuilder: (context, _, _) => ColoredBox(
                          color: context.shiori.color.ink1,
                          child: Center(child: Icon(Icons.broken_image_outlined)),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            meta.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (meta.releaseInfo.isNotEmpty)
            Text(
              meta.releaseInfo,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class StremioDetailsPage extends StatefulWidget {
  const StremioDetailsPage({
    super.key,
    required this.meta,
    required this.mediaType,
    required this.addons,
    required this.service,
  });

  final StremioMeta meta;
  final StremioMediaType mediaType;
  final List<StremioAddon> addons;
  final StremioAddonService service;

  @override
  State<StremioDetailsPage> createState() => _StremioDetailsPageState();
}

class _StremioDetailsPageState extends State<StremioDetailsPage> {
  List<StremioStream> _streams = const [];
  String? _streamError;
  String? _selectedVideoTitle;
  String? _selectedEpisodeId;
  int _streamRequestId = 0;
  bool _loadingStreams = false;

  Future<void> _loadStreams(
    String id,
    String title, {
    bool isEpisode = false,
  }) async {
    final requestId = ++_streamRequestId;
    setState(() {
      _selectedVideoTitle = title;
      _selectedEpisodeId = isEpisode ? id : null;
      _loadingStreams = true;
      _streamError = null;
      _streams = const [];
    });
    try {
      final streams = await widget.service.loadStreams(
        widget.addons,
        widget.mediaType,
        id,
      );
      if (!mounted || requestId != _streamRequestId) return;
      setState(() {
        _streams = streams;
        _loadingStreams = false;
        if (streams.isEmpty) {
          _streamError =
              'No streams were returned. Add a Stremio streaming add-on from the extension button.';
        }
      });
    } catch (error) {
      if (!mounted || requestId != _streamRequestId) return;
      setState(() {
        _loadingStreams = false;
        _streamError = error.toString();
      });
    }
  }

  Future<void> _play(StremioStream stream) async {
    await context.push(
      '/stremioPlayer',
      extra: StremioPlayerRequest(
        stream: stream,
        title: _selectedVideoTitle ?? widget.meta.name,
        mediaType: widget.mediaType,
        mediaId: widget.mediaType == StremioMediaType.series
            ? _selectedEpisodeId ?? widget.meta.id
            : widget.meta.id,
        parentId: widget.meta.id,
        parentTitle: widget.meta.name,
        poster: widget.meta.poster,
        episodeTitle: widget.mediaType == StremioMediaType.series
            ? _selectedVideoTitle
            : null,
      ),
    );
  }

  Widget _buildStreamResults(BuildContext context) {
    if (!_loadingStreams && _streamError == null && _streams.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loadingStreams)
            const Center(child: CircularProgressIndicator())
          else if (_streamError != null)
            Text(
              _streamError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            )
          else ...[
            Text('Streams', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ..._streams.map((stream) => Card(
                  child: ListTile(
                    leading: Icon(stream.isTorrent
                        ? Icons.tune_rounded
                        : Icons.play_arrow_rounded),
                    title: Text(stream.displayTitle,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(stream.addonName),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _play(stream),
                  ),
                )),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final meta = widget.meta;
    final episodes = meta.episodes
      ..sort((a, b) {
        final season = a.season.compareTo(b.season);
        if (season != 0) return season;
        final episode = a.episode.compareTo(b.episode);
        return episode != 0 ? episode : a.id.compareTo(b.id);
      });

    return Scaffold(
      appBar: AppBar(title: Text(meta.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (meta.poster.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(ShioriShape.cover),
                  child: Image.network(
                    meta.poster,
                    width: 120,
                    height: 180,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(
                      width: 120,
                      height: 180,
                      child: Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(meta.name, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text([
                      widget.mediaType.label,
                      if (meta.releaseInfo.isNotEmpty) meta.releaseInfo,
                      if (meta.runtime.isNotEmpty) meta.runtime,
                    ].join(' · ')),
                    if (meta.genres.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(meta.genres.join(' · ')),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (meta.description.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(meta.description),
          ],
          const SizedBox(height: 20),
          if (widget.mediaType == StremioMediaType.movie)
            ...[
              FilledButton.icon(
                onPressed: () => _loadStreams(meta.id, meta.name),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Find streams'),
              ),
              _buildStreamResults(context),
            ]
          else ...[
            Text('Episodes', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (episodes.isEmpty)
              const Text('No episodes were provided by the metadata add-on.')
            else
              ...episodes.map((episode) {
                final selected = _selectedEpisodeId == episode.id;
                return Column(
                  children: [
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.play_circle_outline_rounded),
                        title: Text(episode.label),
                        trailing: selected && _loadingStreams
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.chevron_right_rounded),
                        onTap: episode.id.isEmpty
                            ? null
                            : () => _loadStreams(
                                  episode.id,
                                  episode.label,
                                  isEpisode: true,
                                ),
                      ),
                    ),
                    if (selected) _buildStreamResults(context),
                  ],
                );
              }),
          ],
        ],
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({required this.icon, required this.message, this.action});

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}
