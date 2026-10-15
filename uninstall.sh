#!/bin/bash
# ==========================================================
# Полный откат split-tunnel для корпоративных VPN Tradesoft.
# Удаляет демон маршрутов и возвращает vpn2-ts/vpn3-ts
# в глобальный режим ("весь трафик через VPN").
#
# Запуск:  sudo ./uninstall.sh   (или ./uninstall.sh — запросит sudo)
# ==========================================================
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Требуются права root, запрашиваю через sudo..."
  exec sudo bash "$0" "$@"
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.tradesoft.corp-vpn-routes"
DAEMON_PLIST="/Library/LaunchDaemons/$LABEL.plist"
DAEMON_SCRIPT="/usr/local/sbin/corp-vpn-routes.sh"
STATE="/var/run/corp-vpn-routes.state"
NETWORKS_CONF="/usr/local/etc/corp-networks.conf"
LEARN_LABEL="com.tradesoft.corp-learn"
LEARN_PLIST="/Library/LaunchDaemons/$LEARN_LABEL.plist"
LEARN_SCRIPT="/usr/local/sbin/corp-learn.sh"
AUTO_NETWORKS_CONF="/usr/local/etc/corp-networks-auto.conf"
WIFI_LABEL="com.tradesoft.corp-wifi-routes"
WIFI_PLIST="/Library/LaunchDaemons/$WIFI_LABEL.plist"
WIFI_SCRIPT="/usr/local/sbin/corp-wifi-routes.sh"
WIFI_STATE="/var/run/corp-wifi-routes.state"
WATCHDOG_LABEL="com.tradesoft.corp-vpn-watchdog"
WATCHDOG_PLIST="/Library/LaunchDaemons/$WATCHDOG_LABEL.plist"
WATCHDOG_SCRIPT="/usr/local/sbin/vpn-watchdog.sh"
DIAG_LABEL="com.tradesoft.corp-vpn-diag"
DIAG_PLIST="/Library/LaunchDaemons/$DIAG_LABEL.plist"
DIAG_SCRIPT="/usr/local/sbin/corp-vpn-diagd.sh"
DIAG_LOG="/var/log/corp-vpn-diag.log"
DIAG_STATE="/tmp/corp-vpn-diagd"
CLEAN_LABEL="com.tradesoft.corp-routes-clean"
CLEAN_PLIST="/Library/LaunchDaemons/$CLEAN_LABEL.plist"
CLEAN_SCRIPT="/usr/local/sbin/corp-routes-clean.sh"
CLEAN_LOG="/var/log/corp-routes-clean.log"
CLEAN_PREV="/var/run/corp-routes-clean.prev"
CLEAN_CUR="/var/run/corp-routes-clean.cur"
CLEAN_PGPREV="/var/run/corp-routes-clean.phantom.prev"
CLEAN_PGCUR="/var/run/corp-routes-clean.phantom.cur"
DB_CLEAN_LABEL="com.tradesoft.corp-db-clean"
DB_CLEAN_PLIST="/Library/LaunchDaemons/$DB_CLEAN_LABEL.plist"
DB_CLEAN_SCRIPT="/usr/local/sbin/corp-db-clean.sh"
DB_CLEAN_PY="/usr/local/sbin/db-clean-aisql.py"
DB_CLEAN_LOG="/var/log/corp-db-clean.log"
NOTIFY_LABEL="com.tradesoft.corp-notify"
NOTIFY_PLIST="/Users/aleksei/Library/LaunchAgents/$NOTIFY_LABEL.plist"
NOTIFY_SCRIPT="/usr/local/sbin/corp-notify.sh"
NOTIFY_UID="$(id -u aleksei 2>/dev/null || echo 501)"
KWATCH_LABEL="com.tradesoft.corp-karing-watch"
KWATCH_PLIST="/Users/aleksei/Library/LaunchAgents/$KWATCH_LABEL.plist"
KWATCH_SCRIPT="/usr/local/sbin/corp-karing-watch.sh"
KWATCH_LOGDIR="/Users/aleksei/Library/Logs/corp-karing-watch"
SYNC_LABEL="com.tradesoft.corp-sites-sync"
SYNC_PLIST="/Users/aleksei/Library/LaunchAgents/$SYNC_LABEL.plist"
SYNC_SCRIPT="/usr/local/sbin/corp-sites-sync.sh"
SYNC_KEEP="/usr/local/etc/sites-keep.txt"
SYNC_LOGDIR="/Users/aleksei/Library/Logs/corp-sites-sync"
SIGNALS="/var/run/corp-vpn-signals"
PREFS="/Library/Preferences/SystemConfiguration/preferences.plist"

