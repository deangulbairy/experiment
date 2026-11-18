import 'package:flutter/material.dart';
import 'package:mangayomi/services/stremio_addon_service.dart';

/// Settings screen for the Stremio add-on manifest URLs used by Movies & TV.
class StremioAddonSettingsPage extends StatefulWidget {
  const StremioAddonSettingsPage({super.key});

  @override
  State<StremioAddonSettingsPage> createState() =>
      _StremioAddonSettingsPageState();
}

class _StremioAddonSettingsPageState extends State<StremioAddonSettingsPage> {
  final _service = StremioAddonService();
  List<String> _urls = const [];
  List<StremioAddon> _addons = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    var urls = <String>[];
    try {
      urls = await _service.installedManifestUrls();
      final addons = await _service.loadAddons();
      if (!mounted) return;
      setState(() {
        _urls = urls;
        _addons = addons;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _urls = urls;
        _addons = const [];
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Movie/TV Add-on URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Manifest URL',
            hintText: 'https://addon.example/manifest.json',
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
      await _service.addManifestUrl(url);
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  Future<void> _remove(String url) async {
    try {
      await _service.removeManifestUrl(url);
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Movie/TV Add-on URLs')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _add,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add URL'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _urls.isEmpty
              ? Center(child: Text(_error!))
              : _urls.isEmpty
                  ? const Center(child: Text('No add-on URLs are installed.'))
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 96),
                      children: [
                        if (_error != null)
                          ListTile(
                            leading: const Icon(Icons.wifi_off_rounded),
                            title: const Text('Could not load add-on details'),
                            subtitle: Text(_error!),
                          ),
                        ..._urls.map((url) {
                          final addon = _addons
                              .where((item) => item.manifestUrl == url)
                              .firstOrNull;
                          final isDefault = url == stremioCinemetaManifest;
                          return ListTile(
                            title: Text(
                              addon?.name ?? Uri.tryParse(url)?.host ?? url,
                            ),
                            subtitle: Text(
                              url,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: isDefault
                                ? const Icon(Icons.lock_outline_rounded)
                                : IconButton(
                                    tooltip: 'Remove add-on URL',
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                    ),
                                    onPressed: () => _remove(url),
                                  ),
                          );
                        }),
                      ],
                    ),
    );
  }
}
