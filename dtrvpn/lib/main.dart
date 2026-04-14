import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'pages/home_page.dart';
import 'services/mihomo_service.dart';
import 'services/settings_service.dart';
import 'services/storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Только критический минимум до runApp — UI появится мгновенно
  await SettingsService.instance.init();

  // Pre-warm базы данных параллельно с первым фреймом
  StorageService.instance.warmUp();

  runApp(const DTRApp());
}

class DTRApp extends StatefulWidget {
  const DTRApp({super.key});

  @override
  State<DTRApp> createState() => _DTRAppState();
}

class _DTRAppState extends State<DTRApp> {
  final _settings = SettingsService.instance;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);

    // Инициализируем VPN-сервис после первого фрейма — не блокирует UI
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      MihomoService.instance.init();
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final seed = _settings.seedColor;
    final mode = _settings.themeMode;

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final lightScheme = ColorScheme.fromSeed(
            seedColor: seed, brightness: Brightness.light);
        final darkScheme = ColorScheme.fromSeed(
            seedColor: seed, brightness: Brightness.dark);

        return MaterialApp(
          title: 'DTR VPN',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: ThemeData(
            colorScheme: lightScheme,
            useMaterial3: true,
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
              },
            ),
          ),
          darkTheme: ThemeData(
            colorScheme: darkScheme,
            useMaterial3: true,
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
              },
            ),
          ),
          // Плавное появление приложения вместо резкого перехода
          home: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeOut,
            child: _ready
                ? const HomePage(key: ValueKey('home'))
                : const _SplashScreen(key: ValueKey('splash')),
          ),
        );
      },
    );
  }
}

/// Splash-экран, показывается пока MihomoService инициализируется
class _SplashScreen extends StatefulWidget {
  const _SplashScreen({super.key});

  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();

    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      body: Center(
        child: FadeTransition(
          opacity: _opacity,
          child: ScaleTransition(
            scale: _scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Icon(Icons.shield_rounded,
                      size: 44, color: cs.primary),
                ),
                const SizedBox(height: 24),
                Text(
                  'DTR VPN',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: cs.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
