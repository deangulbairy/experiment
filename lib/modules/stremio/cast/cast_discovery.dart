// Adapted from https://github.com/IStoleThis/chromecast-testing (Apache-2.0).
import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:dart_cast/dart_cast.dart';

/// Whether device discovery should go through the operating system's own
/// Bonjour / NSD support instead of dart_cast's pure-Dart mDNS.
///
/// iOS (and sandboxed macOS) block raw multicast sockets unless the app holds
/// an Apple-granted entitlement, which a sideloaded build can't have. Android
/// is also more reliable through NSD, since the OS manages the multicast lock.
bool get useNativeDiscovery =>
    Platform.isIOS || Platform.isMacOS || Platform.isAndroid;

/// An [MdnsLookup] for dart_cast backed by Bonsoir.
///
/// dart_cast asks for `_googlecast._tcp.local`; Bonsoir wants the type
/// without the `.local` suffix.
Stream<MdnsServiceInfo> bonsoirLookup(String serviceType) {
  final type = serviceType.replaceFirst(RegExp(r'\.local\.?$'), '');

  BonsoirDiscovery? discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? subscription;
  late final StreamController<MdnsServiceInfo> controller;

  Future<void> shutdown() async {
    final sub = subscription;
    final disc = discovery;
    subscription = null;
    discovery = null;
    await sub?.cancel();
    try {
      await disc?.stop();
    } catch (_) {}
  }

  controller = StreamController<MdnsServiceInfo>(
    onListen: () async {
      try {
        final disc = BonsoirDiscovery(type: type);
        discovery = disc;
        await disc.initialize();
        subscription = disc.eventStream!.listen((event) {
          switch (event) {
            case BonsoirDiscoveryServiceFoundEvent():
              // Resolving is what fills in the address and the TXT records.
              event.service!.resolve(disc.serviceResolver);
            case BonsoirDiscoveryServiceResolvedEvent():
              final BonsoirService? service = event.service;
              if (service == null || controller.isClosed) return;
              final host = _preferReachableAddress(service.hostAddresses);
              if (host == null) return;
              controller.add(
                MdnsServiceInfo(
                  name: service.name,
                  host: host,
                  port: service.port,
                  txtRecords: Map<String, String>.from(service.attributes),
                ),
              );
            default:
              break;
          }
        });
        await disc.start();
      } catch (error, stack) {
        if (!controller.isClosed) controller.addError(error, stack);
      }
    },
    onCancel: shutdown,
  );
  return controller.stream;
}

/// A Chromecast is reached over a plain TLS socket, which can't take an IPv6
/// link-local address without a scope id, so prefer IPv4.
String? _preferReachableAddress(List<String> addresses) {
  for (final address in addresses) {
    if (InternetAddress.tryParse(address)?.type == InternetAddressType.IPv4) {
      return address;
    }
  }
  // Some TVs advertise only IPv6. Keep those visible too; dart:io can connect
  // to global IPv6 addresses, while the most common IPv4 path stays preferred.
  for (final address in addresses) {
    if (InternetAddress.tryParse(address)?.type == InternetAddressType.IPv6) {
      return address;
    }
  }
  return null;
}

