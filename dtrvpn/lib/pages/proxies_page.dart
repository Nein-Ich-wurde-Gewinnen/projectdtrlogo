import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../models/proxy_node.dart';
import '../models/profile.dart';
import '../models/vpn_state.dart';
import '../services/storage_service.dart';
import '../services/mihomo_service.dart';
import '../services/settings_service.dart';
import '../services/dtr_log.dart';
import 'package:yaml/yaml.dart';

// top-level для compute()
List<ProxyNode> _parseNodesBackground(String yaml) {
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
        if (provider is YamlMap &&
            provider['type']?.toString().toLowerCase() == 'inline') {
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
  } catch (_) { return []; }
}

// Цвета задержки (из FlClash)
Color _delayColor(int? ms, BuildContext context) {
  if (ms == null) return Theme.of(context).colorScheme.onSurfaceVariant;
  if (ms < 0)     return Colors.red;
  if (ms < 600)   return const Color(0xFF2E7D32);
  if (ms <= 1200) return const Color(0xFFC57F0A);
  return Colors.red;
}

class ProxiesPage extends StatefulWidget {
  const ProxiesPage({super.key});
  @override
  State<ProxiesPage> createState() => _ProxiesPageState();
}

class _ProxiesPageState extends State<ProxiesPage>
    with AutomaticKeepAliveClientMixin {
  static const _tag = 'ProxiesPage';

  final _storage  = StorageService.instance;
  final _mihomo   = MihomoService.instance;
  final _settings = SettingsService.instance;

  Profile? _activeProfile;
  List<ProxyNode> _nodes = [];
  bool _loading = false;
  final Set<String> _testingNodes = {};
  ProxyNode? _selectedNode;

  StreamSubscription<VpnState>?    _stateSub;
  StreamSubscription<TrafficStats>? _trafficSub;
  TrafficStats _traffic = const TrafficStats();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    DtrLog.i(_tag, 'initState()');
    _loadNodes();
    _stateSub = _mihomo.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
    _trafficSub = _mihomo.trafficStream.listen((t) {
      if (mounted) setState(() => _traffic = t);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _trafficSub?.cancel();
    super.dispose();
  }

  Future<void> _loadNodes() async {
    if (!mounted) return;
    DtrLog.i(_tag, '_loadNodes()');
    setState(() => _loading = true);
    try {
      final profile = await _storage.getActiveProfile();
      if (!mounted) return;
      _activeProfile = profile;
      if (profile?.rawConfig != null) {
        DtrLog.d(_tag, 'parsing config, len=${profile!.rawConfig!.length}');
        final nodes = await compute(_parseNodesBackground, profile.rawConfig!);
        DtrLog.i(_tag, 'loaded ${nodes.length} nodes');
        if (mounted) setState(() { _nodes = nodes; _loading = false; });
      } else {
        DtrLog.w(_tag, 'no active profile or no rawConfig');
        if (mounted) setState(() { _nodes = []; _loading = false; });
      }
    } catch (e, st) {
      DtrLog.ex(_tag, '_loadNodes error', e, st);
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectNode(ProxyNode node) {
    setState(() {
      _selectedNode = _selectedNode?.name == node.name ? null : node;
    });
    DtrLog.d(_tag, 'selected: ${_selectedNode?.name ?? "none"}');
  }

  Future<void> _connectSelected() async {
    final node = _selectedNode;
    if (node == null) return;
    if (_activeProfile?.rawConfig == null) {
      _showSnack('Сначала выберите профиль во вкладке Профили', isError: true);
      return;
    }
    final vpnState = _mihomo.currentState;
    if (vpnState.isConnected && vpnState.activeNode?.name == node.name) {
      DtrLog.i(_tag, 'disconnect requested for "${node.name}"');
      await _mihomo.disconnect();
    } else {
      DtrLog.i(_tag, 'connect requested for "${node.name}" [${node.typeLabel}]');
      final ok = await _mihomo.connect(node, _activeProfile!.rawConfig!);
      if (!ok && mounted) _showSnack('Ошибка подключения — см. логи', isError: true);
    }
  }

  Future<void> _testDelay(ProxyNode node) async {
    if (_testingNodes.contains(node.name)) return; // уже тестируется
    DtrLog.d(_tag, 'testDelay "${node.name}" url=${_settings.pingUrl}');
    setState(() => _testingNodes.add(node.name));
    final ms = await _mihomo.testDelay(node.name, testUrl: _settings.pingUrl);
    final idx = _nodes.indexWhere((n) => n.name == node.name);
    if (idx != -1 && mounted) {
      setState(() {
        _nodes[idx].latencyMs = ms;
        _testingNodes.remove(node.name);
      });
    }
    DtrLog.i(_tag, 'testDelay "${node.name}" → ${ms}ms');
  }

  // Параллельный пинг всех серверов с лимитом concurrency=10 (из FlClashX)
  Future<void> _testAllDelays() async {
    if (_nodes.isEmpty) return;
    DtrLog.i(_tag, 'testAllDelays: ${_nodes.length} nodes, concurrency=10');

    const batchSize = 10;
    final nodes = List<ProxyNode>.from(_nodes);

    for (int i = 0; i < nodes.length; i += batchSize) {
      final batch = nodes.skip(i).take(batchSize).toList();
      DtrLog.d(_tag, 'Ping batch ${i ~/ batchSize + 1}: ${batch.map((n) => n.name).join(", ")}');
      await Future.wait(batch.map(_testDelay));
    }
    DtrLog.i(_tag, 'testAllDelays: complete');
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final vpnState = _mihomo.currentState;
    final isSelectedConnected = vpnState.isConnected &&
        vpnState.activeNode?.name == _selectedNode?.name;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Прокси'),
        centerTitle: false,
        actions: [
          if (_nodes.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.timer_outlined),
              tooltip: 'Замерить все',
              onPressed: _testAllDelays,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить список',
            onPressed: _loadNodes,
          ),
        ],
      ),
      body: Column(
        children: [
          // VPN статус + трафик
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, anim) => SizeTransition(
              sizeFactor: anim,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: _VpnStatusBar(
              key: ValueKey(vpnState.status),
              state: vpnState,
              traffic: _traffic,
              onDisconnect: _mihomo.disconnect,
            ),
          ),
          // Поиск УБРАН по запросу (жёлтая стрелка на скриншоте)
          Expanded(child: _buildList(context, vpnState)),
        ],
      ),
      floatingActionButton: AnimatedScale(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutBack,
        scale: _selectedNode != null ? 1.0 : 0.0,
        child: FloatingActionButton.extended(
          onPressed: _connectSelected,
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Icon(
              isSelectedConnected ? Icons.stop_rounded : Icons.play_arrow_rounded,
              key: ValueKey(isSelectedConnected),
            ),
          ),
          label: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              isSelectedConnected ? 'Отключить' : 'Подключить',
              key: ValueKey(isSelectedConnected),
            ),
          ),
          backgroundColor: isSelectedConnected
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
          foregroundColor: isSelectedConnected
              ? Theme.of(context).colorScheme.onError
              : Theme.of(context).colorScheme.onPrimary,
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, VpnState vpnState) {
    if (_loading) return _buildSkeleton(context);

    if (_activeProfile == null) {
      return _buildHint(context,
          icon: Icons.folder_off_outlined,
          title: 'Нет активного профиля',
          subtitle: 'Перейди во вкладку Профили и активируй подписку');
    }
    if (_nodes.isEmpty) {
      return _buildHint(context,
          icon: Icons.cloud_off_outlined,
          title: 'Серверы не загружены',
          subtitle: 'Обнови профиль во вкладке Профили');
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
      itemCount: _nodes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (ctx, i) {
        final node = _nodes[i];
        final isActive   = vpnState.isConnected && vpnState.activeNode?.name == node.name;
        final isSelected = _selectedNode?.name == node.name;
        return RepaintBoundary(
          child: _ProxyCard(
            key: ValueKey(node.name),
            node: node,
            isActive: isActive,
            isSelected: isSelected,
            isTesting: _testingNodes.contains(node.name),
            isConnecting: vpnState.isConnecting &&
                vpnState.activeNode?.name == node.name,
            onTap: () => _selectNode(node),
            onTestDelay: () => _testDelay(node),
          ),
        );
      },
    );
  }

  Widget _buildSkeleton(BuildContext context) {
    final base  = Theme.of(context).colorScheme.surfaceContainerHighest;
    final shine = Theme.of(context).colorScheme.surface;
    return Shimmer.fromColors(
      baseColor: base,
      highlightColor: shine,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: 8,
        separatorBuilder: (_, __) => const SizedBox(height: 4),
        itemBuilder: (_, __) => Container(
          height: 64,
          decoration: BoxDecoration(
            color: base,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }

  Widget _buildHint(BuildContext context,
      {required IconData icon, required String title, required String subtitle}) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 72, color: cs.onSurface.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.5)),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.4)),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

