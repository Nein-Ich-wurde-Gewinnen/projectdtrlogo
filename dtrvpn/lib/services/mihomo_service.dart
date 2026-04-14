import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';
import '../models/proxy_node.dart';
import '../models/vpn_state.dart';
import 'dtr_log.dart';

class MihomoService {
  static MihomoService? _instance;
  MihomoService._();
  static MihomoService get instance => _instance ??= MihomoService._();

  static const _tag = 'Mihomo';

  static const _channel         = MethodChannel('online.dtr.vpn/mihomo');
  static const _stateChannel    = EventChannel('online.dtr.vpn/vpn_state');
  static const _trafficChannel  = EventChannel('online.dtr.vpn/traffic');
  static const _mihomoLogChannel = EventChannel('online.dtr.vpn/mihomo_log'); // ← NEW

  final _stateController    = StreamController<VpnState>.broadcast();
  final _trafficController  = StreamController<TrafficStats>.broadcast();
  final _mihomoLogController = StreamController<List<MihomoLogEntry>>.broadcast(); // ← NEW

  VpnState _currentState = const VpnState();

  VpnState              get currentState    => _currentState;
  Stream<VpnState>      get stateStream     => _stateController.stream;
  Stream<TrafficStats>  get trafficStream   => _trafficController.stream;
  Stream<List<MihomoLogEntry>> get mihomoLogStream => _mihomoLogController.stream; // ← NEW

  void init() {
    DtrLog.i(_tag, 'init() — подписываемся на каналы');

    _stateChannel.receiveBroadcastStream().listen((event) {
      _handleStateEvent(Map<String, dynamic>.from(event));
    }, onError: (e) => DtrLog.e(_tag, 'stateChannel error: $e'));

    _trafficChannel.receiveBroadcastStream().listen((event) {
      _handleTrafficEvent(event as String);
    }, onError: (e) => DtrLog.e(_tag, 'trafficChannel error: $e'));

    // ← NEW: Mihomo internal log stream (DNS queries, rule matching, etc.)
    _mihomoLogChannel.receiveBroadcastStream().listen((event) {
      _handleMihomoLogEvent(event as String);
    }, onError: (e) => DtrLog.e(_tag, 'mihomoLogChannel error: $e'));
  }

  void _handleStateEvent(Map<String, dynamic> event) {
    final rawStatus = event['status'] as String? ?? '?';
    final error     = event['error']  as String?;
    DtrLog.d(_tag, 'stateEvent status=$rawStatus${error != null ? " error=$error" : ""}');

    final status = switch (rawStatus) {
      'connected'       => VpnStatus.connected,
      'connecting'      => VpnStatus.connecting,
      'disconnected'    => VpnStatus.disconnected,
      'error'           => VpnStatus.error,
      'network_changed' => _currentState.status,
      _                 => VpnStatus.disconnected,
    };

    _currentState = _currentState.copyWith(status: status, errorMessage: error);
    _stateController.add(_currentState);
  }

  void _handleTrafficEvent(String json) {
    try {
      final map   = jsonDecode(json) as Map<String, dynamic>;
      final stats = TrafficStats(
        upBytes:   (map['up']   as num?)?.toInt() ?? 0,
        downBytes: (map['down'] as num?)?.toInt() ?? 0,
      );
      _currentState = _currentState.copyWith(traffic: stats);
      _trafficController.add(stats);
    } catch (e) {
      DtrLog.w(_tag, 'trafficEvent parse error: $e');
    }
  }

  // ← NEW: parse Mihomo log batch from Go ring-buffer drain
  void _handleMihomoLogEvent(String json) {
    try {
      final list = jsonDecode(json) as List<dynamic>;
      final entries = <MihomoLogEntry>[];
      for (final item in list) {
        try {
          final parsed = jsonDecode(item as String) as Map<String, dynamic>;
          final entry = MihomoLogEntry(
            level:   parsed['level']   as String? ?? 'info',
            payload: parsed['payload'] as String? ?? '',
            time:    parsed['time']    as String? ?? '',
          );
          entries.add(entry);
          // Also forward to DtrLog so they appear in the logs page
          if (kDebugMode) {
            DtrLog.d('Mihomo-Core', '[${entry.level.toUpperCase()}] ${entry.payload}');
          }
        } catch (_) {}
      }
      if (entries.isNotEmpty) {
        _mihomoLogController.add(entries);
      }
    } catch (e) {
      DtrLog.w(_tag, 'mihomoLogEvent parse error: $e  raw=$json');
    }
  }

  // ── connect ────────────────────────────────────────────────────────────────

