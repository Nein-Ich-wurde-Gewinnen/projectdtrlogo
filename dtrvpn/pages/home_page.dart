import 'package:flutter/material.dart';
import 'proxies_page.dart';
import 'profiles_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  late final AnimationController _navAnimCtrl;
  late final Animation<double> _navFade;

  // IndexedStack держит все страницы живыми — не пересоздаются при переключении.
  // AutomaticKeepAliveClientMixin в каждой странице сохраняет их состояние.
  static const _pages = [
    ProxiesPage(),
    ProfilesPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    _navAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _navFade = CurvedAnimation(parent: _navAnimCtrl, curve: Curves.easeOut);
    _navAnimCtrl.forward();
  }

  @override
  void dispose() {
    _navAnimCtrl.dispose();
    super.dispose();
  }

  void _onTabChanged(int index) {
    if (index == _currentIndex) return;
    _navAnimCtrl.forward(from: 0);
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // IndexedStack: все страницы монтированы, но видна только одна.
      // Устраняет лаги при переключении вкладок и при открытии клавиатуры.
      body: FadeTransition(
        opacity: _navFade,
        child: IndexedStack(
          index: _currentIndex,
          children: _pages,
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onTabChanged,
        animationDuration: const Duration(milliseconds: 300),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns),
            label: 'Прокси',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Профили',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Настройки',
          ),
        ],
      ),
    );
  }
}
