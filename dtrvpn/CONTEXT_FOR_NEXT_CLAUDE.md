# DTR VPN — Контекст проекта (апрель 2026)

## Привет! Ты продолжаешь разработку Android VPN-клиента DTR VPN.

---

## Директории

| Путь | Что там |
|------|---------|
| `~/dtrvpn` | **Основной репозиторий проекта** (git push сюда) |
| `~/downloads` | Архивы с исходниками для изучения |
| `~/downloads/FlClashX` | Исходники FlClashX (эталонный клиент, уже клонирован) |

Репозиторий: `https://github.com/Nein-Ich-wurde-Gewinnen/DTRClient` ветка `main`

---

## Стек

| Слой | Технология |
|------|-----------|
| UI | Flutter stable 3.41.6 / Dart |
| VPN-ядро | Go 1.22 + github.com/metacubex/mihomo v1.18.8 |
| JNI-мост | C (jni_bridge.c) + CGO → libclash.so |
| Android | Kotlin, minSdk 21, targetSdk 34, NDK 26.1.10909125 |
| Сборка CI | GitHub Actions, ubuntu-22.04 |
| Gradle | 8.10.2, AGP 8.7.3, Kotlin 2.1.0 |

---

## Структура репо

```
DTRClient/
├── .github/workflows/build.yml   ← CI (единственный активный)
├── android/
│   ├── app/build.gradle
│   └── src/main/
│       ├── AndroidManifest.xml
│       └── kotlin/online/dtr/vpn/
│           ├── MainActivity.kt      ← Flutter v2, MethodChannel + EventChannel
│           └── DTRVpnService.kt     ← Android VpnService, JNI-вызовы
├── core/
│   ├── clash_ffi.go    ← Go-ядро: все exported функции
│   ├── jni_bridge.c    ← JNI символы для Kotlin
│   └── go.mod
├── lib/
│   ├── main.dart
│   ├── models/
│   │   ├── profile.dart
│   │   ├── proxy_node.dart
│   │   └── vpn_state.dart       ← содержит TrafficStats
│   ├── pages/
│   │   ├── home_page.dart       ← IndexedStack + FadeTransition
│   │   ├── proxies_page.dart    ← список серверов, FAB подключения
│   │   ├── profiles_page.dart   ← управление подписками
│   │   ├── settings_page.dart   ← тема, ping URL, кнопка логов
│   │   └── logs_page.dart       ← просмотр DtrLog (debug only)
│   └── services/
│       ├── mihomo_service.dart      ← Flutter ↔ Kotlin ↔ Go
│       ├── subscription_service.dart← HTTP загрузка подписок
│       ├── storage_service.dart     ← SQLite через sqflite
│       ├── settings_service.dart    ← SharedPreferences
│       └── dtr_log.dart             ← кольцевой буфер логов (debug)
└── pubspec.yaml
```

---

## Архитектура

```
Flutter UI (Dart)
    ↓ MethodChannel "online.dtr.vpn/mihomo"
MainActivity.kt (Kotlin)
    ↓ startService(Intent)
DTRVpnService.kt (Android VpnService)
    ↓ JNI external fun (System.loadLibrary("clash"))
jni_bridge.c → libclash.so
    ↓ CGO
clash_ffi.go → github.com/metacubex/mihomo
```

### Channels Flutter ↔ Kotlin

| Channel | Тип | Назначение |
|---------|-----|------------|
| `online.dtr.vpn/mihomo` | MethodChannel | Команды: connect, disconnect, testDelay, getProxies... |
| `online.dtr.vpn/vpn_state` | EventChannel | Статус VPN: connected/connecting/disconnected/error |
| `online.dtr.vpn/traffic` | EventChannel | Скорость трафика каждую секунду `{"up":N,"down":N}` |
| `online.dtr.vpn/mihomo_log` | EventChannel | **NEW** Внутренние логи Mihomo (DNS, правила) каждые 500мс |

### JNI методы (external fun в DTRVpnService.kt)

