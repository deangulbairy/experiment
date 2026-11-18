import 'package:material_ui/material_ui.dart';
import 'package:mangayomi/modules/stremio/stremio_player_page.dart';
import 'package:mangayomi/services/http/custom_extended_image_provider.dart';
import 'package:mangayomi/services/stremio_library_service.dart';
import 'package:shiori/shiori.dart';

/// Stremio movies and the latest episode of each series, shown in the Watch
/// library alongside the regular anime continue shelf.
class StremioContinueShelf extends StatefulWidget {
  const StremioContinueShelf({super.key});

  @override
  State<StremioContinueShelf> createState() => _StremioContinueShelfState();
}

class _StremioContinueShelfState extends State<StremioContinueShelf> {
  final _service = StremioLibraryService.instance;
  List<StremioLibraryEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _service.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    _service.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    final entries = await _service.getEntries();
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) return const SizedBox.shrink();
    const coverWidth = 96.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ShioriSectionHeader(title: 'Continue watching', overline: true),
        SizedBox(
          height: coverWidth / coverAspect + 72,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: ShioriSpace.s16),
            itemCount: _entries.length > 12 ? 12 : _entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: ShioriSpace.s12),
            itemBuilder: (context, index) {
              final entry = _entries[index];
              final subtitle = entry.episodeTitle ??
                  (entry.duration > Duration.zero
                      ? '${_formatDuration(entry.position)} / ${_formatDuration(entry.duration)}'
                      : 'Movie');
              return SizedBox(
                width: coverWidth,
                child: ShioriCoverTile(
                  subtitle: subtitle,
                  cover: ShioriCover(
                    image: entry.poster.isEmpty
                        ? null
                        : CustomExtendedNetworkImageProvider(entry.poster),
                    title: entry.cardTitle,
                    progress: entry.progress,
                    onTap: () => Navigator.of(
                      context,
                      rootNavigator: true,
                    ).push(
                      MaterialPageRoute<void>(
                        builder: (_) => StremioPlayerPage(
                          stream: entry.stream,
                          title: entry.playbackTitle,
                          mediaType: entry.mediaType,
                          mediaId: entry.mediaId,
                          parentId: entry.parentId,
                          parentTitle: entry.parentTitle,
                          poster: entry.poster,
                          episodeTitle: entry.episodeTitle,
                          initialPosition: entry.position,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: ShioriSpace.s8),
      ],
    );
  }
}
