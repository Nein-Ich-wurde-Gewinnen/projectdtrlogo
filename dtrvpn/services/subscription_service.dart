import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';
import '../models/profile.dart';
import '../models/proxy_node.dart';

// Top-level для compute()
List<ProxyNode> _parseProxiesBackground(String yaml) {
  try {
    final doc = loadYaml(yaml);
    if (doc is! YamlMap) return [];
    final all = <ProxyNode>[];

    // Обычные proxies:
    final proxies = doc['proxies'];
    if (proxies is YamlList) {
      all.addAll(proxies.whereType<YamlMap>().map((m) {
        try { return ProxyNode.fromClashMap(m); } catch (_) { return null; }
      }).whereType<ProxyNode>());
    }

    // Remnawave: proxy-providers с type: inline
    final providers = doc['proxy-providers'];
    if (providers is YamlMap) {
      for (final entry in providers.entries) {
        final provider = entry.value;
        if (provider is YamlMap && provider['type'] == 'inline') {
          final pp = provider['proxies'];
          if (pp is YamlList) {
            all.addAll(pp.whereType<YamlMap>().map((m) {
              try { return ProxyNode.fromClashMap(m); } catch (_) { return null; }
            }).whereType<ProxyNode>());
          }
        }
      }
    }
    return all;
  } catch (_) {
    return [];
  }
}

class SubInfo {
  final String raw;
  final List<ProxyNode> nodes;
  final String name;
  final String? username;
  final int? trafficUsed;
  final int? trafficTotal;
  final DateTime? expireDate;

  const SubInfo({
    required this.raw,
    required this.nodes,
    required this.name,
    this.username,
    this.trafficUsed,
    this.trafficTotal,
    this.expireDate,
  });
}

class SubscriptionService {
  static const _timeout = Duration(seconds: 15);

  Future<SubInfo> fetchSubscription(String url) async {
    final uri = Uri.parse(url);
    final response = await http.get(uri, headers: {
      'User-Agent': 'clash.meta',
      'Accept': '*/*',
    }).timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
    }

    String body = response.body;
    // Попытка base64-декода
    try {
      final decoded = utf8.decode(base64.decode(body.trim()));
      if (decoded.contains('proxies:') || decoded.contains('Proxy:')) {
        body = decoded;
      }
    } catch (_) {}

    // Парсим заголовки подписки (стандарт Clash + Remnawave)
    final userInfo = _parseUserInfo(response.headers);
    final subName = _extractName(response.headers, url);

    final nodes = await compute(_parseProxiesBackground, body);

    return SubInfo(
      raw: body,
      nodes: nodes,
      name: subName,
      username: userInfo.username,
      trafficUsed: userInfo.trafficUsed,
      trafficTotal: userInfo.trafficTotal,
      expireDate: userInfo.expireDate,
    );
  }

  _UserInfo _parseUserInfo(Map<String, String> headers) {
    // subscription-userinfo: upload=X; download=Y; total=Z; expire=T
    final raw = headers['subscription-userinfo'] ?? '';
    int? upload, download, total;
    DateTime? expire;

    for (final part in raw.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length != 2) continue;
      final key = kv[0].trim();
      final val = int.tryParse(kv[1].trim());
      if (val == null) continue;
      switch (key) {
        case 'upload':   upload = val; break;
        case 'download': download = val; break;
        case 'total':    total = val; break;
        case 'expire':
          // expire=0 означает безлимитную подписку (нет срока истечения)
          if (val > 0) expire = DateTime.fromMillisecondsSinceEpoch(val * 1000);
          break;
      }
    }

    // Имя пользователя из profile-title или content-disposition
    String? username;
    final cd = headers['profile-title'] ??
        headers['content-disposition'] ??
        headers['x-profile-title'] ?? '';
    if (cd.isNotEmpty) {
      try {
        // Может быть base64
        username = utf8.decode(base64.decode(cd));
      } catch (_) {
        username = cd;
      }
    }

    final used = (upload ?? 0) + (download ?? 0);
    return _UserInfo(
      username: username?.isNotEmpty == true ? username : null,
      trafficUsed: used > 0 ? used : null,
      // total=0 → безлимит → null (не показывать прогресс-бар)
      trafficTotal: (total != null && total > 0) ? total : null,
      expireDate: expire,
    );
  }

  String _extractName(Map<String, String> headers, String url) {
    final cd = headers['content-disposition'] ?? '';
    final match = RegExp(r'filename="?([^";]+)"?').firstMatch(cd);
    if (match != null) return match.group(1)!;
    try {
      final uri = Uri.parse(url);
      final seg = uri.pathSegments.lastWhere((s) => s.isNotEmpty,
          orElse: () => 'Подписка');
      return seg.length > 30 ? 'Подписка' : seg;
    } catch (_) {
      return 'Подписка';
    }
  }
}

class _UserInfo {
  final String? username;
  final int? trafficUsed;
  final int? trafficTotal;
  final DateTime? expireDate;
  const _UserInfo({this.username, this.trafficUsed, this.trafficTotal, this.expireDate});
}