DB_CLEAN_REPO="${DB_CLEAN_REPO:-$HOME/Work/scripts/db-clean}"

fail=0

echo "==> Остановка и удаление демона..."
if launchctl list | grep -q "$LABEL"; then
  launchctl unload "$DAEMON_PLIST"
fi
rm -f "$DAEMON_PLIST" "$DAEMON_SCRIPT"
rm -f "$NETWORKS_CONF"

echo "==> Остановка и удаление демона автодетекта (corp-learn)..."
if launchctl list | grep -q "$LEARN_LABEL"; then
  launchctl unload "$LEARN_PLIST"
fi
rm -f "$LEARN_PLIST" "$LEARN_SCRIPT" "$AUTO_NETWORKS_CONF"

echo "==> Остановка и удаление демона маршрутизации при корп. Wi-Fi (corp-wifi-routes)..."
if launchctl list | grep -q "$WIFI_LABEL"; then
  launchctl unload "$WIFI_PLIST"
fi
rm -f "$WIFI_PLIST" "$WIFI_SCRIPT"
rm -f "$WIFI_STATE"

echo "==> Остановка и удаление демона-вачдога корп. VPN (vpn-watchdog)..."
if launchctl list | grep -q "$WATCHDOG_LABEL"; then
  launchctl unload "$WATCHDOG_PLIST"
fi
rm -f "$WATCHDOG_PLIST" "$WATCHDOG_SCRIPT"
rm -f /tmp/corp-vpn-watchdog.lock

echo "==> Остановка и удаление демона-логгера корп. сети/VPN (corp-vpn-diag)..."
if launchctl list | grep -q "$DIAG_LABEL"; then
  launchctl unload "$DIAG_PLIST"
fi
rm -f "$DIAG_PLIST" "$DIAG_SCRIPT"
rm -f "$DIAG_LOG" "${DIAG_LOG}.tmp" "${DIAG_LOG}.stdout.log" "${DIAG_LOG}.stderr.log"
rm -rf "$DIAG_STATE"

echo "==> Остановка и удаление демона очистки мёртвых маршрутов (corp-routes-clean)..."
if launchctl list | grep -q "$CLEAN_LABEL"; then
  launchctl unload "$CLEAN_PLIST"
fi
rm -f "$CLEAN_PLIST" "$CLEAN_SCRIPT"
rm -f "$CLEAN_LOG" "$CLEAN_PREV" "$CLEAN_CUR" "$CLEAN_PGPREV" "$CLEAN_PGCUR"

echo "==> Удаление демона очистки БД aisql (db-clean) из $DB_CLEAN_REPO..."
if [ -x "$DB_CLEAN_REPO/uninstall.sh" ]; then
  (cd "$DB_CLEAN_REPO" && ./uninstall.sh)
else
  echo "  [WARN] $DB_CLEAN_REPO/uninstall.sh не найден — пробуем вручную"
  if launchctl list | grep -q "$DB_CLEAN_LABEL"; then
    launchctl unload "$DB_CLEAN_PLIST"
  fi
  rm -f "$DB_CLEAN_PLIST" "$DB_CLEAN_SCRIPT" "$DB_CLEAN_PY"
  rm -f "$DB_CLEAN_LOG" "${DB_CLEAN_LOG}.stdout.log" "${DB_CLEAN_LOG}.stderr.log"
fi

echo "==> Остановка и удаление юзер-агента уведомлений (corp-notify)..."
if launchctl print "gui/$NOTIFY_UID/$NOTIFY_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$NOTIFY_UID" "$NOTIFY_PLIST" 2>/dev/null || true
fi
rm -f "$NOTIFY_PLIST" "$NOTIFY_SCRIPT"
rm -f "$SIGNALS" /tmp/corp-vpn-notify.pos /tmp/corp-vpn-notify.seen
rm -f /tmp/corp-notify.stdout.log /tmp/corp-notify.stderr.log

