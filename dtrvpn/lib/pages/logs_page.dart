import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/dtr_log.dart';
import '../services/mihomo_service.dart';

/// Страница логов с двумя вкладками:
///   1. DTR — Flutter-side DtrLog (все компоненты: SubSvc, Mihomo, StorageService и т.д.)
///   2. Core — Mihomo internal logs из Go-ядра (DNS, правила, соединения)
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});
  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Логи'),
        centerTitle: false,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.phone_android, size: 18), text: 'DTR'),
            Tab(icon: Icon(Icons.memory, size: 18), text: 'Mihomo Core'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _DtrLogTab(),
          _MihomoLogTab(),
        ],
      ),
    );
  }
}

// ── DTR Flutter-side logs ──────────────────────────────────────────────────

class _DtrLogTab extends StatefulWidget {
  const _DtrLogTab();
  @override
  State<_DtrLogTab> createState() => _DtrLogTabState();
}

class _DtrLogTabState extends State<_DtrLogTab>
    with AutomaticKeepAliveClientMixin {
  List<DtrLogEntry> _entries = [];
  String _filter = '';
  DtrLogLevel? _levelFilter;
  Timer? _refreshTimer;

  static const _levelColors = {
    DtrLogLevel.debug: Color(0xFF9E9E9E),
    DtrLogLevel.info:  Color(0xFF1976D2),
    DtrLogLevel.warn:  Color(0xFFFF9800),
    DtrLogLevel.error: Color(0xFFF44336),
  };

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _refresh();
    // Автообновление раз в секунду пока страница открыта
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _refresh();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _refresh() {
    final all = DtrLog.entries.reversed.toList();
    setState(() => _entries = all);
  }

  List<DtrLogEntry> get _filtered {
    var list = _entries;
    if (_levelFilter != null) {
      list = list.where((e) => e.level == _levelFilter).toList();
    }
    if (_filter.isNotEmpty) {
      final q = _filter.toLowerCase();
      list = list.where((e) =>
          e.tag.toLowerCase().contains(q) ||
          e.message.toLowerCase().contains(q)).toList();
    }
    return list;
  }

  Future<void> _copyAll() async {
    final text = _filtered.map((e) => e.toString()).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Скопировано в буфер'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final filtered = _filtered;
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        // Toolbar
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Поиск по тегу/сообщению...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
              const SizedBox(width: 6),
              // Фильтр по уровню
              PopupMenuButton<DtrLogLevel?>(
                icon: Icon(Icons.filter_list,
                    color: _levelFilter != null ? cs.primary : null),
                tooltip: 'Фильтр по уровню',
                onSelected: (v) => setState(() => _levelFilter = v),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: null, child: Text('Все уровни')),
                  const PopupMenuDivider(),
                  ...DtrLogLevel.values.map((l) => PopupMenuItem(
                        value: l,
                        child: Row(children: [
                          Icon(Icons.circle, size: 10,
                              color: _levelColors[l]),
                          const SizedBox(width: 8),
                          Text(l.name.toUpperCase()),
                        ]),
                      )),
                ],
              ),
              // Копировать
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                tooltip: 'Копировать всё',
                onPressed: _copyAll,
              ),
              // Очистить
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Очистить',
                onPressed: () {
                  DtrLog.clear();
                  setState(() => _entries = []);
                },
              ),
            ],
          ),
        ),
        // Счётчик
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(
            children: [
              Text('${filtered.length} записей',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant)),
            ],
          ),
        ),
        const Divider(height: 1),
        // Список
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text('Нет логов',
                      style: TextStyle(color: cs.onSurface.withValues(alpha: 0.4))),
                )
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) {
                    final e = filtered[i];
                    return _LogEntryTile(entry: e, levelColors: _levelColors);
                  },
                ),
        ),
      ],
    );
  }
}

class _LogEntryTile extends StatelessWidget {
  const _LogEntryTile({required this.entry, required this.levelColors});
  final DtrLogEntry entry;
  final Map<DtrLogLevel, Color> levelColors;

