#!/bin/bash
# ==========================================================
# Установка split-tunnel для корпоративных VPN Tradesoft
# (vpn2-ts, vpn3-ts) + автоматическая маршрутизация
# корпоративных подсетей и MySQL-серверов.
#
# Запуск:  sudo ./install.sh   (или ./install.sh — запросит sudo)
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
NETWORKS_CONF="/usr/local/etc/corp-networks.conf"
PREFS="/Library/Preferences/SystemConfiguration/preferences.plist"

fail=0

echo "==> Установка файлов демона..."
cp "$DIR/corp-vpn-routes.sh" "$DAEMON_SCRIPT"
chmod 755 "$DAEMON_SCRIPT"
cp "$DIR/com.tradesoft.corp-vpn-routes.plist" "$DAEMON_PLIST"
mkdir -p /usr/local/etc
cp "$DIR/corp-networks.conf" "$NETWORKS_CONF"
chmod 644 "$NETWORKS_CONF"

echo "==> Загрузка демона..."
if launchctl list | grep -q "$LABEL"; then
  launchctl unload "$DAEMON_PLIST" 2>/dev/null || true
fi
launchctl load -w "$DAEMON_PLIST"

echo "==> Применение split-режима (убираем OverridePrimary)..."
BIN="/tmp/split_fix_build"
swiftc -o "$BIN" "$DIR/split_fix.swift" 2>&1 | head -30
"$BIN"
rm -f "$BIN"

echo
echo "==> Проверка результата"

if launchctl list | grep -q "$LABEL"; then
  echo "  [OK]   демон $LABEL загружен"
else
  echo "  [FAIL] демон $LABEL не загружен"
  fail=1
fi

if [ -x "$DAEMON_SCRIPT" ]; then
  echo "  [OK]   скрипт $DAEMON_SCRIPT"
else
  echo "  [FAIL] скрипт $DAEMON_SCRIPT отсутствует"
  fail=1
fi

if [ -r "$NETWORKS_CONF" ]; then
  echo "  [OK]   конфиг корп. сетей $NETWORKS_CONF"
else
  echo "  [FAIL] конфиг $NETWORKS_CONF отсутствует"
  fail=1
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
    if 'OverridePrimary' in cfg:
        print('  [FAIL] ' + name + ': OverridePrimary всё ещё в конфиге')
        ok = False
    else:
        print('  [OK]   ' + name + ': split-режим (нет OverridePrimary)')
sys.exit(0 if ok else 1)
EOF
[ $? -eq 0 ] || fail=1

if [ "$fail" -eq 0 ]; then
  echo
  echo "Готово. Подключите vpn2-ts, vpn3-ts или vpn4 — корпоративные маршруты"
  echo "из /usr/local/etc/corp-networks.conf добавятся автоматически."
else
  echo
  echo "Есть ошибки — проверьте вывод выше."
  exit 1
fi
