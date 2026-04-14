import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';
import '../models/proxy_node.dart';
import 'dtr_log.dart';

// Парсинг прокси в фоновом изоляте
List<ProxyNode> _parseProxiesBackground(String yaml) {
  try {
    final doc = loadYaml(yaml);
    if (doc is! YamlMap) return [];
    final all = <ProxyNode>[];
    final proxies = doc['proxies'];
    if (proxies is YamlList) {
      all.addAll(proxies.whereType<YamlMap>().map((m) {
        try { return ProxyNode.fromClashMap(m); } catch (_) { return null; }
      }).whereType<ProxyNode>());
    }
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
  final String? supportUrl;
  final String? announceMsg;
  final int? updateIntervalHours;

  const SubInfo({
    required this.raw,
    required this.nodes,
    required this.name,
    this.username,
    this.trafficUsed,
    this.trafficTotal,
    this.expireDate,
    this.supportUrl,
    this.announceMsg,
    this.updateIntervalHours,
  });
}

class SubscriptionService {
  static const _tag = 'SubSvc';
  static const _timeoutSecs = 20;
  static const _maxRetries  = 3;

  /// Загрузка и парсинг подписки с retry-логикой (FlClashX approach).
  ///
  /// Использует dart:io HttpClient напрямую (не http-пакет) для:
  ///   - отключения проверки плохих SSL-сертификатов (badCertificateCallback)
  ///   - правильного User-Agent для серверов Remnawave/Mihomo
  ///   - retry с exponential backoff при сетевых ошибках
  Future<SubInfo> fetchSubscription(String url) async {
    DtrLog.i(_tag, '══ fetchSubscription ══');
    DtrLog.i(_tag, '  url = $url');

    Exception? lastError;

    for (int attempt = 1; attempt <= _maxRetries; attempt++) {
      if (attempt > 1) {
        final waitSecs = attempt * 2;
        DtrLog.w(_tag, 'Retry $attempt/$_maxRetries — waiting ${waitSecs}s');
        await Future.delayed(Duration(seconds: waitSecs));
      }

      try {
        DtrLog.d(_tag, '[attempt $attempt] creating HttpClient');
        final client = HttpClient()
          // Bypass SSL cert errors (same as FlClashX FlClashHttpOverrides)
          ..badCertificateCallback = (cert, host, port) {
            DtrLog.w(_tag, 'Bad cert for $host:$port (SubjectDN: ${cert.subject}) — bypassing');
            return true;
          }
          ..connectionTimeout = const Duration(seconds: _timeoutSecs)
          ..idleTimeout = const Duration(seconds: _timeoutSecs);

        late HttpClientResponse response;
        try {
          DtrLog.d(_tag, '[attempt $attempt] HTTP GET $url');
          final request = await client.getUrl(Uri.parse(url));
          request.headers.set(HttpHeaders.userAgentHeader, 'clash.meta');
          request.headers.set(HttpHeaders.acceptHeader, '*/*');
          request.headers.set(HttpHeaders.connectionHeader, 'close');
          response = await request.close()
              .timeout(const Duration(seconds: _timeoutSecs));
        } catch (e) {
          client.close(force: true);
          DtrLog.e(_tag, '[attempt $attempt] connection error: $e');
          lastError = Exception('Ошибка подключения к серверу: $e');
          continue; // retry
        }

        DtrLog.i(_tag, '[attempt $attempt] HTTP ${response.statusCode}');

        // Логируем все заголовки ответа
        if (kDebugMode) {
          DtrLog.d(_tag, 'Response headers:');
          response.headers.forEach((name, values) {
            DtrLog.d(_tag, '  $name: ${values.join(", ")}');
          });
        }

        if (response.statusCode != 200) {
          client.close(force: true);
          DtrLog.e(_tag, 'HTTP error ${response.statusCode}');
          lastError = Exception('HTTP ${response.statusCode}');
          // 4xx — не ретраить, только сетевые ошибки
          if (response.statusCode >= 400 && response.statusCode < 500) break;
          continue;
        }

        // Читаем тело
        final bytes = await response.expand((chunk) => chunk).toList()
            .timeout(const Duration(seconds: _timeoutSecs));
        client.close();

        String body = utf8.decode(bytes, allowMalformed: true);
        DtrLog.d(_tag, 'body: ${body.length} chars');

        // Пробуем base64
        try {
          final decoded = utf8.decode(base64.decode(body.trim()));
          if (decoded.contains('proxies:') || decoded.contains('Proxy:') ||
              decoded.contains('proxy-providers:')) {
            body = decoded;
            DtrLog.i(_tag, 'body decoded from base64');
          }
        } catch (_) {
          DtrLog.d(_tag, 'body is not base64');
        }

        // Парсим заголовки
        final userInfo  = _parseUserInfo(response.headers);
        final subName   = _extractName(response.headers, url);
        final extraHdrs = _parseProviderHeaders(response.headers);

        DtrLog.i(_tag, 'Profile name: "$subName"');
        DtrLog.i(_tag, 'Traffic: used=${userInfo.trafficUsed} total=${userInfo.trafficTotal}');
        DtrLog.i(_tag, 'Expire: ${userInfo.expireDate}');
        if (extraHdrs.supportUrl != null)
          DtrLog.i(_tag, 'support-url: ${extraHdrs.supportUrl}');
        if (extraHdrs.announceMsg != null)
          DtrLog.i(_tag, 'announce: ${extraHdrs.announceMsg}');
        if (extraHdrs.updateIntervalHours != null)
          DtrLog.i(_tag, 'update-interval: ${extraHdrs.updateIntervalHours}h');

        // Парсим прокси в фоновом изоляте
        final nodes = await compute(_parseProxiesBackground, body);
        DtrLog.i(_tag, 'Parsed ${nodes.length} proxy nodes');

        if (nodes.isEmpty) {
          DtrLog.w(_tag, 'WARNING: no proxy nodes found!');
          DtrLog.w(_tag, 'YAML top-level keys: ${_getYamlKeys(body)}');
          DtrLog.d(_tag, 'Body preview: ${body.take(300)}');
        }

        return SubInfo(
          raw:                 body,
          nodes:               nodes,
          name:                subName,
          username:            userInfo.username,
          trafficUsed:         userInfo.trafficUsed,
          trafficTotal:        userInfo.trafficTotal,
          expireDate:          userInfo.expireDate,
          supportUrl:          extraHdrs.supportUrl,
          announceMsg:         extraHdrs.announceMsg,
          updateIntervalHours: extraHdrs.updateIntervalHours,
        );

      } catch (e, st) {
        DtrLog.ex(_tag, '[attempt $attempt] unexpected error', e, st);
        lastError = Exception('$e');
      }
    }

    // Все попытки исчерпаны
    DtrLog.e(_tag, 'fetchSubscription FAILED after $_maxRetries attempts: $lastError');
    throw lastError ?? Exception('Unknown error fetching subscription');
  }

  _UserInfo _parseUserInfo(HttpHeaders headers) {
    final raw = headers.value('subscription-userinfo') ?? '';
    DtrLog.d(_tag, 'subscription-userinfo: "${raw.isEmpty ? "(empty)" : raw}"');

    int? upload, download, total;
    DateTime? expire;

    for (final part in raw.split(';')) {
      final kv = part.trim().split('=');
      if (kv.length != 2) continue;
      final key = kv[0].trim();
      final val = int.tryParse(kv[1].trim());
      if (val == null) continue;
      switch (key) {
        case 'upload':   upload   = val; break;
        case 'download': download = val; break;
        case 'total':    total    = val; break;
        case 'expire':
          if (val > 0) {
            expire = DateTime.fromMillisecondsSinceEpoch(val * 1000);
            DtrLog.d(_tag, 'expire raw=$val → ${expire.toLocal()}');
          } else {
            DtrLog.d(_tag, 'expire=0 → permanent subscription');
          }
          break;
      }
    }

    String? username;
    final titleHeader = headers.value('profile-title') ??
                        headers.value('content-disposition') ??
                        headers.value('x-profile-title') ?? '';
    if (titleHeader.isNotEmpty) {
      try { username = utf8.decode(base64.decode(titleHeader)); }
      catch (_) { username = titleHeader; }
      DtrLog.d(_tag, 'username: "$username"');
    }

    final used = (upload ?? 0) + (download ?? 0);
    return _UserInfo(
      username:     username?.isNotEmpty == true ? username : null,
      trafficUsed:  used > 0 ? used : null,
      trafficTotal: (total != null && total > 0) ? total : null, // 0 = unlimited
      expireDate:   expire,
    );
  }

  _ProviderHeaders _parseProviderHeaders(HttpHeaders headers) {
    final supportUrl   = headers.value('support-url');
    final announceMsg  = headers.value('announce');
    final intervalStr  = headers.value('profile-update-interval');
    int? updateIntervalHours;
    if (intervalStr != null) {
      updateIntervalHours = int.tryParse(intervalStr);
      DtrLog.d(_tag, 'profile-update-interval: $updateIntervalHours h');
    }
    return _ProviderHeaders(
      supportUrl:          supportUrl?.isNotEmpty == true ? supportUrl : null,
      announceMsg:         announceMsg?.isNotEmpty == true ? announceMsg : null,
      updateIntervalHours: updateIntervalHours,
    );
  }

  String _extractName(HttpHeaders headers, String url) {
    // 1) content-disposition: attachment; filename="..."
    final cd = headers.value('content-disposition') ?? '';
    final match = RegExp(r'filename="?([^";]+)"?').firstMatch(cd);
    if (match != null) return match.group(1)!;
    // 2) Last path segment
    try {
      final uri = Uri.parse(url);
      final seg = uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
      if (seg.isNotEmpty && seg.length <= 40) return seg;
    } catch (_) {}
    return 'Подписка';
  }

  String _getYamlKeys(String yaml) {
    try {
      final doc = loadYaml(yaml);
      if (doc is YamlMap) return doc.keys.toList().toString();
    } catch (_) {}
    return '(не YAML)';
  }
}

extension on String {
  String take(int n) => length <= n ? this : substring(0, n);
}

class _UserInfo {
  final String? username;
  final int? trafficUsed;
  final int? trafficTotal;
  final DateTime? expireDate;
  const _UserInfo({this.username, this.trafficUsed, this.trafficTotal, this.expireDate});
}

class _ProviderHeaders {
  final String? supportUrl;
  final String? announceMsg;
  final int? updateIntervalHours;
  const _ProviderHeaders({this.supportUrl, this.announceMsg, this.updateIntervalHours});
}