  @override
  Widget build(BuildContext context) {
    final color = levelColors[entry.level] ?? Colors.grey;
    final t = entry.time;
    final ts =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${(t.millisecond ~/ 10).toString().padLeft(2, '0')}';

    return InkWell(
      onLongPress: () async {
        await Clipboard.setData(ClipboardData(text: entry.toString()));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Скопировано'), duration: Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ));
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Уровень
            SizedBox(
              width: 14,
              child: Text(entry.levelLabel,
                  style: TextStyle(
                      fontSize: 11, color: color, fontWeight: FontWeight.bold,
                      fontFamily: 'monospace')),
            ),
            const SizedBox(width: 4),
            // Время
            Text(ts,
                style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                    fontFamily: 'monospace')),
            const SizedBox(width: 6),
            // Тег
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(entry.tag,
                  style: TextStyle(
                      fontSize: 10, color: color, fontWeight: FontWeight.w600,
                      fontFamily: 'monospace')),
            ),
            const SizedBox(width: 6),
            // Сообщение
            Expanded(
              child: Text(entry.message,
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85),
                      fontFamily: 'monospace'),
                  softWrap: true),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Mihomo Core logs (из Go-ядра via EventChannel) ─────────────────────────

class _MihomoLogTab extends StatefulWidget {
  const _MihomoLogTab();
  @override
  State<_MihomoLogTab> createState() => _MihomoLogTabState();
}

class _MihomoLogTabState extends State<_MihomoLogTab>
    with AutomaticKeepAliveClientMixin {
  final _mihomo = MihomoService.instance;
  final List<MihomoLogEntry> _entries = [];
  StreamSubscription<List<MihomoLogEntry>>? _sub;
  final _scrollController = ScrollController();
  bool _autoScroll = true;
  String _filter = '';

  static const _maxEntries = 500;

  static const _levelColors = {
    'debug':   Color(0xFF9E9E9E),
    'info':    Color(0xFF1976D2),
    'warning': Color(0xFFFF9800),
    'error':   Color(0xFFF44336),
    'silent':  Color(0xFF607D8B),
  };

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _sub = _mihomo.mihomoLogStream.listen((batch) {
      if (!mounted) return;
      setState(() {
        _entries.addAll(batch);
        while (_entries.length > _maxEntries) _entries.removeAt(0);
      });
      if (_autoScroll && _scrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  List<MihomoLogEntry> get _filtered {
    if (_filter.isEmpty) return _entries;
    final q = _filter.toLowerCase();
    return _entries.where((e) => e.payload.toLowerCase().contains(q)).toList();
  }

  Future<void> _copyAll() async {
    final text = _filtered
        .map((e) => '${e.time} [${e.level.toUpperCase()}] ${e.payload}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Скопировано'), behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final filtered = _filtered;
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        // Toolbar
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Поиск...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
              const SizedBox(width: 6),
              // Авто-скролл
              IconButton(
                icon: Icon(
                  _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
                  size: 20,
                  color: _autoScroll ? cs.primary : null,
                ),
                tooltip: _autoScroll ? 'Авто-скролл вкл' : 'Авто-скролл выкл',
                onPressed: () => setState(() => _autoScroll = !_autoScroll),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 20),
                tooltip: 'Копировать',
                onPressed: _copyAll,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Очистить',
                onPressed: () => setState(() => _entries.clear()),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Row(children: [
            Text('${filtered.length} записей',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant)),
            const Spacer(),
            if (_entries.isEmpty)
              Text('Логи появятся после подключения VPN',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.6))),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.memory, size: 48,
                          color: cs.onSurface.withValues(alpha: 0.2)),
                      const SizedBox(height: 12),
                      Text('Нет логов Mihomo',
                          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.4))),
                      const SizedBox(height: 4),
                      Text('Подключитесь к VPN чтобы увидеть логи ядра',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.3))),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) {
                    final e = filtered[i];
                    final color = _levelColors[e.level.toLowerCase()] ?? Colors.grey;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.time,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: cs.onSurface.withValues(alpha: 0.4),
                                  fontFamily: 'monospace')),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(e.level.toUpperCase(),
                                style: TextStyle(
                                    fontSize: 9, color: color,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace')),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(e.payload,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurface.withValues(alpha: 0.85),
                                    fontFamily: 'monospace')),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
