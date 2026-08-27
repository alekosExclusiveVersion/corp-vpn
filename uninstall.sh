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
PREFS="/Library/Preferences/SystemConfiguration/preferences.plist"

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
    'vpn4': '931E4155-0924-4D0B-B4F7-5F8D104E494B',
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
