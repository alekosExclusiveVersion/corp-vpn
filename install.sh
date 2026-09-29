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
DIAG_LABEL="com.tradesoft.corp-vpn-diag"
DIAG_PLIST="/Library/LaunchDaemons/$DIAG_LABEL.plist"
DIAG_SCRIPT="/usr/local/sbin/corp-vpn-diagd.sh"
CLEAN_LABEL="com.tradesoft.corp-routes-clean"
CLEAN_PLIST="/Library/LaunchDaemons/$CLEAN_LABEL.plist"
CLEAN_SCRIPT="/usr/local/sbin/corp-routes-clean.sh"
CLEAN_LOG="/var/log/corp-routes-clean.log"
CLEAN_PREV="/var/run/corp-routes-clean.prev"
CLEAN_CUR="/var/run/corp-routes-clean.cur"
DB_CLEAN_LABEL="com.tradesoft.corp-db-clean"
DB_CLEAN_PLIST="/Library/LaunchDaemons/$DB_CLEAN_LABEL.plist"
DB_CLEAN_SCRIPT="/usr/local/sbin/corp-db-clean.sh"
DB_CLEAN_PY="/usr/local/sbin/db-clean-aisql.py"
DB_CLEAN_LOG="/var/log/corp-db-clean.log"
NOTIFY_LABEL="com.tradesoft.corp-notify"
NOTIFY_PLIST="/Users/aleksei/Library/LaunchAgents/$NOTIFY_LABEL.plist"
NOTIFY_SCRIPT="/usr/local/sbin/corp-notify.sh"
NOTIFY_UID="$(id -u aleksei 2>/dev/null || echo 501)"
SIGNALS="/var/run/corp-vpn-signals"
PREFS="/Library/Preferences/SystemConfiguration/preferences.plist"

DB_CLEAN_REPO="${DB_CLEAN_REPO:-$HOME/Work/scripts/db-clean}"

fail=0

echo "==> Самопроверка демона маршрутов (без root и без сети)..."
# Гейт перед установкой. selftest гоняет чистые функции на подставленных данных
# и ловит именно тот класс багов, что уже проскакивал в прод: неверный разбор
# POINTOPOINT-маски, обрезанная регулярка кандидатов, потерянный фильтр
# on-link подсетей TUN, потерявшийся fail-open в in_subnet. Провал означает,
# что арифметическое ядро демона неверно, а на нём стоят add_routes,
# assert_routes, del_routes, sweep и определение сессии.
# При провале демон НЕ устанавливается: в системе остаётся последняя рабочая
# версия, остальная установка доходит до конца и завершается exit 1.
ROUTES_SELFTEST_OK=1
if ! sh "$DIR/corp-vpn-routes.sh" --selftest; then
  ROUTES_SELFTEST_OK=0
  fail=1
fi
echo

echo "==> Самопроверка генератора Karing (без сети)..."
# karing-rules.sh -i пишет прямо в конфиг Karing, поэтому ошибка в нём
# молча уводит корп. трафик мимо туннеля, а откат виден только в UI Karing.
# Проверяем на подставленных фикстурах с подменёнными HOME/CORP_NETWORKS_CONF
# (живой конфиг не читается и не меняется).
if sh "$DIR/karing-rules.sh" --selftest; then
  KARING_SELFTEST_OK=1
else
  KARING_SELFTEST_OK=0
  fail=1
  echo "!! ПРОВАЛ самопроверки karing-rules.sh — правила для Karing"
  echo "!! могут быть неверны. Синхронизацию пока не выполняйте."
fi
echo

echo "==> Самопроверка сборщика доменов (без MySQL)..."
# collect-sites.py кормит SITE_DOMAINS, из которых karing-rules.sh строит
# direct-группу: ошибка в фильтре мусора заводит в Karing почтовые хосты
# и тестовые инстансы. Нужен интерпретатор с pymysql — берём venv приложения
# SQL Admin, иначе проверку пропускаем.
PY_SELFTEST=""
for cand in "$(dirname "$DIR")/parallels-sql-admins/.venv/bin/python" \
            /usr/local/bin/python3 python3; do
  if command -v "$cand" >/dev/null 2>&1 && \
     "$cand" -c 'import pymysql' >/dev/null 2>&1; then
    PY_SELFTEST="$cand"
    break
  fi
done
if [ -n "$PY_SELFTEST" ]; then
  if "$PY_SELFTEST" "$DIR/collect-sites.py" --selftest; then
    COLLECT_SELFTEST_OK=1
  else
    COLLECT_SELFTEST_OK=0
    fail=1
    echo "!! ПРОВАЛ самопроверки collect-sites.py — список SITE_DOMAINS"
    echo "!! может содержать мусор."
  fi
else
  COLLECT_SELFTEST_OK=0
  echo "-- интерпретатор с pymysql не найден, проверка пропущена"
fi
echo

echo "==> Установка файлов демона..."
if [ "$ROUTES_SELFTEST_OK" -eq 1 ]; then
  cp "$DIR/corp-vpn-routes.sh" "$DAEMON_SCRIPT"
  chmod 755 "$DAEMON_SCRIPT"
else
  echo "!! ПРОВАЛ самопроверки — $DAEMON_SCRIPT НЕ обновлён."
  echo "!! Осталась предыдущая версия (если демон был установлен ранее)."
  echo "!! У остальных компонентов неверная логика маршрутов может уводить"
  echo "!! корп. трафик в Karing мимо туннеля — проверь вывод selftest выше."
fi
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

