import 'dart:math';
import 'package:flutter/material.dart';
import '../models/profile.dart';
import '../services/storage_service.dart';
import '../services/subscription_service.dart';
import 'package:uuid/uuid.dart';

// ── Форматирование трафика ─────────────────────────────────────────────────

String _fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  final i = (log(bytes) / log(1024)).floor().clamp(0, units.length - 1);
  final val = bytes / pow(1024, i);
  return '${val.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

String _fmtDate(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inMinutes < 1) return 'только что';
  if (diff.inHours < 1) return '${diff.inMinutes} мин. назад';
  if (diff.inDays < 1) return '${diff.inHours} ч. назад';
  return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
}

String _fmtExpire(DateTime dt) {
  final now = DateTime.now();
  final diff = dt.difference(now);
  if (diff.isNegative) return 'Истекла';
  if (diff.inDays == 0) return 'Сегодня';
  if (diff.inDays == 1) return 'Завтра';
  return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
}

// ── Page ───────────────────────────────────────────────────────────────────

class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key});
  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _storage = StorageService.instance;
  final _subService = SubscriptionService();
  List<Profile> _profiles = [];
  final Set<String> _loadingIds = {};

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final p = await _storage.getProfiles();
    if (mounted) setState(() => _profiles = p);
  }

  Future<void> _addProfile() async {
    final result = await showDialog<({String name, String url})>(
      context: context,
      builder: (_) => const _AddProfileDialog(),
    );
    if (result == null) return;

    final profile = Profile(id: const Uuid().v4(), name: result.name, url: result.url);
    await _storage.insertProfile(profile);
    await _loadProfiles();
    await _refresh(profile.id);
  }

  Future<void> _refresh(String id) async {
    Profile? profile;
    try {
      profile = _profiles.firstWhere((p) => p.id == id);
    } catch (_) {
      profile = await _storage.getProfile(id);
    }
    if (profile == null) return;

    setState(() => _loadingIds.add(id));
    try {
      final info = await _subService.fetchSubscription(profile!.url);
      final updated = profile.copyWith(
        rawConfig: info.raw,
        proxyCount: info.nodes.length,
        lastUpdated: DateTime.now(),
        name: profile.name.isEmpty || profile.name == 'Подписка'
            ? info.name
            : profile.name,
        username: info.username,
        trafficUsed: info.trafficUsed,
        trafficTotal: info.trafficTotal,
        expireDate: info.expireDate,
      );
      await _storage.updateProfile(updated);
      await _loadProfiles();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Обновлено: ${info.nodes.length} хостов'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Ошибка: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _loadingIds.remove(id));
    }
  }

  Future<void> _activate(String id) async {
    await _storage.setActiveProfile(id);
    await _loadProfiles();
  }

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить профиль?'),
        content: const Text('Конфигурация будет удалена.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (confirm != true) return;
    await _storage.deleteProfile(id);
    await _loadProfiles();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    return Scaffold(
      appBar: AppBar(title: const Text('Профили'), centerTitle: false),
      body: _profiles.isEmpty
          ? _buildEmpty(context)
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              itemCount: _profiles.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) {
                final p = _profiles[i];
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _ProfileCard(
                    key: ValueKey('${p.id}-${p.lastUpdated}'),
                    profile: p,
                    isLoading: _loadingIds.contains(p.id),
                    onActivate: () => _activate(p.id),
                    onRefresh: () => _refresh(p.id),
                    onDelete: () => _delete(p.id),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addProfile,
        icon: const Icon(Icons.add_link),
        label: const Text('Добавить'),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_open, size: 72, color: cs.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text('Нет профилей',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.5))),
          const SizedBox(height: 8),
          Text('Добавьте ссылку на подписку',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.4))),
        ],
      ),
    );
  }
}

