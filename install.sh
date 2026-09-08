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
LEARN_LABEL="com.tradesoft.corp-learn"
LEARN_PLIST="/Library/LaunchDaemons/$LEARN_LABEL.plist"
LEARN_SCRIPT="/usr/local/sbin/corp-learn.sh"
AUTO_NETWORKS_CONF="/usr/local/etc/corp-networks-auto.conf"
WIFI_LABEL="com.tradesoft.corp-wifi-routes"
WIFI_PLIST="/Library/LaunchDaemons/$WIFI_LABEL.plist"
WIFI_SCRIPT="/usr/local/sbin/corp-wifi-routes.sh"
WATCHDOG_LABEL="com.tradesoft.corp-vpn-watchdog"
WATCHDOG_PLIST="/Library/LaunchDaemons/$WATCHDOG_LABEL.plist"
WATCHDOG_SCRIPT="/usr/local/sbin/vpn-watchdog.sh"
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

echo "==> Установка демона автодетекта сайтов (corp-learn)..."
cp "$DIR/corp-learn.sh" "$LEARN_SCRIPT"
chmod 755 "$LEARN_SCRIPT"
cp "$DIR/com.tradesoft.corp-learn.plist" "$LEARN_PLIST"
if [ ! -f "$AUTO_NETWORKS_CONF" ]; then
  cat > "$AUTO_NETWORKS_CONF" <<'EOF'
# Автодетект corp-learn.sh: корп. сайты добавляются сюда автоматически по PTR.
# Домены, которые нужно сохранить навсегда, переносите в corp-networks.conf
# (SITE_DOMAINS). Строки вида "# " и пустые игнорируются.
EOF
fi
chmod 644 "$AUTO_NETWORKS_CONF"
if launchctl list | grep -q "$LEARN_LABEL"; then
  launchctl unload "$LEARN_PLIST" 2>/dev/null || true
fi
launchctl load -w "$LEARN_PLIST"

echo "==> Установка демона маршрутизации при корп. Wi-Fi (corp-wifi-routes)..."
cp "$DIR/corp-wifi-routes.sh" "$WIFI_SCRIPT"
chmod 755 "$WIFI_SCRIPT"
cp "$DIR/com.tradesoft.corp-wifi-routes.plist" "$WIFI_PLIST"
if launchctl list | grep -q "$WIFI_LABEL"; then
  launchctl unload "$WIFI_PLIST" 2>/dev/null || true
fi
launchctl load -w "$WIFI_PLIST"

echo "==> Установка демона-вачдога корп. VPN (автоподъём при обрыве)..."
cp "$DIR/vpn-watchdog.sh" "$WATCHDOG_SCRIPT"
chmod 755 "$WATCHDOG_SCRIPT"
cp "$DIR/com.tradesoft.corp-vpn-watchdog.plist" "$WATCHDOG_PLIST"
if launchctl list | grep -q "$WATCHDOG_LABEL"; then
  launchctl unload "$WATCHDOG_PLIST" 2>/dev/null || true
fi
launchctl load -w "$WATCHDOG_PLIST"

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

if launchctl list | grep -q "$LEARN_LABEL"; then
  echo "  [OK]   демон $LEARN_LABEL загружен"
else
  echo "  [FAIL] демон $LEARN_LABEL не загружен"
  fail=1
fi

if [ -x "$LEARN_SCRIPT" ]; then
  echo "  [OK]   скрипт автодетекта $LEARN_SCRIPT"
else
  echo "  [FAIL] скрипт автодетекта $LEARN_SCRIPT отсутствует"
  fail=1
fi

if launchctl list | grep -q "$WIFI_LABEL"; then
  echo "  [OK]   демон $WIFI_LABEL загружен"
else
  echo "  [FAIL] демон $WIFI_LABEL не загружен"
  fail=1
fi

if [ -x "$WIFI_SCRIPT" ]; then
  echo "  [OK]   скрипт $WIFI_SCRIPT"
else
  echo "  [FAIL] скрипт $WIFI_SCRIPT отсутствует"
  fail=1
fi

if launchctl list | grep -q "$WATCHDOG_LABEL"; then
  echo "  [OK]   демон $WATCHDOG_LABEL загружен"
else
  echo "  [FAIL] демон $WATCHDOG_LABEL не загружен"
  fail=1
fi

if [ -x "$WATCHDOG_SCRIPT" ]; then
  echo "  [OK]   скрипт $WATCHDOG_SCRIPT"
else
  echo "  [FAIL] скрипт $WATCHDOG_SCRIPT отсутствует"
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
    'vpn4-ts': '931E4155-0924-4D0B-B4F7-5F8D104E494B',
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
  echo "Готово. Подключите vpn1-ts, vpn2-ts, vpn3-ts или vpn4-ts — корпоративные маршруты"
  echo "из /usr/local/etc/corp-networks.conf добавятся автоматически."
  echo "При корп. Wi-Fi маршруты добавляются автоматически (corp-wifi-routes)."
  echo "Автоподъём VPN при обрыве — vpn-watchdog (каждые 30с)."
else
  echo
  echo "Есть ошибки — проверьте вывод выше."
  exit 1
fi
