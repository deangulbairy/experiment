// Adapted from https://github.com/IStoleThis/chromecast-testing (Apache-2.0).
import 'package:dart_cast/dart_cast.dart' show CastDevice;
import 'package:material_ui/material_ui.dart';

import 'cast_controller.dart';

/// The cast icon for the player's top bar. It fills in while casting.
class CastButton extends StatelessWidget {
  const CastButton({
    super.key,
    required this.controller,
    required this.onPressed,
  });

  final CastController controller;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final casting = controller.isCasting;
        return IconButton(
          tooltip: casting
              ? 'Casting to ${controller.device?.name ?? 'TV'}'
              : 'Cast to TV',
          icon: Icon(
            casting ? Icons.cast_connected : Icons.cast,
            color: Colors.white,
          ),
          onPressed: onPressed,
        );
      },
    );
  }
}

/// Opens the device picker, which turns into the remote while casting.
Future<void> showCastSheet(
  BuildContext context, {
  required CastController controller,
  required void Function(CastDevice device) onDeviceSelected,
  required VoidCallback onStopCasting,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (_) => CastSheet(
      controller: controller,
      onDeviceSelected: onDeviceSelected,
      onStopCasting: onStopCasting,
    ),
  );
}

class CastSheet extends StatefulWidget {
  const CastSheet({
    super.key,
    required this.controller,
    required this.onDeviceSelected,
    required this.onStopCasting,
  });

  final CastController controller;
  final void Function(CastDevice device) onDeviceSelected;
  final VoidCallback onStopCasting;

  @override
  State<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<CastSheet> {
  CastController get _cast => widget.controller;

  @override
  void initState() {
    super.initState();
    if (!_cast.isBusy) _cast.discover();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: _cast,
        builder: (context, _) {
          final theme = Theme.of(context);
          final casting = _cast.isCasting;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(casting ? Icons.cast_connected : Icons.cast),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          casting
                              ? 'Casting to ${_cast.device?.name ?? 'TV'}'
                              : 'Cast to a TV',
                          style: theme.textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!_cast.isBusy)
                        IconButton(
                          tooltip: 'Search again',
                          icon: const Icon(Icons.refresh),
                          onPressed: _cast.status == CastStatus.searching
                              ? null
                              : _cast.discover,
                        ),
                    ],
                  ),
                  if (_cast.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _cast.error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  const SizedBox(height: 8),
                  if (casting)
                    _RemotePanel(
                      controller: _cast,
                      onStopCasting: widget.onStopCasting,
                    )
                  else if (_cast.status == CastStatus.connecting)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Row(
                        children: [
                          const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              'Connecting to ${_cast.device?.name ?? 'TV'}…',
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    _DeviceList(
                      controller: _cast,
                      onDeviceSelected: widget.onDeviceSelected,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.controller, required this.onDeviceSelected});

  final CastController controller;
  final void Function(CastDevice device) onDeviceSelected;

  @override
  Widget build(BuildContext context) {
    final searching = controller.status == CastStatus.searching;
    final devices = controller.devices;

    if (devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: searching
            ? const Row(
                children: [
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 16),
                  Expanded(child: Text('Looking for TVs on your Wi-Fi…')),
                ],
              )
            : const Text(
                'No Chromecast found. Check that this device and the TV are on '
                'the same Wi-Fi network, then search again.',
              ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (searching) const LinearProgressIndicator(),
        for (final device in devices)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.tv),
            title: Text(device.name),
            subtitle: (device.metadata['md'] ?? '').isEmpty
                ? null
                : Text(device.metadata['md']!),
            onTap: () => onDeviceSelected(device),
          ),
      ],
    );
  }
}

class _RemotePanel extends StatefulWidget {
  const _RemotePanel({required this.controller, required this.onStopCasting});

  final CastController controller;
  final VoidCallback onStopCasting;

  @override
  State<_RemotePanel> createState() => _RemotePanelState();
}

class _RemotePanelState extends State<_RemotePanel> {
  double? _seekDrag;
  double? _volumeDrag;

  CastController get _cast => widget.controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<Duration>(
          valueListenable: _cast.duration,
          builder: (context, total, _) => ValueListenableBuilder<Duration>(
            valueListenable: _cast.position,
            builder: (context, position, _) => _seekBar(position, total),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              iconSize: 32,
              tooltip: 'Back 10 seconds',
              icon: const Icon(Icons.replay_10),
              onPressed: () => _cast.seekBy(const Duration(seconds: -10)),
            ),
            IconButton(
              iconSize: 56,
              tooltip: _cast.isPlaying ? 'Pause' : 'Play',
              icon: Icon(
                _cast.isPlaying
                    ? Icons.pause_circle_filled
                    : Icons.play_circle_filled,
              ),
              onPressed: _cast.togglePlayPause,
            ),
            IconButton(
              iconSize: 32,
              tooltip: 'Forward 10 seconds',
              icon: const Icon(Icons.forward_10),
              onPressed: () => _cast.seekBy(const Duration(seconds: 10)),
            ),
          ],
        ),
        Row(
          children: [
            const Icon(Icons.volume_down),
            Expanded(
              child: Slider(
                value: _volumeDrag ?? _cast.volume ?? 1.0,
                onChanged: (value) => setState(() => _volumeDrag = value),
                onChangeEnd: (value) {
                  setState(() => _volumeDrag = null);
                  _cast.setVolume(value);
                },
              ),
            ),
            const Icon(Icons.volume_up),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: widget.onStopCasting,
            icon: const Icon(Icons.cast_connected),
            label: const Text('Stop casting'),
          ),
        ),
      ],
    );
  }

  Widget _seekBar(Duration position, Duration total) {
    final enabled = total > Duration.zero;
    final max = enabled ? total.inMilliseconds.toDouble() : 1.0;
    final current = (_seekDrag ?? position.inMilliseconds.toDouble())
        .clamp(0.0, max)
        .toDouble();
    return Column(
      children: [
        Slider(
          value: enabled ? current : 0.0,
          max: max,
          onChanged: enabled
              ? (value) => setState(() => _seekDrag = value)
              : null,
          onChangeEnd: enabled
              ? (value) {
                  setState(() => _seekDrag = null);
                  _cast.seek(Duration(milliseconds: value.round()));
                }
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_format(Duration(milliseconds: current.round()))),
              Text(enabled ? _format(total) : '--:--'),
            ],
          ),
        ),
      ],
    );
  }

  static String _format(Duration value) {
    String two(int n) => n.toString().padLeft(2, '0');
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }
}

