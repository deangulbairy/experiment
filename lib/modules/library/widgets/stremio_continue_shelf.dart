import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/history/providers/isar_providers.dart';
import 'package:mangayomi/modules/library/widgets/continue_shelf.dart';
import 'package:mangayomi/modules/library/widgets/library_entry_utils.dart';
import 'package:mangayomi/modules/stremio/stremio_player_page.dart';
import 'package:mangayomi/repositories/chapter_repository.dart';
import 'package:mangayomi/repositories/manga_repository.dart';
import 'package:mangayomi/services/http/custom_extended_image_provider.dart';
import 'package:mangayomi/services/stremio_addon_service.dart';
import 'package:mangayomi/services/stremio_library_service.dart';
import 'package:mangayomi/utils/extensions/chapter_extensions.dart';
import 'package:shiori/shiori.dart';

/// A single Continue Watching row shared by anime, movies, and series.
class WatchContinueShelf extends ConsumerStatefulWidget {
  const WatchContinueShelf({super.key});

  @override
  ConsumerState<WatchContinueShelf> createState() =>
      _WatchContinueShelfState();
}

class _WatchContinueShelfState extends ConsumerState<WatchContinueShelf> {
  final _service = StremioLibraryService.instance;
  List<StremioLibraryEntry> _stremioEntries = const [];

  @override
  void initState() {
    super.initState();
    _service.addListener(_refresh);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _service.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    final entries = await _service.getEntries();
    if (!mounted) return;
    setState(() => _stremioEntries = entries);
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final cards = <_WatchShelfCard>[];
    final showAnimeHistory = ref.watch(continueShelfProvider);
    final history = ref
        .watch(getAllHistoryStreamProvider(itemType: ItemType.anime))
        .asData
        ?.value;
    if (history != null && showAnimeHistory) {
      final chapterIds = history.map((item) => item.chapterId).nonNulls.toSet();
      final chapterById = {
        for (final chapter
            in chapterRepository.getAllByIds(chapterIds.toList()).nonNulls)
          chapter.id!: chapter,
      };
      final mangaIds = chapterById.values
          .map((chapter) => chapter.mangaId)
          .nonNulls
          .toSet()
          .toList();
      final mangaById = {
        for (final manga in mangaRepository.getAllByIds(mangaIds).nonNulls)
          manga.id!: manga,
      };
      final lastWatched = <int, int>{};
      for (final item in history) {
        final mangaId = chapterById[item.chapterId]?.mangaId ?? item.mangaId;
        if (mangaId == null) continue;
        final timestamp = int.tryParse(item.date ?? '') ?? 0;
        if (timestamp > (lastWatched[mangaId] ?? 0)) {
          lastWatched[mangaId] = timestamp;
        }
      }
      for (final entry in continueEntries(
        history,
        chapterById: chapterById,
        mangaById: mangaById,
      )) {
        cards.add(
          _WatchShelfCard(
            timestamp: lastWatched[entry.manga.id] ?? 0,
            anime: entry,
          ),
        );
      }
    }
    for (final entry in _stremioEntries) {
      cards.add(
        _WatchShelfCard(
          timestamp: entry.lastPlayedAt.millisecondsSinceEpoch,
          stremio: entry,
        ),
      );
    }
    cards.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    if (cards.isEmpty) return const SizedBox.shrink();

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
            itemCount: cards.length > 12 ? 12 : cards.length,
            separatorBuilder: (_, _) => const SizedBox(width: ShioriSpace.s12),
            itemBuilder: (context, index) {
              final card = cards[index];
              final anime = card.anime;
              if (anime != null) {
                return SizedBox(
                  width: coverWidth,
                  child: ShioriCoverTile(
                    subtitle: anime.chapter.name,
                    cover: ShioriCover(
                      image: resolveCoverImage(anime.manga, ref),
                      title: anime.manga.name ?? '',
                      progress: anime.progress,
                      onTap: () => anime.chapter.pushToReaderView(context),
                      onLongPress: () => context.push(
                        '/manga-reader/detail',
                        extra: anime.manga.id,
                      ),
                    ),
                  ),
                );
              }

              final entry = card.stremio!;
              final subtitle = entry.episodeTitle ??
                  (entry.duration > Duration.zero
                      ? '${_formatDuration(entry.position)} / '
                            '${_formatDuration(entry.duration)}'
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
                    onTap: () => context.push(
                      '/stremioPlayer',
                      extra: StremioPlayerRequest(
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
              );
            },
          ),
        ),
        const SizedBox(height: ShioriSpace.s8),
      ],
    );
  }
}

class _WatchShelfCard {
  const _WatchShelfCard({
    required this.timestamp,
    this.anime,
    this.stremio,
  });

  final int timestamp;
  final ContinueEntry? anime;
  final StremioLibraryEntry? stremio;
}