echo "==> Установка демона-логгера корп. сети/VPN (пилот MAC-детекта)..."
cp "$DIR/corp-vpn-diagd.sh" "$DIAG_SCRIPT"
chmod 755 "$DIAG_SCRIPT"
cp "$DIR/com.tradesoft.corp-vpn-diag.plist" "$DIAG_PLIST"
if launchctl list | grep -q "$DIAG_LABEL"; then
  launchctl unload "$DIAG_PLIST" 2>/dev/null || true
fi
launchctl load -w "$DIAG_PLIST"

echo "==> Установка демона очистки мёртвых маршрутов (corp-routes-clean)..."
cp "$DIR/corp-routes-clean.sh" "$CLEAN_SCRIPT"
chmod 755 "$CLEAN_SCRIPT"
cp "$DIR/com.tradesoft.corp-routes-clean.plist" "$CLEAN_PLIST"
rm -f "$CLEAN_PREV" "$CLEAN_CUR"
: > "$CLEAN_LOG" 2>/dev/null || true
if launchctl list | grep -q "$CLEAN_LABEL"; then
  launchctl unload "$CLEAN_PLIST" 2>/dev/null || true
fi
launchctl load -w "$CLEAN_PLIST"

echo "==> Установка демона очистки БД aisql (db-clean) из $DB_CLEAN_REPO..."
if [ -x "$DB_CLEAN_REPO/install.sh" ]; then
  (cd "$DB_CLEAN_REPO" && ./install.sh)
else
  echo "  [FAIL] $DB_CLEAN_REPO/install.sh не найден — db-clean не устанавливается"
  fail=1
fi

echo "==> Установка юзер-агента уведомлений (corp-notify, LaunchAgent $NOTIFY_UID)..."
cp "$DIR/corp-notify.sh" "$NOTIFY_SCRIPT"
chmod 755 "$NOTIFY_SCRIPT"
mkdir -p /Users/aleksei/Library/LaunchAgents
cp "$DIR/com.tradesoft.corp-notify.plist" "$NOTIFY_PLIST"
chown aleksei:staff "$NOTIFY_PLIST"
rm -f "$SIGNALS" /tmp/corp-vpn-notify.pos /tmp/corp-vpn-notify.seen
if launchctl print "gui/$NOTIFY_UID/$NOTIFY_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$NOTIFY_UID" "$NOTIFY_PLIST" 2>/dev/null || true
fi
launchctl bootstrap "gui/$NOTIFY_UID" "$NOTIFY_PLIST"

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

if launchctl list | grep -q "$DIAG_LABEL"; then
  echo "  [OK]   демон $DIAG_LABEL загружен"
else
  echo "  [FAIL] демон $DIAG_LABEL не загружен"
  fail=1
fi

if [ -x "$DIAG_SCRIPT" ]; then
  echo "  [OK]   скрипт $DIAG_SCRIPT"
else
  echo "  [FAIL] скрипт $DIAG_SCRIPT отсутствует"
  fail=1
fi

if launchctl list | grep -q "$CLEAN_LABEL"; then
  echo "  [OK]   демон $CLEAN_LABEL загружен"
else
  echo "  [FAIL] демон $CLEAN_LABEL не загружен"
  fail=1
fi

if [ -x "$CLEAN_SCRIPT" ]; then
  echo "  [OK]   скрипт $CLEAN_SCRIPT"
else
  echo "  [FAIL] скрипт $CLEAN_SCRIPT отсутствует"
  fail=1
fi

if launchctl list | grep -q "$DB_CLEAN_LABEL"; then
  echo "  [OK]   демон $DB_CLEAN_LABEL загружен"
else
  echo "  [FAIL] демон $DB_CLEAN_LABEL не загружен"
  fail=1
fi

if [ -x "$DB_CLEAN_SCRIPT" ] && [ -x "$DB_CLEAN_PY" ]; then
  echo "  [OK]   скрипт $DB_CLEAN_SCRIPT"
else
  echo "  [FAIL] скрипт $DB_CLEAN_SCRIPT отсутствует"
  fail=1
fi

if launchctl print "gui/$NOTIFY_UID/$NOTIFY_LABEL" >/dev/null 2>&1; then
  echo "  [OK]   юзер-агент $NOTIFY_LABEL загружен"
else
  echo "  [FAIL] юзер-агент $NOTIFY_LABEL не загружен"
  fail=1
fi

if [ -x "$NOTIFY_SCRIPT" ]; then
  echo "  [OK]   скрипт $NOTIFY_SCRIPT"
else
  echo "  [FAIL] скрипт $NOTIFY_SCRIPT отсутствует"
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
  echo "Логгер сети/VPN — corp-vpn-diag (каждые 10с, /var/log/corp-vpn-diag.log)."
  echo "Очистка мёртвых маршрутов — corp-routes-clean (каждые 15с, /var/log/corp-routes-clean.log)."
  echo "Очистка БД aisql по заявкам Б24 — corp-db-clean (ежедневно 03:00, /var/log/corp-db-clean.log)."
  echo "Уведомления (Notification Center) — corp-notify (LaunchAgent, каждые 10с)."
else
  echo
  if [ "$ROUTES_SELFTEST_OK" -eq 0 ]; then
    echo "Есть ошибки. Главная: провалена самопроверка демона маршрутов"
    echo "(--selftest) — демон не обновлён, в системе предыдущая версия."
    echo "Правьте скрипт, пока selftest не станет зелёным, и запустите install.sh снова."
  else
    echo "Есть ошибки — проверьте вывод выше."
  fi
  exit 1
fi
