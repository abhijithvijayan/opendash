/// What a log line may say about the rider's network and whereabouts. A
/// log is pulled and passed on, so nothing in it may single out a person, a
/// household or a place. `ScooterSurvey.shown` is the rule for values
/// from the stock service; this is the rule for what Android reports.
abstract final class LogPrivacy {
  /// A DNS server address: an IPv4 one stays (a router's private address,
  /// or a carrier's or a public resolver's); an IPv6 one keeps its first
  /// two groups, which name the provider and not the line.
  static String dnsServer(String address) {
    if (!address.contains(':')) return address;
    final groups = address.split(':').where((g) => g.isNotEmpty).take(2).join(':');
    return '$groups::';
  }

  /// A private DNS host name: the provider stays, a first label that can
  /// be an account's own (`abc123.dns.example.io`) goes.
  static Object? privateDns(Object? name) {
    if (name is! String || name == 'off' || name == 'auto') return name;
    final labels = name.split('.');
    return labels.length < 3 ? name : '*.${labels.skip(1).join('.')}';
  }

  /// `networks` as `platform.networkCheck` and `Net.kt` report them, for
  /// the log. The screen keeps the full values.
  static List<Object?> networks(List<Object?> networks) => [
        for (final n in networks)
          if (n is Map)
            {
              for (final MapEntry(:key, :value) in n.entries)
                key: switch (key) {
                  'dns' => [for (final a in value is List ? value : const []) a is String ? dnsServer(a) : a],
                  'private_dns' => privateDns(value),
                  _ => value,
                },
            }
          else
            n,
      ];

  /// A sunrise or sunset as the scooter reports it (`yyyy-MM-dd HH:mm:ss`),
  /// to the quarter hour: the second it sets is a position.
  static Object? sunTime(Object? value) {
    if (value is! String) return value == null ? null : 'unreadable';
    final m = RegExp(r'^(\d{4}-\d{2}-\d{2}) (\d{2}):(\d{2})').firstMatch(value);
    if (m == null) return 'unreadable';
    final minute = int.parse(m.group(3)!) ~/ 15 * 15;
    return '${m.group(1)} ${m.group(2)}:${minute.toString().padLeft(2, '0')}';
  }
}
