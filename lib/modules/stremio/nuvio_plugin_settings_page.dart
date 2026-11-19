import 'package:flutter/material.dart';
import 'package:mangayomi/services/nuvio_plugin_service.dart';

/// Settings screen for native Nuvio JavaScript scraper repositories.
class NuvioPluginSettingsPage extends StatefulWidget {
  const NuvioPluginSettingsPage({super.key});

  @override
  State<NuvioPluginSettingsPage> createState() =>
      _NuvioPluginSettingsPageState();
}

class _NuvioPluginSettingsPageState extends State<NuvioPluginSettingsPage> {
  final _service = NuvioPluginService.instance;
  List<NuvioPluginRepository> _repositories = const [];
  bool _loading = true;
  bool _hasTmdbKey = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final values = await Future.wait([
      _service.loadRepositories(),
      _service.tmdbApiKey(),
    ]);
    if (!mounted) return;
    setState(() {
      _repositories = values[0] as List<NuvioPluginRepository>;
      _hasTmdbKey = (values[1] as String?)?.isNotEmpty == true;
      _loading = false;
    });
  }

  Future<void> _addRepository() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Nuvio plugin repository'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Manifest URL',
            hintText: 'https://example.com/manifest.json',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.isEmpty) return;
    try {
      await _service.addRepository(url);
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  Future<void> _removeRepository(NuvioPluginRepository repository) async {
    await _service.removeRepository(repository.manifestUrl);
    await _load();
  }

  Future<void> _editScraperSettings(
    NuvioPluginRepository repository,
    NuvioPluginScraper scraper,
  ) async {
    try {
      final layout = await _service.loadSettingsLayout(
        repository.manifestUrl,
        scraper,
      );
      if (!mounted) return;
      final storageId = _service.scraperSettingsStorageId(
        repository.manifestUrl,
        scraper.id,
      );
      final values = <String, dynamic>{};
      for (final field in layout) {
        final key = field['key']?.toString();
        if (key != null && field.containsKey('defaultValue')) {
          values[key] = field['defaultValue'];
        }
      }
      values.addAll(await _service.scraperSettings(storageId));
      final controllers = <String, TextEditingController>{};
      for (final field in layout) {
        if (field['type']?.toString() == 'text') {
          final key = field['key']?.toString();
          if (key != null) {
            controllers[key] = TextEditingController(
              text: values[key]?.toString() ?? '',
            );
          }
        }
      }

      final shouldSave = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('${scraper.name} settings'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final field in layout)
                      _buildSettingField(
                        field,
                        values,
                        controllers,
                        setDialogState,
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
      for (final controller in controllers.values) {
        controller.dispose();
      }
      if (shouldSave == true) {
        await _service.saveScraperSettings(storageId, values);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  Widget _buildSettingField(
    Map<String, dynamic> field,
    Map<String, dynamic> values,
    Map<String, TextEditingController> controllers,
    void Function(void Function()) setDialogState,
  ) {
    final type = field['type']?.toString() ?? 'info';
    final key = field['key']?.toString();
    final label = field['label']?.toString() ?? '';
    final description = field['description']?.toString();
    switch (type) {
      case 'header':
        return Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(label, style: Theme.of(context).textTheme.titleSmall),
          ),
        );
      case 'info':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(description?.isNotEmpty == true ? description! : label),
          ),
        );
      case 'text':
        if (key == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            controller: controllers[key],
            obscureText: field['isPassword'] == true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: label,
              hintText: field['placeholder']?.toString(),
              helperText: description,
            ),
            onChanged: (value) => values[key] = value,
          ),
        );
      case 'toggle':
        if (key == null) return const SizedBox.shrink();
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          subtitle: description == null ? null : Text(description),
          value: values[key] == true,
          onChanged: (value) => setDialogState(() => values[key!] = value),
        );
      case 'select':
        if (key == null) return const SizedBox.shrink();
        final options = (field['options'] as List? ?? const [])
            .whereType<Map>()
            .map((option) => option.cast<String, dynamic>())
            .toList();
        if (options.isEmpty) return const SizedBox.shrink();
        final selectedValue = values[key] ?? options.first['value'];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: DropdownButtonFormField<dynamic>(
            value: selectedValue,
            decoration: InputDecoration(
              labelText: label,
              helperText: description,
            ),
            items: options
                .map((option) => DropdownMenuItem<dynamic>(
                      value: option['value'],
                      child: Text(option['label']?.toString() ??
                          option['value']?.toString() ?? ''),
                    ))
                .toList(),
            onChanged: (value) {
              if (value != null) setDialogState(() => values[key!] = value);
            },
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Future<void> _editTmdbKey() async {
    final controller = TextEditingController(
      text: await _service.tmdbApiKey() ?? '',
    );
    if (!mounted) {
      controller.dispose();
      return;
    }
    final key = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('TMDB API key'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'API key',
            helperText:
                'Used to match IMDb catalog IDs to the TMDB IDs expected by Nuvio plugins. Leave blank to remove it.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (key == null) return;
    await _service.setTmdbApiKey(key);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nuvio plugin repositories')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _addRepository,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add repository'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Nuvio plugins run scraper JavaScript on this device. Add repositories you trust.',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: const Text('TMDB API key'),
                  subtitle: Text(
                    _hasTmdbKey
                        ? 'Saved securely · Used to match IMDb IDs for Nuvio providers'
                        : 'Optional · Needed when a title only has an IMDb ID',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _editTmdbKey,
                ),
                const Divider(),
                if (_repositories.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('No Nuvio plugin repositories are installed.'),
                    ),
                  )
                else
                  ..._repositories.map((repository) => Card(
                        clipBehavior: Clip.antiAlias,
                        child: ExpansionTile(
                          title: Text(repository.name),
                          subtitle: Text(
                            repository.error ??
                                [
                                  if (repository.version.isNotEmpty)
                                    'Version ${repository.version}',
                                  '${repository.scraperCount} providers',
                                ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          children: [
                            if (repository.error == null)
                              ...repository.scrapers.map((scraper) => ListTile(
                                    title: Text(scraper.name),
                                    subtitle: Text(
                                      scraper.enabled
                                          ? scraper.supportedTypes.join(' · ')
                                          : 'Disabled in manifest',
                                    ),
                                    trailing: scraper.hasSettings
                                        ? IconButton(
                                            tooltip: 'Configure provider',
                                            icon: const Icon(
                                              Icons.tune_rounded,
                                            ),
                                            onPressed: () =>
                                                _editScraperSettings(
                                              repository,
                                              scraper,
                                            ),
                                          )
                                        : null,
                                    onTap: scraper.hasSettings
                                        ? () => _editScraperSettings(
                                              repository,
                                              scraper,
                                            )
                                        : null,
                                  )),
                            ListTile(
                              leading: const Icon(Icons.link_rounded),
                              title: Text(repository.manifestUrl),
                              trailing: IconButton(
                                tooltip: 'Remove repository',
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () => _removeRepository(repository),
                              ),
                            ),
                          ],
                        ),
                      )),
              ],
            ),
    );
  }
}