  Future<bool> connect(ProxyNode node, String fullConfig, {bool enableIpv6 = false}) async {
    DtrLog.i(_tag, '── connect() ── "${node.name}" [${node.typeLabel}] ${node.server}:${node.port}');
    DtrLog.d(_tag, 'rawConfig ${fullConfig.length} chars');

    String builtConfig;
    try {
      builtConfig = _buildConfig(fullConfig, node.name);
    } catch (e, st) {
      DtrLog.ex(_tag, '_buildConfig FAILED', e, st);
      _currentState = _currentState.copyWith(status: VpnStatus.error, errorMessage: e.toString());
      _stateController.add(_currentState);
      return false;
    }

    _currentState = _currentState.copyWith(status: VpnStatus.connecting, activeNode: node);
    _stateController.add(_currentState);

    try {
      final result = await _channel.invokeMethod<bool>('connect', {
        'config':     builtConfig,
        'proxyName':  node.name,
        'enableIpv6': enableIpv6,
      });
      DtrLog.i(_tag, 'connect() result=$result');
      return result ?? false;
    } on PlatformException catch (e) {
      DtrLog.e(_tag, 'connect() PlatformException: code=${e.code} msg=${e.message}');
      _currentState = _currentState.copyWith(status: VpnStatus.error, errorMessage: e.message);
      _stateController.add(_currentState);
      return false;
    } catch (e, st) {
      DtrLog.ex(_tag, 'connect() unexpected error', e, st);
      _currentState = _currentState.copyWith(status: VpnStatus.error, errorMessage: e.toString());
      _stateController.add(_currentState);
      return false;
    }
  }

  Future<void> disconnect() async {
    DtrLog.i(_tag, 'disconnect()');
    try { await _channel.invokeMethod('disconnect'); }
    on PlatformException catch (e) { DtrLog.w(_tag, 'disconnect() error: ${e.message}'); }
  }

  Future<bool> isRunning() async {
    try {
      final r = await _channel.invokeMethod<bool>('isRunning') ?? false;
      DtrLog.d(_tag, 'isRunning()=$r');
      return r;
    } catch (e) { DtrLog.w(_tag, 'isRunning() error: $e'); return false; }
  }

  Future<void> selectProxy(String groupName, String proxyName) async {
    DtrLog.d(_tag, 'selectProxy group="$groupName" proxy="$proxyName"');
    try {
      await _channel.invokeMethod('selectProxy', {'group': groupName, 'proxy': proxyName});
    } on PlatformException catch (e) { DtrLog.w(_tag, 'selectProxy() error: ${e.message}'); }
  }

  Future<int> testDelay(String proxyName, {String testUrl = 'https://www.gstatic.com/generate_204'}) async {
    DtrLog.d(_tag, 'testDelay "$proxyName" url=$testUrl');
    try {
      final ms = await _channel.invokeMethod<int>('testDelay', {
        'proxy': proxyName, 'url': testUrl, 'timeout': 3000,
      });
      final result = ms ?? -1;
      if (result < 0) {
        DtrLog.w(_tag, 'testDelay "$proxyName" → TIMEOUT. VPN должен быть подключён!');
      } else {
        DtrLog.i(_tag, 'testDelay "$proxyName" → ${result}ms');
      }
      return result;
    } catch (e) {
      DtrLog.e(_tag, 'testDelay "$proxyName" exception: $e');
      return -1;
    }
  }

  // ← NEW: pre-validate config string (calls Go ValidateConfig via Kotlin)
  Future<String> validateConfig(String config) async {
    try {
      final err = await _channel.invokeMethod<String>('validateConfig', {'config': config});
      return err ?? '';
    } catch (e) {
      DtrLog.w(_tag, 'validateConfig error: $e');
      return '';
    }
  }

  Future<TrafficStats> getTraffic() async {
    try {
      final json = await _channel.invokeMethod<String>('getTraffic') ?? '{}';
      final map  = jsonDecode(json) as Map<String, dynamic>;
      return TrafficStats(upBytes: (map['up'] as num?)?.toInt() ?? 0,
                          downBytes: (map['down'] as num?)?.toInt() ?? 0);
    } catch (e) { DtrLog.w(_tag, 'getTraffic() error: $e'); return const TrafficStats(); }
  }

  Future<TrafficStats> getTotalTraffic() async {
    try {
      final json = await _channel.invokeMethod<String>('getTotalTraffic') ?? '{}';
      final map  = jsonDecode(json) as Map<String, dynamic>;
      return TrafficStats(upBytes: (map['up'] as num?)?.toInt() ?? 0,
                          downBytes: (map['down'] as num?)?.toInt() ?? 0);
    } catch (e) { DtrLog.w(_tag, 'getTotalTraffic() error: $e'); return const TrafficStats(); }
  }

  Future<void> forceGC() async {
    DtrLog.d(_tag, 'forceGC()');
    try { await _channel.invokeMethod('forceGC'); } catch (_) {}
  }

  // ── _buildConfig ───────────────────────────────────────────────────────────