// ── VPN Status Bar с трафик-счётчиком ─────────────────────────────────────

class _VpnStatusBar extends StatelessWidget {
  const _VpnStatusBar({
    super.key,
    required this.state,
    required this.traffic,
    required this.onDisconnect,
  });

  final VpnState state;
  final TrafficStats traffic;
  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    switch (state.status) {
      case VpnStatus.disconnected:
        return const SizedBox.shrink();

      case VpnStatus.connecting:
        return _bar(
          color: scheme.primaryContainer,
          fg:    scheme.onPrimaryContainer,
          child: Row(children: [
            const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            const Expanded(child: Text('Подключение...',
                style: TextStyle(fontWeight: FontWeight.w500))),
          ]),
        );

      case VpnStatus.connected:
        return _bar(
          color: const Color(0xFF1B5E20),
          fg:    Colors.white,
          child: Row(children: [
            const Icon(Icons.shield, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    state.activeNode?.name ?? 'Подключено',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600,
                        fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '↑ ${traffic.upFormatted}  ↓ ${traffic.downFormatted}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onDisconnect,
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              child: const Text('Стоп'),
            ),
          ]),
        );

      case VpnStatus.error:
        return _bar(
          color: scheme.errorContainer,
          fg:    scheme.onErrorContainer,
          child: Row(children: [
            Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(child: Text(
              state.errorMessage ?? 'Ошибка',
              style: TextStyle(color: scheme.onErrorContainer,
                  fontWeight: FontWeight.w500),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            )),
          ]),
        );
    }
  }

  Widget _bar({required Color color, required Color fg, required Widget child}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: DefaultTextStyle(style: TextStyle(color: fg), child: child),
    );
  }
}