```kotlin
initClash(homeDir: String)
startClash(config: String, fd: Int): String
stopClash()
isClashRunning(): Int
selectProxy(group: String, proxy: String): String
testDelay(proxyName: String, testUrl: String, timeoutMs: Int): Int
getProxies(): String
getTraffic(): String       // текущая скорость байт/сек
getTotalTraffic(): String  // суммарный трафик за сессию
forceGC()
validateConfig(config: String): String  // "" = OK, иначе ошибка
startLog()                              // подписаться на Mihomo logs
stopLog()                               // отписаться
getPendingLogs(): String                // JSON массив, очищает буфер
```

---

## Что было исправлено / добавлено (история)

### Баги

| # | Проблема | Причина | Фикс |
|---|----------|---------|------|
| 1 | YAML parse error line 17 | `_buildConfig` возвращает JSON, `injectTunConfig` приклеивал YAML сверху — смешение block/flow | `injectTunConfig` определяет формат по `{` и инжектит tun/dns как JSON-поля |
| 2 | Пинг всегда -1 | `iURLTest` имел неверную сигнатуру — в v1.18.8 URLTest возвращает `(uint16, uint16, error)` | Исправлена сигнатура, `delay, _, err := ut.URLTest(ctx, url, nil)` |
| 3 | Лаги при открытии клавиатуры | `AnimatedSwitcher` пересоздавал страницы | `IndexedStack` + `AutomaticKeepAliveClientMixin` |
| 4 | Поиск в прокси лагал при вводе | SearchBar не использовал debounce | Убран SearchBar целиком (не нужен) |
| 5 | Безлимит показывал "Истекла" | `expire=0` создавал дату 01.01.1970; `total=0` не обрабатывался | `expire=0` → `null`; `total=0` → безлимит |

### Добавлено из FlClashX

| Компонент | Что добавлено |
|-----------|---------------|
| **Go core** | `ValidateConfig()` — валидация конфига до запуска |
| **Go core** | `StartLog()` / `StopLog()` / `GetPendingLogs()` — поток внутренних логов Mihomo |
| **Go core** | `tunnel.ProxiesWithProviders()` вместо `Proxies()` — включает прокси из proxy-providers |
| **Kotlin** | `validateConfig` JNI + pre-validate в `startVpn()` перед запуском Mihomo |
| **Kotlin** | Log polling goroutine: `startLog()` → `getPendingLogs()` каждые 500мс → broadcast `online.dtr.vpn.MIHOMO_LOG` |
| **Flutter** | `mihomoLogStream` в `MihomoService` — EventChannel для Mihomo логов |
| **Flutter** | `MihomoLogEntry` класс — `{level, payload, time}` |
| **Flutter** | `subscription_service.dart` — парсит `support-url`, `announce`, `profile-update-interval` заголовки |
| **Flutter** | `dtr_log.dart` — централизованный кольцевой буфер 600 записей (только debug) |
| **Flutter** | `logs_page.dart` — страница просмотра DtrLog с фильтром/копированием |
| **Flutter** | `settings_page.dart` — раздел Debug с кнопкой Логи (только debug) |
| **Flutter** | Mihomo internal logs форвардятся в DtrLog как `D/Mihomo-Core` |

---

## Текущее состояние (что ОСТАЛОСЬ сделать)

### Критическое

- [ ] **Проверить что `tunnel.ProxiesWithProviders()` компилируется с mihomo v1.18.8** — если нет, fallback на `tunnel.Proxies()` с комментарием
- [ ] **Обновить `Profile` модель** — добавить поля `supportUrl`, `announceMsg`, `updateIntervalHours` в `profile.dart` и SQLite-схему в `storage_service.dart`
- [ ] **Показать `announceMsg`** в profiles_page.dart — FlClashX показывает баннер от провайдера
- [ ] **Показать кнопку `supportUrl`** в profile card — если URL начинается с `t.me/` показать иконку Telegram

### Функциональность