  String _buildConfig(String yamlStr, String selectedProxy) {
    DtrLog.d(_tag, '_buildConfig для "$selectedProxy"');

    dynamic doc;
    try {
      doc = loadYaml(yamlStr);
    } catch (e) {
      DtrLog.e(_tag, '_buildConfig: loadYaml failed: $e');
      throw 'Не удалось прочитать конфиг: $e';
    }

    if (doc is! YamlMap) {
      DtrLog.e(_tag, '_buildConfig: doc is ${doc.runtimeType}, expected YamlMap');
      throw 'Конфиг не является YAML-словарём';
    }

    DtrLog.d(_tag, '_buildConfig: top-level keys = ${doc.keys.toList()}');

    final allProxies = <Map<String, dynamic>>[];

    final proxiesNode = doc['proxies'];
    if (proxiesNode is YamlList) {
      int n = 0;
      for (final item in proxiesNode) {
        if (item is YamlMap) { allProxies.add(_deepConvert(item) as Map<String, dynamic>); n++; }
      }
      DtrLog.i(_tag, '_buildConfig: proxies[] → $n прокси');
    } else {
      DtrLog.d(_tag, '_buildConfig: нет "proxies" (${proxiesNode?.runtimeType})');
    }

    final providersNode = doc['proxy-providers'];
    if (providersNode is YamlMap) {
      DtrLog.d(_tag, '_buildConfig: proxy-providers keys=${providersNode.keys.toList()}');
      for (final entry in providersNode.entries) {
        final provider = entry.value;
        if (provider is! YamlMap) continue;
        final ptype = provider['type']?.toString().toLowerCase() ?? '';
        if (ptype != 'inline') {
          DtrLog.w(_tag, '_buildConfig: provider "${entry.key}" type=$ptype — не inline, пропускаем');
          continue;
        }
        final pp = provider['proxies'];
        if (pp is! YamlList) { DtrLog.w(_tag, '_buildConfig: provider "${entry.key}" без proxies'); continue; }
        int n = 0;
        for (final item in pp) {
          if (item is YamlMap) { allProxies.add(_deepConvert(item) as Map<String, dynamic>); n++; }
        }
        DtrLog.i(_tag, '_buildConfig: provider "${entry.key}" inline → $n прокси');
      }
    }

    DtrLog.i(_tag, '_buildConfig: итого ${allProxies.length} прокси');

    if (allProxies.isEmpty) {
      DtrLog.e(_tag, '_buildConfig: нет ни одного прокси!');
      throw 'Прокси не найдены (proxies и proxy-providers пусты)';
    }

    final proxyNames = allProxies.map((p) => p['name']?.toString() ?? '').toSet();
    if (!proxyNames.contains(selectedProxy)) {
      DtrLog.e(_tag, '_buildConfig: "$selectedProxy" не найден среди ${proxyNames.length} прокси');
      throw 'Прокси "$selectedProxy" не найден в конфиге';
    }

    final config = <String, dynamic>{
      'mixed-port': 7890, 'allow-lan': false, 'mode': 'rule', 'log-level': 'info',
      // DNS config for fake-ip — required for domain resolution through TUN.
      // Placed here (not in Kotlin injectTunConfig) because Kotlin no longer
      // injects TUN/DNS: TUN is started separately via startTun() JNI call.
      'dns': {
        'enable': true,
        'enhanced-mode': 'fake-ip',
        'listen': '0.0.0.0:1053',
        'fake-ip-range': '198.18.0.1/16',
        'nameserver': ['1.1.1.1', '8.8.8.8'],
      },
      'proxies': allProxies,
      'proxy-groups': [{'name': 'PROXY', 'type': 'select', 'proxies': [selectedProxy]}],
      'rules': ['MATCH,PROXY'],
    };

    try {
      final encoded = jsonEncode(config);
      DtrLog.i(_tag, '_buildConfig OK — ${encoded.length} chars');
      return encoded;
    } catch (e) {
      DtrLog.ex(_tag, '_buildConfig jsonEncode failed', e);
      throw 'Ошибка сериализации конфига: $e';
    }
  }

  static dynamic _deepConvert(dynamic value) {
    if (value is YamlMap) {
      return {for (final e in value.entries) if (e.key != null) e.key.toString(): _deepConvert(e.value)};
    }
    if (value is YamlList) return [for (final item in value) _deepConvert(item)];
    return value;
  }

  void dispose() {
    DtrLog.i(_tag, 'dispose()');
    _stateController.close();
    _trafficController.close();
    _mihomoLogController.close();
  }
}

// ── MihomoLogEntry ─────────────────────────────────────────────────────────

/// Single log entry from Mihomo Go core (DNS, rule matching, proxy selection, etc.)
class MihomoLogEntry {
  final String level;    // debug / info / warning / error / silent
  final String payload;
  final String time;

  const MihomoLogEntry({
    required this.level,
    required this.payload,
    required this.time,
  });
}
