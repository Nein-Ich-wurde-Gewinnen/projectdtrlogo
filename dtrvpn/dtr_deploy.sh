#!/data/data/com.termux/files/usr/bin/bash
# dtr_deploy.sh — запускать из Termux
# Пушит изменения → ждёт GitHub Actions → скачивает APK
set -e

REPO="Nein-Ich-wurde-Gewinnen/DTRClient"  # ← ПОМЕНЯЙ

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[DTR]${NC} $1"; }
warn() { echo -e "${YELLOW}[DTR]${NC} $1"; }
err()  { echo -e "${RED}[DTR]${NC} $1"; exit 1; }

# ── Зависимости ──────────────────────────────────────────────────────────────
command -v git >/dev/null || pkg install git -y
command -v gh  >/dev/null || pkg install gh -y

# ── Авторизация gh ────────────────────────────────────────────────────────────
if ! gh auth status >/dev/null 2>&1; then
    warn "Нужна авторизация GitHub CLI"
    gh auth login
fi

# ── Пуш ──────────────────────────────────────────────────────────────────────
log "Пушу изменения в GitHub..."
git add -A
git commit -m "build: $(date '+%d.%m.%Y %H:%M')" 2>/dev/null || log "Нечего коммитить"
git push

# ── Ждём запуска Actions ──────────────────────────────────────────────────────
log "Жду запуска GitHub Actions..."
sleep 5

RUN_ID=$(gh run list --repo "$REPO" --limit 1 --json databaseId --jq '.[0].databaseId')
log "Run ID: $RUN_ID"

# ── Ждём завершения ───────────────────────────────────────────────────────────
log "Жду завершения билда (~15-25 мин)..."
gh run watch "$RUN_ID" --repo "$REPO"

STATUS=$(gh run view "$RUN_ID" --repo "$REPO" --json conclusion --jq '.conclusion')
[ "$STATUS" = "success" ] || err "Билд упал! Смотри: https://github.com/$REPO/actions/runs/$RUN_ID"

# ── Скачать APK ───────────────────────────────────────────────────────────────
OUTDIR="$HOME/storage/downloads/DTR_APK"
mkdir -p "$OUTDIR"

log "Скачиваю APK..."
gh run download "$RUN_ID" --repo "$REPO" --dir "$OUTDIR"

log "✅ APK готов:"
ls -lh "$OUTDIR"/*.apk 2>/dev/null || ls -lh "$OUTDIR"/DTR-VPN-APK/

echo ""
log "Установка через ADB (если телефон подключён к ПК):"
echo "  adb install $OUTDIR/DTR-VPN-APK/DTR-VPN-debug-*.apk"
echo ""
log "Или открой файл-менеджер и установи вручную из Downloads/DTR_APK/"