// ── Profile Card ───────────────────────────────────────────────────────────

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    super.key,
    required this.profile,
    required this.isLoading,
    required this.onActivate,
    required this.onRefresh,
    required this.onDelete,
  });

  final Profile profile;
  final bool isLoading;
  final VoidCallback onActivate;
  final VoidCallback onRefresh;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isActive = profile.isActive;
    // hasTraffic: показываем блок трафика если есть использованный трафик
    final hasTraffic = profile.trafficUsed != null;
    final bool isUnlimited = profile.trafficTotal == null;
    final double trafficFraction = !isUnlimited && profile.trafficTotal! > 0
        ? ((profile.trafficUsed ?? 0) / profile.trafficTotal!).clamp(0.0, 1.0)
        : 0.0;
    final isExpired = profile.expireDate != null &&
        profile.expireDate!.isBefore(DateTime.now());
    final expireSoon = !isExpired &&
        profile.expireDate != null &&
        profile.expireDate!.difference(DateTime.now()).inDays < 7;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: isActive ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
        border: isActive
            ? Border.all(color: scheme.primary, width: 1.5)
            : Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
        boxShadow: isActive
            ? [BoxShadow(color: scheme.primary.withValues(alpha: 0.15), blurRadius: 12, offset: const Offset(0, 4))]
            : null,
      ),
      child: InkWell(
        onTap: onActivate,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Заголовок
              Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: isActive
                          ? scheme.primary.withValues(alpha: 0.2)
                          : scheme.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      isActive ? Icons.check_circle : Icons.folder_outlined,
                      color: isActive ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                            child: Text(
                              profile.name,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                    color: isActive
                                        ? scheme.onPrimaryContainer
                                        : scheme.onSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isActive)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text('Активен',
                                  style: TextStyle(color: scheme.onPrimary, fontSize: 10, fontWeight: FontWeight.w600)),
                            ),
                        ]),
                        if (profile.username != null)
                          Text(
                            profile.username!,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: isActive
                                      ? scheme.onPrimaryContainer.withValues(alpha: 0.75)
                                      : scheme.onSurfaceVariant,
                                ),
                          ),
                      ],
                    ),
                  ),
                  if (isLoading)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert),
                      onSelected: (v) {
                        if (v == 'refresh') onRefresh();
                        if (v == 'delete') onDelete();
                        if (v == 'activate') onActivate();
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'refresh',
                            child: ListTile(leading: Icon(Icons.refresh), title: Text('Обновить'), dense: true)),
                        if (!isActive)
                          const PopupMenuItem(value: 'activate',
                              child: ListTile(leading: Icon(Icons.check_circle_outline), title: Text('Активировать'), dense: true)),
                        const PopupMenuDivider(),
                        const PopupMenuItem(value: 'delete',
                            child: ListTile(leading: Icon(Icons.delete_outline, color: Colors.red),
                                title: Text('Удалить', style: TextStyle(color: Colors.red)), dense: true)),
                      ],
                    ),
                ],
              ),

              // Трафик
              if (hasTraffic) ...[
                const SizedBox(height: 12),
                if (!isUnlimited) ...[
                  // Лимитированный — показываем использовано / всего + прогресс-бар
                  Row(
                    children: [
                      Icon(Icons.swap_vert, size: 16,
                          color: isActive ? scheme.onPrimaryContainer.withValues(alpha: 0.7) : scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(
                        '${_fmtBytes(profile.trafficUsed ?? 0)} / ${_fmtBytes(profile.trafficTotal!)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: isActive
                                  ? scheme.onPrimaryContainer.withValues(alpha: 0.85)
                                  : scheme.onSurface,
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                      const Spacer(),
                      Text(
                        '${(trafficFraction * 100).toStringAsFixed(1)}%',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: trafficFraction > 0.9
                                  ? scheme.error
                                  : isActive
                                      ? scheme.onPrimaryContainer.withValues(alpha: 0.7)
                                      : scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: trafficFraction,
                      minHeight: 6,
                      backgroundColor: scheme.surfaceContainerHighest,
                      color: trafficFraction > 0.9
                          ? scheme.error
                          : trafficFraction > 0.75
                              ? Colors.orange
                              : scheme.primary,
                    ),
                  ),
                ] else ...[
                  // Безлимитный — показываем потраченный трафик + метку ∞
                  Row(
                    children: [
                      Icon(Icons.swap_vert, size: 16,
                          color: isActive ? scheme.onPrimaryContainer.withValues(alpha: 0.7) : scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(
                        '${_fmtBytes(profile.trafficUsed ?? 0)} потрачено',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: isActive
                                  ? scheme.onPrimaryContainer.withValues(alpha: 0.85)
                                  : scheme.onSurface,
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('∞ Безлимит',
                            style: TextStyle(
                              color: scheme.primary,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            )),
                      ),
                    ],
                  ),
                ],
              ],

              // Метаданные: истечение + обновление
              const SizedBox(height: 8),
              Row(
                children: [
                  if (profile.expireDate != null) ...[
                    Icon(Icons.schedule, size: 14,
                        color: isExpired
                            ? scheme.error
                            : expireSoon
                                ? Colors.orange
                                : scheme.onSurfaceVariant.withValues(alpha: 0.7)),
                    const SizedBox(width: 4),
                    Text(
                      isExpired ? 'Истекла' : 'до ${_fmtExpire(profile.expireDate!)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: isExpired
                                ? scheme.error
                                : expireSoon
                                    ? Colors.orange
                                    : isActive
                                        ? scheme.onPrimaryContainer.withValues(alpha: 0.6)
                                        : scheme.onSurfaceVariant.withValues(alpha: 0.7),
                            fontSize: 11,
                          ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (profile.lastUpdated != null) ...[
                    Icon(Icons.update, size: 14,
                        color: isActive
                            ? scheme.onPrimaryContainer.withValues(alpha: 0.5)
                            : scheme.onSurfaceVariant.withValues(alpha: 0.5)),
                    const SizedBox(width: 4),
                    Text(
                      _fmtDate(profile.lastUpdated!),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: isActive
                                ? scheme.onPrimaryContainer.withValues(alpha: 0.5)
                                : scheme.onSurfaceVariant.withValues(alpha: 0.6),
                            fontSize: 11,
                          ),
                    ),
                  ] else
                    Text('Не загружен',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                            fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Add Profile Dialog ─────────────────────────────────────────────────────

class _AddProfileDialog extends StatefulWidget {
  const _AddProfileDialog();
  @override
  State<_AddProfileDialog> createState() => _AddProfileDialogState();
}

class _AddProfileDialogState extends State<_AddProfileDialog> {
  final _urlCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _urlCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Добавить подписку'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: 'URL подписки *',
                hintText: 'https://sub.example.com/...',
                prefixIcon: Icon(Icons.link),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Введите URL';
                final uri = Uri.tryParse(v.trim());
                if (uri == null || !uri.hasScheme) return 'Некорректный URL';
                return null;
              },
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Название (необязательно)',
                hintText: 'DTR VPN',
                prefixIcon: Icon(Icons.label_outline),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton.icon(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.pop(context, (
              name: _nameCtrl.text.trim().isEmpty ? 'Подписка' : _nameCtrl.text.trim(),
              url: _urlCtrl.text.trim(),
            ));
          },
          icon: const Icon(Icons.download),
          label: const Text('Добавить'),
        ),
      ],
    );
  }
}
