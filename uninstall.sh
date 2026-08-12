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
PREFS="/Library/Preferences/SystemConfiguration/preferences.plist"

fail=0

echo "==> Остановка и удаление демона..."
if launchctl list | grep -q "$LABEL"; then
  launchctl unload "$DAEMON_PLIST"
fi
rm -f "$DAEMON_PLIST" "$DAEMON_SCRIPT"
rm -f "$NETWORKS_CONF"

echo "==> Очистка маршрутов, добавленных демоном..."
if [ -f "$STATE" ]; then
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    route -n delete -host "$ip" >/dev/null 2>&1 || true
  done < "$STATE"
fi
rm -f "$STATE"
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
