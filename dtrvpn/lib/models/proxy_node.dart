enum ProxyType { vless, vmess, trojan, ss, hy2, unknown }

class ProxyNode {
  final String name;
  final String server;
  final int port;
  final ProxyType type;
  final Map<String, dynamic> raw;
  int? latencyMs; // null = не замерен, -1 = таймаут

  ProxyNode({
    required this.name,
    required this.server,
    required this.port,
    required this.type,
    required this.raw,
    this.latencyMs,
  });

  String get typeLabel {
    switch (type) {
      case ProxyType.vless:   return 'VLESS';
      case ProxyType.vmess:   return 'VMess';
      case ProxyType.trojan:  return 'Trojan';
      case ProxyType.ss:      return 'SS';
      case ProxyType.hy2:     return 'HY2';
      case ProxyType.unknown: return '???';
    }
  }

  String get latencyLabel {
    if (latencyMs == null) return '—';
    if (latencyMs! < 0)    return 'Timeout';
    return '${latencyMs}ms';
  }

  // Пороги из FlClash: < 600ms = green, 600–1200ms = orange, > 1200ms = red
  bool get isTimeout => latencyMs != null && latencyMs! < 0;
  bool get isFast    => latencyMs != null && latencyMs! >= 0 && latencyMs! < 600;
  bool get isMedium  => latencyMs != null && latencyMs! >= 600 && latencyMs! <= 1200;
  bool get isSlow    => latencyMs != null && latencyMs! > 1200;

  /// Парсинг одного прокси из Clash/Mihomo YAML блока
  factory ProxyNode.fromClashMap(Map<dynamic, dynamic> m) {
    final typeStr = (m['type'] ?? '').toString().toLowerCase();
    ProxyType ptype;
    switch (typeStr) {
      case 'vless':
        ptype = ProxyType.vless;
        break;
      case 'vmess':
        ptype = ProxyType.vmess;
        break;
      case 'trojan':
        ptype = ProxyType.trojan;
        break;
      case 'ss':
      case 'shadowsocks':
        ptype = ProxyType.ss;
        break;
      case 'hysteria2':
      case 'hy2':
        ptype = ProxyType.hy2;
        break;
      default:
        ptype = ProxyType.unknown;
    }

    return ProxyNode(
      name:   (m['name']   ?? 'Unknown').toString(),
      server: (m['server'] ?? '').toString(),
      port:   int.tryParse(m['port']?.toString() ?? '0') ?? 0,
      type:   ptype,
      raw:    Map<String, dynamic>.from(m),
    );
  }

  String toClashYaml() {
    final buf = StringBuffer();
    raw.forEach((k, v) {
      if (v is Map) {
        buf.writeln('  $k:');
        v.forEach((k2, v2) => buf.writeln('    $k2: $v2'));
      } else if (v is List) {
        buf.writeln('  $k: [${v.join(', ')}]');
      } else {
        buf.writeln('  $k: $v');
      }
    });
    return buf.toString();
  }
}