- [ ] **Страница логов Mihomo** — сейчас `logs_page.dart` показывает Flutter-side DtrLog. Нужно добавить вторую вкладку (или второй экран) для Mihomo internal logs из `mihomoLogStream`
- [ ] **Параллельный пинг всех серверов** — сейчас `_testAllDelays()` делает `Future.wait()` что уже параллельно, но ограничить до 10 одновременных (FlClashX использует batch 100)
- [ ] **Auto-update профилей** — сохранять `updateIntervalHours` из заголовка, запускать фоновое обновление
- [ ] **Подписанный release APK** — нужны GitHub Secrets: `KEYSTORE_BASE64`, `KEY_STORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`

### Улучшения

- [ ] **arm + x86_64 сборки** — сейчас только arm64-v8a
- [ ] **Кэш Flutter pub** в GitHub Actions

---

## Важные версии (проверенная связка)

| Компонент | Версия |
|-----------|--------|
| Flutter | stable 3.41.6 |
| Dart SDK | >=3.3.0 |
| Go | 1.22 |
| Mihomo | v1.18.8 |
| Android NDK | 26.1.10909125 |
| Gradle | 8.10.2 |
| AGP | 8.7.3 |
| Kotlin | 2.1.0 |
| Java | 17 (temurin) |
| compileSdk | 34 |
| minSdk | 21 |

---

## CI (GitHub Actions build.yml)

Шаги:
1. Checkout → Java 17 → Go 1.22 → Cache Go → Flutter stable
2. Setup NDK 26.1.10909125 (sdkmanager)
3. Create `android/local.properties` ← ОБЯЗАТЕЛЬНО ДО Gradle
4. **Build Mihomo core** (`./build_core.sh` → `libclash.so`)
5. `flutter pub get`
6. `flutter build apk --debug`
7. Upload artifact

`gradlew` хранится **в репозитории** — НЕ генерируется в CI.

---

## Известные особенности Mihomo конфига

Подписки бывают двух форматов:
1. **Обычный Clash/Mihomo YAML** — секция `proxies:`
2. **Remnawave inline** — секция `proxy-providers:` с `type: inline`

`_buildConfig()` обрабатывает оба. Результат — **JSON** (валидный YAML flow). `injectTunConfig()` в Kotlin определяет формат по `{` и инжектит `tun:` и `dns:` соответственно.

**ВАЖНО**: `log-level: info` в конфиге (не `warning`) — иначе Mihomo logs будут пустыми!

---

## Подписка — заголовки ответа сервера

```
subscription-userinfo: upload=X; download=Y; total=Z; expire=T
  total=0 → безлимит (показываем "∞ Безлимит", не прогресс-бар)
  expire=0 → бессрочно (не показываем дату)

support-url: https://t.me/channel  ← кнопка поддержки в карточке профиля
announce: Текст объявления          ← баннер в профиле
profile-update-interval: 24         ← авто-обновление раз в N часов
profile-title: <base64 или текст>   ← имя подписки
```

---

## Команды для разработки в Termux

```bash
# Основная директория
cd ~/dtrvpn

# Push и следим за CI
git add -A && git commit -m "..." && git push origin main
gh run watch --repo Nein-Ich-wurde-Gewinnen/DTRClient

# Запустить приложение локально (через USB debugging)
flutter run --debug

# Только собрать APK
flutter build apk --debug
```

---

## Для следующего Claude

Привет! Ты продолжаешь разрабатывать Android VPN-клиент **DTR VPN** (Flutter + Go/Mihomo).

**Репозиторий**: `~/dtrvpn` (GitHub: `Nein-Ich-wurde-Gewinnen/DTRClient`)
**Исходники FlClashX для референса**: `~/downloads/FlClashX` (уже клонирован)

### Первым делом

1. Проверь текущее состояние файлов командой: `find ~/dtrvpn -name "*.dart" -o -name "*.kt" -o -name "*.go" | xargs ls -la`
2. Спроси у пользователя: прошёл ли последний CI build успешно?
3. Если пользователь принёс архив с файлами — распакуй в `/home/claude` и изучи

### Приоритет задач

1. **Добавить `supportUrl`/`announceMsg` в модель `Profile`** и отображение в `profiles_page.dart`
2. **Страница Mihomo логов** — интегрировать `mihomoLogStream` в `logs_page.dart`
3. **Параллельный пинг** с лимитом concurrency
4. **Авто-обновление профилей** на основе `updateIntervalHours`
