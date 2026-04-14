import 'dart:math';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/profile.dart';
import '../services/storage_service.dart';
import '../services/subscription_service.dart';
import '../services/dtr_log.dart';
import 'package:uuid/uuid.dart';

// ── Утилиты форматирования ─────────────────────────────────────────────────

String _fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  final i = (log(bytes) / log(1024)).floor().clamp(0, units.length - 1);
  final val = bytes / pow(1024, i);
  final str = val.toStringAsFixed(i == 0 ? 0 : 2);
  final trimmed = str.contains('.')
      ? str.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
      : str;
  return '$trimmed ${units[i]}';
}

String _fmtDate(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inSeconds < 60) return 'только что';
  if (diff.inMinutes < 60) return '${diff.inMinutes} мин. назад';
  if (diff.inHours < 24)   return '${diff.inHours} ч. назад';
  if (diff.inDays < 30)    return '${diff.inDays} д. назад';
  return _dateStr(dt);
}

String _fmtExpire(DateTime dt) {
  final now = DateTime.now();
  final diff = dt.difference(now);
  if (diff.isNegative) return 'Истекла';
  if (diff.inDays == 0) return 'Сегодня';
  if (diff.inDays == 1) return 'Завтра';
  if (diff.inDays < 7)  return 'Через ${diff.inDays} д.';
  return _dateStr(dt);
}

String _dateStr(DateTime dt) =>
    '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';

// ── Page ───────────────────────────────────────────────────────────────────