echo "==> Остановка и удаление юзер-агента вотчера Karing (corp-karing-watch)..."
if launchctl print "gui/$NOTIFY_UID/$KWATCH_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$NOTIFY_UID" "$KWATCH_PLIST" 2>/dev/null || true
fi
rm -f "$KWATCH_PLIST" "$KWATCH_SCRIPT"

echo "==> Остановка и удаление юзер-агента актуализации доменов (corp-sites-sync)..."
if launchctl print "gui/$NOTIFY_UID/$SYNC_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$NOTIFY_UID" "$SYNC_PLIST" 2>/dev/null || true
fi
rm -f "$SYNC_PLIST" "$SYNC_SCRIPT" "$SYNC_KEEP"
rm -rf "$SYNC_LOGDIR"

echo "==> Очистка маршрутов, добавленных демоном..."
if [ -f "$STATE" ]; then
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    route -n delete -host "$ip" >/dev/null 2>&1 || true
  done < "$STATE"
fi
rm -f "$STATE"
if [ -f "$WIFI_STATE" ]; then
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    route -n delete -host "$ip" >/dev/null 2>&1 || true
  done < "$WIFI_STATE"
fi
rm -f "$WIFI_STATE"
route -n delete -net 10.0.0.0/8 >/dev/null 2>&1 || true
route -n delete -net 192.168.0.0/16 >/dev/null 2>&1 || true

echo "==> Возврат глобального режима (OverridePrimary)..."
BIN="/tmp/split_restore_build"
swiftc -o "$BIN" "$DIR/split_restore.swift" 2>&1 | head -30
"$BIN"
rm -f "$BIN"

echo
echo "==> Проверка результата"

if launchctl list | grep -q "$LABEL"; then
  echo "  [FAIL] демон $LABEL всё ещё загружен"
  fail=1
else
  echo "  [OK]   демон $LABEL удалён"
fi

if [ -e "$DAEMON_SCRIPT" ] || [ -e "$DAEMON_PLIST" ]; then
  echo "  [FAIL] файлы демона остались на диске"
  fail=1
else
  echo "  [OK]   файлы демона удалены"
fi

if [ -e "$LEARN_SCRIPT" ] || [ -e "$LEARN_PLIST" ] || [ -e "$AUTO_NETWORKS_CONF" ]; then
  echo "  [FAIL] файлы демона автодетекта остались на диске"
  fail=1
else
  echo "  [OK]   файлы демона автодетекта удалены"
fi

if launchctl list | grep -q "$WIFI_LABEL"; then
  echo "  [FAIL] демон $WIFI_LABEL всё ещё загружен"
  fail=1
else
  echo "  [OK]   демон $WIFI_LABEL удалён"
fi

if [ -e "$WIFI_SCRIPT" ] || [ -e "$WIFI_PLIST" ] || [ -e "$WIFI_STATE" ]; then
  echo "  [FAIL] файлы демона wifi-routes остались на диске"
  fail=1
else
  echo "  [OK]   файлы демона wifi-routes удалены"
fi

if launchctl list | grep -q "$WATCHDOG_LABEL"; then
  echo "  [FAIL] демон $WATCHDOG_LABEL всё ещё загружен"
  fail=1
else
  echo "  [OK]   демон $WATCHDOG_LABEL удалён"
fi

if [ -e "$WATCHDOG_SCRIPT" ] || [ -e "$WATCHDOG_PLIST" ]; then
  echo "  [FAIL] файлы демона vpn-watchdog остались на диске"
  fail=1
else
  echo "  [OK]   файлы демона vpn-watchdog удалены"
fi

if launchctl list | grep -q "$DIAG_LABEL"; then
  echo "  [FAIL] демон $DIAG_LABEL всё ещё загружен"
  fail=1
else
  echo "  [OK]   демон $DIAG_LABEL удалён"
fi

if [ -e "$DIAG_SCRIPT" ] || [ -e "$DIAG_PLIST" ]; then
  echo "  [FAIL] файлы демона corp-vpn-diag остались на диске"
  fail=1
else
  echo "  [OK]   файлы демона corp-vpn-diag удалены"
fi

if launchctl list | grep -q "$CLEAN_LABEL"; then
  echo "  [FAIL] демон $CLEAN_LABEL всё ещё загружен"
  fail=1
else
  echo "  [OK]   демон $CLEAN_LABEL удалён"
fi

