import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/proxy_node.dart';
import '../models/profile.dart';
import '../models/vpn_state.dart';
import '../services/storage_service.dart';
import '../services/mihomo_service.dart';
import '../services/settings_service.dart';
import 'package:yaml/yaml.dart';

// Top-level для compute()
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

class ProxiesPage extends StatefulWidget {
  const ProxiesPage({super.key});
  @override
  State<ProxiesPage> createState() => _ProxiesPageState();
}

class _ProxiesPageState extends State<ProxiesPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _storage = StorageService.instance;
  final _mihomo = MihomoService.instance;
  final _settings = SettingsService.instance;

  Profile? _activeProfile;
  List<ProxyNode> _nodes = [];
  bool _loading = false;
  final Set<String> _testingNodes = {};

  ProxyNode? _selectedNode;

  StreamSubscription<VpnState>? _stateSub;

  @override
  void initState() {
    super.initState();
    _loadNodes();
    _stateSub = _mihomo.stateStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  Future<void> _loadNodes() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final profile = await _storage.getActiveProfile();
      if (!mounted) return;
      _activeProfile = profile;
      if (profile?.rawConfig != null) {
        final nodes = await compute(_parseNodesBackground, profile!.rawConfig!);
        if (mounted) {
          setState(() {
            _nodes = nodes;
            _loading = false;
          });
        }
      } else {
        if (mounted) setState(() { _nodes = []; _loading = false; });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectNode(ProxyNode node) {
    setState(() {
      _selectedNode = _selectedNode?.name == node.name ? null : node;
    });
  }

  Future<void> _connectSelected() async {
    final node = _selectedNode;
    if (node == null) return;
    if (_activeProfile?.rawConfig == null) {
      _showSnack('Сначала выберите профиль', isError: true);
      return;
    }
    final vpnState = _mihomo.currentState;
    if (vpnState.isConnected && vpnState.activeNode?.name == node.name) {
      await _mihomo.disconnect();
    } else {
      final ok = await _mihomo.connect(node, _activeProfile!.rawConfig!);
      if (!ok && mounted) _showSnack('Ошибка подключения', isError: true);
    }
  }

  Future<void> _testDelay(ProxyNode node) async {
    setState(() => _testingNodes.add(node.name));
    final pingUrl = _settings.pingUrl;
    final ms = await _mihomo.testDelay(node.name, testUrl: pingUrl);
    final idx = _nodes.indexWhere((n) => n.name == node.name);
    if (idx != -1 && mounted) {
      setState(() {
        _nodes[idx].latencyMs = ms;
        _testingNodes.remove(node.name);
      });
    }
  }

  Future<void> _testAllDelays() async {
    for (final node in List.from(_nodes)) {
      await _testDelay(node);
    }
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
    super.build(context); // обязательно для AutomaticKeepAliveClientMixin
    final vpnState = _mihomo.currentState;
    final selectedName = _selectedNode?.name;
    final isSelectedConnected = vpnState.isConnected &&
        vpnState.activeNode?.name == selectedName;

    return Scaffold(
      // Не пересчитываем лейаут при открытии клавиатуры в других вкладках
      resizeToAvoidBottomInset: false,
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
            tooltip: 'Обновить',
            onPressed: _loadNodes,
          ),
        ],
      ),
      body: Column(
        children: [
          // VPN статус-бар
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: _VpnStatusBar(
              key: ValueKey(vpnState.status),
              state: vpnState,
              onDisconnect: _mihomo.disconnect,
            ),
          ),
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
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_activeProfile == null) {
      return _buildHint(context,
          icon: Icons.folder_off_outlined,
          title: 'Нет активного профиля',
          subtitle: 'Перейди во вкладку Профили и активируй подписку');
    }

    if (_nodes.isEmpty) {
      return _buildHint(context,
          icon: Icons.cloud_off_outlined,
          title: 'Хосты не загружены',
          subtitle: 'Обнови профиль во вкладке Профили');
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
      itemCount: _nodes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (ctx, i) {
        final node = _nodes[i];
        final isActive = vpnState.isConnected && vpnState.activeNode?.name == node.name;
        final isSelected = _selectedNode?.name == node.name;
        return RepaintBoundary(
          child: _ProxyCard(
            key: ValueKey(node.name),
            node: node,
            isActive: isActive,
            isSelected: isSelected,
            isTesting: _testingNodes.contains(node.name),
            isConnecting: vpnState.isConnecting && vpnState.activeNode?.name == node.name,
            onTap: () => _selectNode(node),
            onTestDelay: () => _testDelay(node),
          ),
        );
      },
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

// ── VPN Status Bar ──────────────────────────────────────────────────────────

class _VpnStatusBar extends StatelessWidget {
  const _VpnStatusBar({super.key, required this.state, required this.onDisconnect});
  final VpnState state;
  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color bg;
    Color fg;
    String label;
    IconData icon;

    switch (state.status) {
      case VpnStatus.connected:
        bg = const Color(0xFF2E7D32);
        fg = Colors.white;
        label = '🟢  ${state.activeNode?.name ?? 'Подключено'}';
        icon = Icons.shield;
        break;
      case VpnStatus.connecting:
        bg = scheme.primaryContainer;
        fg = scheme.onPrimaryContainer;
        label = '⏳  Подключение...';
        icon = Icons.hourglass_empty;
        break;
      case VpnStatus.error:
        bg = scheme.errorContainer;
        fg = scheme.onErrorContainer;
        label = '❌  ${state.errorMessage ?? 'Ошибка'}';
        icon = Icons.error_outline;
        break;
      case VpnStatus.disconnected:
        return const SizedBox.shrink();
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(label,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w500))),
          if (state.isConnected)
            TextButton(
              onPressed: onDisconnect,
              style: TextButton.styleFrom(foregroundColor: fg),
              child: const Text('Отключить'),
            ),
        ],
      ),
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
  final bool isActive;
  final bool isSelected;
  final bool isTesting;
  final bool isConnecting;
  final VoidCallback onTap;
  final VoidCallback onTestDelay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Цвет карточки зависит от состояния
    Color cardColor;
    Color borderColor;
    double elevation;

    if (isActive) {
      cardColor = const Color(0xFF2E7D32).withValues(alpha: 0.12);
      borderColor = const Color(0xFF2E7D32);
      elevation = 2;
    } else if (isSelected) {
      cardColor = scheme.primaryContainer.withValues(alpha: 0.7);
      borderColor = scheme.primary;
      elevation = 1;
    } else {
      cardColor = scheme.surfaceContainerHighest;
      borderColor = Colors.transparent;
      elevation = 0;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: (isActive || isSelected) ? 1.5 : 0),
        boxShadow: elevation > 0
            ? [BoxShadow(color: borderColor.withValues(alpha: 0.2), blurRadius: 8, offset: const Offset(0, 2))]
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
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: isActive
                        ? const Color(0xFF2E7D32).withValues(alpha: 0.2)
                        : isSelected
                            ? scheme.primary.withValues(alpha: 0.15)
                            : scheme.surface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(
                      node.typeLabel,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: isActive
                            ? const Color(0xFF2E7D32)
                            : isSelected
                                ? scheme.primary
                                : scheme.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Имя и сервер
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        node.name,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${node.server}:${node.port}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Индикатор состояния
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
          color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5));
    }
    Color color;
    if (node.isTimeout) {
      color = Colors.red;
    } else if (node.isFast) {
      color = const Color(0xFF2E7D32);
    } else if (node.isMedium) {
      color = Colors.orange;
    } else {
      color = Colors.red;
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(node.latencyLabel,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}