class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key});
  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  static const _tag = 'ProfilesPage';
  final _storage    = StorageService.instance;
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
    DtrLog.d(_tag, 'loadProfiles: ${p.length} profiles');
    if (mounted) setState(() => _profiles = p);
  }

  Future<void> _addProfile() async {
    final result = await showDialog<({String name, String url})>(
      context: context,
      builder: (_) => const _AddProfileDialog(),
    );
    if (result == null) return;

    DtrLog.i(_tag, 'addProfile name="${result.name}" url=${result.url}');
    final profile = Profile(id: const Uuid().v4(), name: result.name, url: result.url);
    await _storage.insertProfile(profile);
    await _loadProfiles();
    await _refresh(profile.id);
  }

  Future<void> _refresh(String id) async {
    Profile? profile;
    try { profile = _profiles.firstWhere((p) => p.id == id); }
    catch (_) { profile = await _storage.getProfile(id); }
    if (profile == null) return;

    DtrLog.i(_tag, 'refresh profile "${profile.name}" url=${profile.url}');
    setState(() => _loadingIds.add(id));

    try {
      final info = await _subService.fetchSubscription(profile!.url);
      final updated = profile.copyWith(
        rawConfig:           info.raw,
        proxyCount:          info.nodes.length,
        lastUpdated:         DateTime.now(),
        name: profile.name.isEmpty || profile.name == 'Подписка'
            ? info.name
            : profile.name,
        username:            info.username,
        trafficUsed:         info.trafficUsed,
        trafficTotal:        info.trafficTotal,
        expireDate:          info.expireDate,
        supportUrl:          info.supportUrl,
        announceMsg:         info.announceMsg,
        updateIntervalHours: info.updateIntervalHours,
      );
      await _storage.updateProfile(updated);
      await _loadProfiles();

      DtrLog.i(_tag, 'refresh OK: ${info.nodes.length} nodes, supportUrl=${info.supportUrl}');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Обновлено: ${info.nodes.length} серверов'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      DtrLog.e(_tag, 'refresh error: $e');
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
    DtrLog.i(_tag, 'activate profile $id');
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
    DtrLog.i(_tag, 'delete profile $id');
    await _storage.deleteProfile(id);
    await _loadProfiles();
  }

  @override
  Widget build(BuildContext context) {
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
                return _ProfileCard(
                  key: ValueKey('${p.id}-${p.lastUpdated}'),
                  profile: p,
                  isLoading: _loadingIds.contains(p.id),
                  onActivate: () => _activate(p.id),
                  onRefresh: () => _refresh(p.id),
                  onDelete: () => _delete(p.id),
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
          Text('Нажмите «Добавить» и вставьте ссылку на подписку',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.4)),
              textAlign: TextAlign.center),
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
  final VoidCallback onActivate, onRefresh, onDelete;

  // Открываем support-url (Telegram или браузер)
  Future<void> _openSupportUrl(BuildContext context) async {
    final raw = profile.supportUrl;
    if (raw == null || raw.isEmpty) return;
    String urlStr = raw;
    // t.me/channel → https://t.me/channel
    if (urlStr.startsWith('t.me/') || urlStr.startsWith('//t.me/')) {
      urlStr = 'https://${urlStr.replaceFirst('//', '')}';
    }
    final uri = Uri.tryParse(urlStr);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть: $urlStr')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme  = Theme.of(context).colorScheme;
    final isActive = profile.isActive;

    final bool isUnlimited  = profile.trafficTotal == null || profile.trafficTotal == 0;
    final bool hasTraffic   = profile.trafficUsed != null;
    final double fraction   = (!isUnlimited && hasTraffic)
        ? ((profile.trafficUsed ?? 0) / profile.trafficTotal!).clamp(0.0, 1.0)
        : 0.0;
    final bool isExpired    = profile.expireDate != null &&
        profile.expireDate!.isBefore(DateTime.now());
    final bool expiresSoon  = !isExpired && profile.expireDate != null &&
        profile.expireDate!.difference(DateTime.now()).inDays < 7;

    final bool hasSupportUrl  = profile.supportUrl?.isNotEmpty == true;
    final bool hasAnnounce    = profile.announceMsg?.isNotEmpty == true;
    final bool isTelegram     = hasSupportUrl &&
        (profile.supportUrl!.contains('t.me') || profile.supportUrl!.contains('telegram'));

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
            ? [BoxShadow(color: scheme.primary.withValues(alpha: 0.15),
                blurRadius: 12, offset: const Offset(0, 4))]
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

              // ── Announce баннер (FlClashX: provider message) ───────────
              if (hasAnnounce) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isActive
                        ? scheme.primary.withValues(alpha: 0.15)
                        : scheme.secondaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: isActive
                            ? scheme.primary.withValues(alpha: 0.4)
                            : scheme.secondary.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.campaign_outlined, size: 16,
                          color: isActive ? scheme.primary : scheme.onSecondaryContainer),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          profile.announceMsg!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: isActive
                                  ? scheme.onPrimaryContainer
                                  : scheme.onSecondaryContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // ── Заголовок строка ────────────────────────────────────────
              Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 42, height: 42,
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
                          if (isActive) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text('Активен',
                                  style: TextStyle(
                                      color: scheme.onPrimary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ]),
                        if (profile.username != null)
                          Text(profile.username!,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: isActive
                                        ? scheme.onPrimaryContainer.withValues(alpha: 0.75)
                                        : scheme.onSurfaceVariant,
                                  )),
                      ],
                    ),
                  ),
                  if (isLoading)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(
                          width: 20, height: 20,
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
                        const PopupMenuItem(
                            value: 'refresh',
                            child: ListTile(
                                leading: Icon(Icons.refresh),
                                title: Text('Обновить'), dense: true)),
                        if (!isActive)
                          const PopupMenuItem(
                              value: 'activate',
                              child: ListTile(
                                  leading: Icon(Icons.check_circle_outline),
                                  title: Text('Активировать'), dense: true)),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                                leading: Icon(Icons.delete_outline, color: Colors.red),
                                title: Text('Удалить',
                                    style: TextStyle(color: Colors.red)),
                                dense: true)),
                      ],
                    ),
                ],
              ),

              // ── Трафик ────────────────────────────────────────────────
              if (hasTraffic) ...[
                const SizedBox(height: 12),
                _SubscriptionTrafficRow(
                  used: profile.trafficUsed ?? 0,
                  total: profile.trafficTotal,
                  isUnlimited: isUnlimited,
                  fraction: fraction,
                  isActive: isActive,
                  scheme: scheme,
                ),
              ],

              // ── Метаданные ────────────────────────────────────────────
              const SizedBox(height: 8),
              Row(
                children: [
                  // Дата истечения
                  Icon(Icons.schedule, size: 14,
                      color: isExpired
                          ? scheme.error
                          : expiresSoon
                              ? Colors.orange
                              : scheme.onSurfaceVariant.withValues(alpha: 0.7)),
                  const SizedBox(width: 4),
                  Text(_expireLabel(profile),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: isExpired
                                ? scheme.error
                                : expiresSoon
                                    ? Colors.orange
                                    : isActive
                                        ? scheme.onPrimaryContainer.withValues(alpha: 0.6)
                                        : scheme.onSurfaceVariant.withValues(alpha: 0.7),
                            fontSize: 11,
                          )),
                  const SizedBox(width: 12),
                  if (profile.lastUpdated != null) ...[
                    Icon(Icons.update, size: 14,
                        color: isActive
                            ? scheme.onPrimaryContainer.withValues(alpha: 0.5)
                            : scheme.onSurfaceVariant.withValues(alpha: 0.5)),
                    const SizedBox(width: 4),
                    Text(_fmtDate(profile.lastUpdated!),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: isActive
                                  ? scheme.onPrimaryContainer.withValues(alpha: 0.5)
                                  : scheme.onSurfaceVariant.withValues(alpha: 0.6),
                              fontSize: 11,
                            )),
                  ] else
                    Text('Не загружен',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                            fontSize: 11)),

                  const Spacer(),

                  // Кнопка поддержки (Telegram или browser)
                  if (hasSupportUrl)
                    GestureDetector(
                      onTap: () => _openSupportUrl(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: isTelegram
                              ? const Color(0xFF0088CC).withValues(alpha: 0.12)
                              : scheme.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isTelegram ? Icons.telegram : Icons.open_in_browser,
                              size: 14,
                              color: isTelegram
                                  ? const Color(0xFF0088CC)
                                  : scheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isTelegram ? 'Telegram' : 'Поддержка',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: isTelegram
                                      ? const Color(0xFF0088CC)
                                      : scheme.primary,
                                  fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _expireLabel(Profile p) {
    if (p.expireDate == null) return '∞';
    return _fmtExpire(p.expireDate!);
  }
}

// ── Блок трафика ───────────────────────────────────────────────────────────

class _SubscriptionTrafficRow extends StatelessWidget {
  const _SubscriptionTrafficRow({
    required this.used,
    required this.total,
    required this.isUnlimited,
    required this.fraction,
    required this.isActive,
    required this.scheme,
  });

  final int used;
  final int? total;
  final bool isUnlimited, isActive;
  final double fraction;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final barColor = !isUnlimited && fraction > 0.9
        ? scheme.error
        : !isUnlimited && fraction > 0.75
            ? Colors.orange
            : scheme.primary;
    final labelColor = isActive
        ? scheme.onPrimaryContainer.withValues(alpha: 0.85)
        : scheme.onSurface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.swap_vert, size: 16,
                color: isActive
                    ? scheme.onPrimaryContainer.withValues(alpha: 0.7)
                    : scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              isUnlimited ? '${_fmtBytes(used)} / ∞ Безлимит' : '${_fmtBytes(used)} / ${_fmtBytes(total!)}',
              style: textTheme.bodySmall?.copyWith(
                  color: labelColor, fontWeight: FontWeight.w500),
            ),
            const Spacer(),
            if (!isUnlimited)
              Text('${(fraction * 100).toStringAsFixed(1)}%',
                  style: textTheme.bodySmall?.copyWith(
                    color: fraction > 0.9
                        ? scheme.error
                        : isActive
                            ? scheme.onPrimaryContainer.withValues(alpha: 0.7)
                            : scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  )),
          ],
        ),
        if (!isUnlimited) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
              color: barColor,
            ),
          ),
        ],
      ],
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
  final _urlCtrl  = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _formKey  = GlobalKey<FormState>();

  @override
  void dispose() { _urlCtrl.dispose(); _nameCtrl.dispose(); super.dispose(); }

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
                hintText: 'https://sub.example.com/api/sub/...',
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