if [ -e "$CLEAN_SCRIPT" ] || [ -e "$CLEAN_PLIST" ] || [ -e "$CLEAN_LOG" ] || [ -e "$CLEAN_PREV" ] || [ -e "$CLEAN_CUR" ] || [ -e "$CLEAN_PGPREV" ] || [ -e "$CLEAN_PGCUR" ]; then
  echo "  [FAIL] файлы демона corp-routes-clean остались на диске"
  fail=1
else
  echo "  [OK]   файлы демона corp-routes-clean удалены"
fi

if launchctl list | grep -q "$DB_CLEAN_LABEL"; then
  echo "  [FAIL] демон $DB_CLEAN_LABEL всё ещё загружен"
  fail=1
else
  echo "  [OK]   демон $DB_CLEAN_LABEL удалён"
fi

if [ -e "$DB_CLEAN_SCRIPT" ] || [ -e "$DB_CLEAN_PLIST" ] || [ -e "$DB_CLEAN_PY" ]; then
  echo "  [FAIL] файлы демона corp-db-clean остались на диске"
  fail=1
else
  echo "  [OK]   файлы демона corp-db-clean удалены"
fi

if launchctl print "gui/$NOTIFY_UID/$NOTIFY_LABEL" >/dev/null 2>&1; then
  echo "  [FAIL] юзер-агент $NOTIFY_LABEL всё ещё загружен"
  fail=1
else
  echo "  [OK]   юзер-агент $NOTIFY_LABEL удалён"
fi

if [ -e "$NOTIFY_SCRIPT" ] || [ -e "$NOTIFY_PLIST" ]; then
  echo "  [FAIL] файлы юзер-агента corp-notify остались на диске"
  fail=1
else
  echo "  [OK]   файлы юзер-агента corp-notify удалены"
fi

if launchctl print "gui/$NOTIFY_UID/$KWATCH_LABEL" >/dev/null 2>&1; then
  echo "  [FAIL] юзер-агент $KWATCH_LABEL всё ещё загружен"
  fail=1
else
  echo "  [OK]   юзер-агент $KWATCH_LABEL удалён"
fi

if [ -e "$KWATCH_SCRIPT" ] || [ -e "$KWATCH_PLIST" ]; then
  echo "  [FAIL] файлы юзер-агента corp-karing-watch остались на диске"
  fail=1
else
  echo "  [OK]   файлы юзер-агента corp-karing-watch удалены"
fi

if launchctl print "gui/$NOTIFY_UID/$SYNC_LABEL" >/dev/null 2>&1; then
  echo "  [FAIL] юзер-агент $SYNC_LABEL всё ещё загружен"
  fail=1
else
  echo "  [OK]   юзер-агент $SYNC_LABEL удалён"
fi

if [ -e "$SYNC_SCRIPT" ] || [ -e "$SYNC_PLIST" ] || [ -e "$SYNC_KEEP" ] || [ -e "$SYNC_LOGDIR" ]; then
  echo "  [FAIL] файлы юзер-агента corp-sites-sync остались на диске"
  fail=1
else
  echo "  [OK]   файлы юзер-агента corp-sites-sync удалены"
fi

if [ -e "$NETWORKS_CONF" ]; then
  echo "  [FAIL] конфиг корп. сетей остался на диске"
  fail=1
else
  echo "  [OK]   конфиг корп. сетей удалён"
fi

python3 - "$PREFS" <<'EOF'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    d = plistlib.load(f)
targets = {
    'vpn2-ts': 'DF442B03-A55C-41F1-A590-740EC2FF0068',
    'vpn3-ts': 'D3B98206-61DC-4340-B0AC-A970F8B9C582',
    'vpn4-ts': '931E4155-0924-4D0B-B4F7-5F8D104E494B',
}
ok = True
for name, sid in targets.items():
    cfg = d['NetworkServices'].get(sid, {}).get('IPv4', {})
    if cfg.get('OverridePrimary'):
        print('  [OK]   ' + name + ': глобальный режим восстановлен')
    else:
        print('  [FAIL] ' + name + ': OverridePrimary отсутствует')
        ok = False
sys.exit(0 if ok else 1)
EOF
[ $? -eq 0 ] || fail=1

if [ "$fail" -eq 0 ]; then
  echo
  echo "Откат выполнен: демон удалён, VPN вернулись в глобальный режим."
else
  echo
  echo "Есть ошибки — проверьте вывод выше."
  exit 1
fi