// ── Proxy Card ──────────────────────────────────────────────────────────────

class _ProxyCard extends StatelessWidget {
  const _ProxyCard({
    super.key,
    required this.node,
    required this.isActive,
    required this.isSelected,
    required this.isTesting,
    required this.isConnecting,
    required this.onTap,
    required this.onTestDelay,
  });

  final ProxyNode node;
  final bool isActive, isSelected, isTesting, isConnecting;
  final VoidCallback onTap, onTestDelay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final cardColor = isActive
        ? const Color(0xFF2E7D32).withValues(alpha: 0.12)
        : isSelected
            ? scheme.primaryContainer.withValues(alpha: 0.7)
            : scheme.surfaceContainerHighest;

    final borderColor = isActive
        ? const Color(0xFF2E7D32)
        : isSelected
            ? scheme.primary
            : Colors.transparent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: borderColor, width: (isActive || isSelected) ? 1.5 : 0),
        boxShadow: (isActive || isSelected)
            ? [BoxShadow(
                color: borderColor.withValues(alpha: 0.2),
                blurRadius: 8, offset: const Offset(0, 2))]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: [
                // Тип протокола
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    color: isActive
                        ? const Color(0xFF2E7D32).withValues(alpha: 0.2)
                        : isSelected
                            ? scheme.primary.withValues(alpha: 0.15)
                            : scheme.surface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(node.typeLabel,
                        style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            color: isActive
                                ? const Color(0xFF2E7D32)
                                : scheme.primary)),
                  ),
                ),
                const SizedBox(width: 12),
                // Имя и сервер
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(node.name,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      Text('${node.server}:${node.port}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Индикаторы состояния
                if (isConnecting)
                  const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else if (isActive)
                  const Icon(Icons.check_circle, color: Color(0xFF2E7D32), size: 22)
                else if (isSelected)
                  Icon(Icons.radio_button_checked, color: scheme.primary, size: 22)
                else
                  GestureDetector(
                    onTap: onTestDelay,
                    child: isTesting
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : _LatencyBadge(node: node),
                  ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LatencyBadge extends StatelessWidget {
  const _LatencyBadge({required this.node});
  final ProxyNode node;

  @override
  Widget build(BuildContext context) {
    if (node.latencyMs == null) {
      return Icon(Icons.timer_outlined, size: 18,
          color: Theme.of(context)
              .colorScheme
              .onSurfaceVariant
              .withValues(alpha: 0.5));
    }
    final color = _delayColor(node.latencyMs, context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8)),
      child: Text(node.latencyLabel,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}
