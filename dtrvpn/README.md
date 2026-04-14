# DTR VPN — Клиент на базе Mihomo

Flutter-приложение с нативным Go-ядром Mihomo для Android.

---

## Структура проекта

```
dtrvpn/
├── lib/
│   ├── main.dart                    # Точка входа, тема
│   ├── models/
│   │   ├── profile.dart             # Модель подписки
│   │   ├── proxy_node.dart          # Модель прокси-ноды
│   │   └── vpn_state.dart           # Состояние VPN
│   ├── pages/
│   │   ├── home_page.dart           # 2 вкладки: Прокси + Профили
│   │   ├── profiles_page.dart       # Управление подписками
│   │   └── proxies_page.dart        # Список хостов + подключение
│   └── services/
│       ├── storage_service.dart     # SQLite хранилище
│       ├── subscription_service.dart # Загрузка/парсинг YAML конфигов
│       └── mihomo_service.dart      # Мост Flutter↔Go через MethodChannel
├── core/
│   ├── clash_ffi.go                 # Go CGo обёртка над Mihomo
│   └── go.mod
├── android/
│   └── app/src/main/kotlin/online/dtr/vpn/
│       ├── MainActivity.kt          # MethodChannel + EventChannel
│       └── DTRVpnService.kt         # Android VpnService + TUN
├── .github/workflows/build.yml      # GitHub Actions CI/CD
├── build_core.sh                    # Сборка libclash.so локально
└── dtr_deploy.sh                    # Termux: пуш + скачать APK
```

---

## Сборка через GitHub Actions (основной способ из Termux)

### 1. Форкнуть/создать репо

```bash
# Установить инструменты в Termux
pkg install git gh -y

# Авторизоваться в GitHub
gh auth login
# → GitHub.com → HTTPS → Login with a web browser

# Создать репо и запушить
cd dtrvpn
git init
git add -A
git commit -m "init: DTR VPN"
gh repo create DTRClient --private --source=. --push
```

### 2. Исправить имя репо в dtr_deploy.sh

```bash
nano dtr_deploy.sh
# Поменяй строку: REPO="ТВОЙ_ЮЗЕР/DTRClient"
```

### 3. Запустить деплой

```bash
chmod +x dtr_deploy.sh
./dtr_deploy.sh
```

Скрипт сам: запушит → подождёт GitHub Actions (~20 мин) → скачает APK в `~/storage/downloads/DTR_APK/`

### 4. Установить APK

Открой в файл-менеджере `Downloads/DTR_APK/DTR-VPN-debug-*.apk` и установи.  
Разреши установку из неизвестных источников если попросит.

---

## Сборка локально (нужен Linux с Go + NDK)

```bash
# 1. Установить Go 1.22+
# https://go.dev/dl/

# 2. Установить Android SDK + NDK r26d
# export ANDROID_NDK_HOME=/path/to/ndk

# 3. Установить Flutter
# https://docs.flutter.dev/get-started/install/linux

# 4. Собрать Go-ядро
chmod +x build_core.sh
./build_core.sh
# → android/app/src/main/jniLibs/arm64-v8a/libclash.so

# 5. Собрать Flutter APK
flutter pub get
flutter build apk --debug --target-platform android-arm64
# APK: build/app/outputs/flutter-apk/app-debug.apk

# 6. Установить
adb install build/app/outputs/flutter-apk/app-debug.apk
```

---

## Добавление подписки DTR

При первом запуске нажми "Добавить" и вставь URL:
```
https://sub.api-dtr.online/sub/ZR68tC5yKgeNhnq5DhL6V64W6
```

Профиль скачается автоматически. Активируй его нажав на карточку.  
Перейди на вкладку Прокси — увидишь все хосты DTR1/DTR2/DTR3.

---

## Подпись APK для production

```bash
# Сгенерировать keystore
keytool -genkey -v -keystore dtr.jks -keyalg RSA -keysize 2048 \
        -validity 10000 -alias dtr

# Закодировать в base64 и добавить в GitHub Secrets:
base64 dtr.jks | tr -d '\n'
# → KEYSTORE_BASE64

# GitHub → Settings → Secrets → Actions:
# KEYSTORE_BASE64 = base64-строка
# KEY_STORE_PASSWORD = пароль keystore
# KEY_ALIAS = dtr
# KEY_PASSWORD = пароль ключа
```

---

## Следующие шаги

- [ ] Кастомная иконка
- [ ] Экран настроек (DNS, режим TUN/System Proxy)
- [ ] Split tunneling (исключить приложения из VPN)
- [ ] Автовыбор быстрейшего прокси
- [ ] Виджет состояния на рабочем столе
