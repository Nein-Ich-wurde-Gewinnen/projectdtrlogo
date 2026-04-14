import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import 'logs_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _settings = SettingsService.instance;
  late final TextEditingController _pingCtrl;

  static const _presetColors = [
    (label: 'Синий',     color: Color(0xFF1A73E8)),
    (label: 'Бирюза',    color: Color(0xFF009688)),
    (label: 'Зелёный',   color: Color(0xFF43A047)),
    (label: 'Лайм',      color: Color(0xFF7CB342)),
    (label: 'Оранжевый', color: Color(0xFFFF9800)),
    (label: 'Красный',   color: Color(0xFFF44336)),
    (label: 'Розовый',   color: Color(0xFFE91E63)),
    (label: 'Фиолет',    color: Color(0xFF9C27B0)),
    (label: 'Индиго',    color: Color(0xFF3F51B5)),
    (label: 'Голубой',   color: Color(0xFF0288D1)),
  ];

  @override
  void initState() {
    super.initState();
    _pingCtrl = TextEditingController(text: _settings.pingUrl);
    _settings.addListener(_rebuild);
  }

  @override
  void dispose() {
    _pingCtrl.dispose();
    _settings.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final currentSeed = _settings.seedColor;
    final currentMode = _settings.themeMode;

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки'), centerTitle: false),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [

          // ── Внешний вид ──────────────────────────────────────────────────
          _SectionHeader('Внешний вид'),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('Режим темы',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto), label: Text('Авто')),
                ButtonSegment(value: ThemeMode.light,
                    icon: Icon(Icons.light_mode), label: Text('Светлый')),
                ButtonSegment(value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode), label: Text('Тёмный')),
              ],
              selected: {currentMode},
              onSelectionChanged: (s) => _settings.setThemeMode(s.first),
            ),
          ),

          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('Цвет темы',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _presetColors.map((preset) {
                final isSelected = currentSeed.toARGB32() == preset.color.toARGB32();
                return Tooltip(
                  message: preset.label,
                  child: GestureDetector(
                    onTap: () => _settings.setSeedColor(preset.color),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: preset.color,
                        shape: BoxShape.circle,
                        border: isSelected
                            ? Border.all(color: cs.onSurface, width: 3)
                            : null,
                        boxShadow: isSelected
                            ? [BoxShadow(color: preset.color.withValues(alpha: 0.5),
                                blurRadius: 8, spreadRadius: 2)]
                            : null,
                      ),
                      child: isSelected
                          ? const Icon(Icons.check, color: Colors.white, size: 22)
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          const Divider(indent: 16, endIndent: 16),

          // ── Подключение ──────────────────────────────────────────────────
          _SectionHeader('Подключение'),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('URL для проверки пинга',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: TextField(
              controller: _pingCtrl,
              decoration: InputDecoration(
                hintText: SettingsService.defaultPingUrl,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.http),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.restore),
                  tooltip: 'По умолчанию',
                  onPressed: () {
                    _pingCtrl.text = SettingsService.defaultPingUrl;
                    _settings.setPingUrl(SettingsService.defaultPingUrl);
                  },
                ),
              ),
              keyboardType: TextInputType.url,
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) _settings.setPingUrl(v.trim());
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'HTTP-адрес отвечающий кодом 204. Используется для замера пинга серверов.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
            ),
          ),

          // ── Debug (только debug-сборка) ──────────────────────────────────
          if (kDebugMode) ...[
            const Divider(indent: 16, endIndent: 16),
            _SectionHeader('Debug'),

            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: const Text('Логи'),
              subtitle: const Text('Flutter + Mihomo Core логи'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LogsPage()),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
