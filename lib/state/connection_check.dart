import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/log_privacy.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/platform_provider.dart';

/// The connection check of Settings → Developer: whether it is running, and
/// what the last one found, a line per network and per address.
///
/// Held here and not in the page, so a check outlives the page: once
/// Settings was closed 19 s into one, the answer arrived a second
/// later at a page that was gone, and OpenDash went to its error screen
/// without logging what the check had found.
final connectionCheckProvider =
    NotifierProvider<ConnectionCheck, ({bool running, List<String>? lines})>(ConnectionCheck.new);

class ConnectionCheck extends Notifier<({bool running, List<String>? lines})> {
  @override
  ({bool running, List<String>? lines}) build() => (running: false, lines: null);

  static String _ms(Object? v) => v == null ? '' : ' ${v}ms';

  /// One line per network, then one per address: how far it got.
  static List<String> describe(List<Map<String, Object?>> networks) {
    if (networks.isEmpty) return ['No network: neither Wi-Fi nor mobile data is up.'];
    return [
      for (final n in networks) ...[
        '${n['transport'] == 'wifi' ? 'Wi-Fi' : n['transport'] == 'mobile' ? 'Mobile data' : 'Other network'}'
            '${n['default'] == true ? ' (in use)' : ''}: '
            '${n['validated'] == true ? 'internet confirmed by Android' : 'internet not confirmed by Android'}'
            ' · DNS ${(n['dns'] as List?)?.join(', ') ?? 'none'}'
            '${n['private_dns'] == 'off' ? '' : ' · private DNS ${n['private_dns']}'}'
            '${n['ipv4'] == null ? '' : ' · IPv4 ${n['ipv4'] == true ? 'yes' : 'no'}, IPv6 ${n['ipv6'] == true ? 'yes' : 'no'}'}'
            '${n['mtu'] is int && n['mtu'] != 0 ? ', MTU ${n['mtu']}' : ''}',
        if (n['cloudflare'] case final Map c)
          '  1.1.1.1 (used for OpenDash downloads): '
              '${c['ok'] == true ? 'answers${_ms(c['took_ms'])}' : 'no answer${_ms(c['took_ms'])}${c['error'] == null ? '' : ' · ${c['error']}'}'}'
              ' · system-wide Private DNS ${c['dot'] == true ? 'would be reachable' : 'port not reachable'}',
        for (final h in (n['hosts'] as List? ?? const []).cast<Map<String, Object?>>())
          '  ${h['host']}: ${switch (h['stage']) {
            'done' => 'reached (HTTP ${h['status']}) · name${_ms(h['dns_ms'])}, connect${_ms(h['connect_ms'])}, answer${_ms(h['https_ms'])}',
            'https' => 'connected, then no answer over HTTPS${_ms(h['failed_ms'])}',
            'connect' => 'name found${_ms(h['dns_ms'])}, could not connect${_ms(h['failed_ms'])}',
            _ => 'name not found (DNS)${_ms(h['failed_ms'])}',
          }}${h['stage'] != 'done' && h['error'] == null ? ' · still waiting after 20 s' : ''}'
              '${h['stage'] != 'done' && h['error'] != null ? ' · ${h['error']}' : ''}',
      ],
    ];
  }

  Future<void> run() async {
    if (state.running) return;
    state = (running: true, lines: state.lines);
    List<String> lines;
    try {
      final networks = await ref.read(platformServiceProvider).networkCheck();
      if (!ref.mounted) return;
      final v = ref.read(vehicleProvider);
      logEvent('net', 'check', {'wifi': v.wifiConnected, 'signal': v.signalBars, 'networks': LogPrivacy.networks(networks)});
      lines = describe(networks);
    } catch (e) {
      logEvent('net', 'check', {'error': e.toString()});
      if (!ref.mounted) return;
      lines = ['The check could not be run on this platform.'];
    }
    state = (running: false, lines: lines);
  }
}
