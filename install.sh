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
ONDEMAND_LABEL="com.tradesoft.corp-vpn-ondemand"
ONDEMAND_PLIST="/Library/LaunchDaemons/$ONDEMAND_LABEL.plist"
ONDEMAND_SCRIPT="/usr/local/sbin/vpn-ondemand.py"
ONDEMAND_PORT=5354
RESOLVER_DIR="/etc/resolver"
DIAG_LABEL="com.tradesoft.corp-vpn-diag"
DIAG_PLIST="/Library/LaunchDaemons/$DIAG_LABEL.plist"
DIAG_SCRIPT="/usr/local/sbin/corp-vpn-diagd.sh"
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
SYNC_LABEL="com.tradesoft.corp-sites-sync"
SYNC_PLIST="/Users/aleksei/Library/LaunchAgents/$SYNC_LABEL.plist"
SYNC_SCRIPT="/usr/local/sbin/corp-sites-sync.sh"
SYNC_KEEP="/usr/local/etc/sites-keep.txt"
SYNC_LOGDIR="/Users/aleksei/Library/Logs/corp-sites-sync"
KWATCH_LABEL="com.tradesoft.corp-karing-watch"
KWATCH_PLIST="/Users/aleksei/Library/LaunchAgents/$KWATCH_LABEL.plist"
KWATCH_SCRIPT="/usr/local/sbin/corp-karing-watch.sh"
KWATCH_LOGDIR="/Users/aleksei/Library/Logs/corp-karing-watch"
# WatchPaths-агент: мгновенный синк Karing после правки корп. конфигов
# (тот же karing-watch.sh --sync, кулдаун не действует).
WSYNC_LABEL="com.tradesoft.corp-karing-sync-onchange"
WSYNC_PLIST="/Users/aleksei/Library/LaunchAgents/$WSYNC_LABEL.plist"
KRESTART_SCRIPT="/usr/local/sbin/corp-karing-restart.sh"
WAKEUP_SCRIPT="/Users/aleksei/.wakeup"
WAKE_LOGDIR="/Users/aleksei/Library/Logs/corp-vpn"
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

echo "==> Самопроверка чистки доменов (только stdlib)..."
# clean-sites.py удаляет из SITE_DOMAINS (при --apply), поэтому ошибка
# в нём — это потерянные корп. маршруты. Selftest на фикстурах, без сети.
if python3 "$DIR/clean-sites.py" --selftest; then
  CLEANSITES_SELFTEST_OK=1
else
  CLEANSITES_SELFTEST_OK=0
  fail=1
  echo "!! ПРОВАЛ самопроверки clean-sites.py — чистка списка доменов"
  echo "!! может снести лишнее."
fi
echo

echo "==> Самопроверка демона очистки мёртвых маршрутов (без root и без сети)..."
# corp-routes-clean.sh мутирует таблицу маршрутов от имени root, поэтому
# ошибка в нём — это отрезанный корп. трафик, а не косметика. Selftest гоняет
# сценарии A/B/C на подставных фикстурах с заглушками netstat/route и проверяет,
# что сценарий C по умолчанию только наблюдает (удаление выключено), а хост
# с настоящим шлюзом, utun-маршрут и on-link адрес не трогаются.
if sh "$DIR/corp-routes-clean.sh" --selftest; then
  CLEAN_SELFTEST_OK=1
else
  CLEAN_SELFTEST_OK=0
  fail=1
  echo "!! ПРОВАЛ самопроверки corp-routes-clean.sh — демон очистки"
  echo "!! маршрутов не обновлён, осталась предыдущая версия."
fi
echo

echo "==> Самопроверка вотчера Karing (без сети, без приложения)..."
# karing-watch.sh рестартует Karing и пишет в его конфиг через karing-rules
# -i: ошибка в логике кулдауна/гардов даст рестарт-луп или пропуск дрейфа.
# Selftest на фикстурах с подменёнными обёртками quit/open/apply/check.
if sh "$DIR/karing-watch.sh" --selftest; then
  KWATCH_SELFTEST_OK=1
else
  KWATCH_SELFTEST_OK=0
  fail=1
  echo "!! ПРОВАЛ самопроверки karing-watch.sh — вотчер дрейфа Karing"
  echo "!! не устанавливается."
fi
echo

echo "==> Самопроверка рестартера Karing (без приложения и без сети)..."
# Рестартер нужен wake-хуку: сразу после сна Karing остаётся «Connected» с
# мёртвым utun и держит default-маршрут в никуда. Проверяем чистую логику
# решений (force / if-dead / не запущен).
if sh "$DIR/karing-restart.sh" --selftest; then
  KRESTART_SELFTEST_OK=1
else
  KRESTART_SELFTEST_OK=0
  fail=1
  echo "!! ПРОВАЛ самопроверки karing-restart.sh — рестартер и wake-хук"
  echo "!! не устанавливаются."
fi
echo

echo "==> Самопроверка wake-хука (выбор лечения без сети)..."
# Проверяются решения «чем лечить»: мертва внешняя сеть и default в utun →
# закрыть Karing; жива внешняя, мертва корп. → переподключить L2TP; Karing уже
# закрыт / default не в utun → дело не в Karing. Ошибка здесь означает, что
# после сна хук будет лечить не ту причину и окно без сети снова растянется.
if sh "$DIR/reconnect-vpn-wake.sh" --selftest; then
  WAKE_SELFTEST_OK=1
else
  WAKE_SELFTEST_OK=0
  fail=1
  echo "!! ПРОВАЛ самопроверки reconnect-vpn-wake.sh — wake-хук НЕ обновляется."
fi
echo

echo "==> Самопроверка демона VPN on demand (без сети и без root)..."
# vpn-ondemand.py решает, поднимать ли L2TP, и пересылает DNS корп. зон.
# Ошибка в разборе зон/MAC-эталонов = ложные подъёмы VPN (в т.ч. на корп.
# Wi-Fi) или мёртвый DNS для корп. имён. Selftest — на чистых функциях.
if /usr/bin/python3 "$DIR/vpn-ondemand.py" --selftest; then
  ONDEMAND_SELFTEST_OK=1
else
  ONDEMAND_SELFTEST_OK=0
  fail=1
  echo "!! ПРОВАЛ самопроверки vpn-ondemand.py — демон и резолверы"
  echo "!! on-demand не устанавливаются."
fi
echo

echo "==> Самопроверка демона wifi-маршрутов (без root и без сети)..."
# Проверяются чистые функции пробуждения: после сна демон должен обновить кэш
# corp-IP и снять utun-пины Karing сразу, а не через 5 минут.
if sh "$DIR/corp-wifi-routes.sh" --selftest; then
  WIFI_SELFTEST_OK=1
else
  WIFI_SELFTEST_OK=0
  fail=1
  echo "!! ПРОВАЛ самопроверки corp-wifi-routes.sh — демон не обновляется."
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
if [ "${WIFI_SELFTEST_OK:-0}" -eq 1 ]; then
  cp "$DIR/corp-wifi-routes.sh" "$WIFI_SCRIPT"
  chmod 755 "$WIFI_SCRIPT"
else
  echo "!! ПРОВАЛ самопроверки — $WIFI_SCRIPT НЕ обновлён (осталась старая версия)."
fi
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

# Резолверы /etc/resolver: корп. зоны уходят на локальный демон on-demand.
# Чужие файлы не трогаем — удаляем только помеченные нашим комментарием.
install_ondemand_resolvers() {
    local zones z f
    mkdir -p "$RESOLVER_DIR" || return 1
    for f in "$RESOLVER_DIR"/*; do
        [ -f "$f" ] || continue
        if grep -q '^# corp-vpn on-demand' "$f" 2>/dev/null; then
            rm -f "$f"
        fi
    done
    # Зоны парсит сам демон (--zones): один источник правды с рантаймом.
    zones=$(CORP_NETWORKS_CONF="$NETWORKS_CONF" /usr/bin/python3 \
        "$DIR/vpn-ondemand.py" --zones 2>/dev/null)
    if [ -z "$zones" ]; then
        echo "  [FAIL] в $NETWORKS_CONF нет зон для $RESOLVER_DIR"
        return 1
    fi
    for z in $zones; do
        cat > "$RESOLVER_DIR/$z" <<EOF
# corp-vpn on-demand: корп. зона -> локальный демон (поднимает L2TP по спросу)
nameserver 127.0.0.1
port $ONDEMAND_PORT
EOF
        chmod 644 "$RESOLVER_DIR/$z"
    done
    echo "  [OK] резолверы on-demand: $(printf '%s\n' $zones | wc -l | tr -d ' ') зон"
    return 0
}

echo "==> Установка демона VPN on demand (DNS-триггер по корп. зонам)..."
# Демон слушает 127.0.0.1:5354 и поднимает L2TP, когда приходит DNS-запрос к
# корп. зоне. Резолверы ставим ТОЛЬКО после того, как порт реально слушается:
# иначе корп. имена останутся без DNS вообще.
if [ "${ONDEMAND_SELFTEST_OK:-0}" -eq 1 ]; then
  cp "$DIR/vpn-ondemand.py" "$ONDEMAND_SCRIPT"
  chmod 755 "$ONDEMAND_SCRIPT"
else
  echo "!! ПРОВАЛ самопроверки — $ONDEMAND_SCRIPT НЕ обновлён."
fi
cp "$DIR/com.tradesoft.corp-vpn-ondemand.plist" "$ONDEMAND_PLIST"
if launchctl list | grep -q "$ONDEMAND_LABEL"; then
  launchctl unload "$ONDEMAND_PLIST" 2>/dev/null || true
fi
launchctl load -w "$ONDEMAND_PLIST"
ONDEMAND_UP=0
for i in $(seq 1 10); do
  if nc -z 127.0.0.1 "$ONDEMAND_PORT" >/dev/null 2>&1; then
    ONDEMAND_UP=1
    break
  fi
  sleep 1
done
if [ "$ONDEMAND_UP" -eq 1 ]; then
  if install_ondemand_resolvers; then
    dscacheutil -flushcache 2>/dev/null || true
    killall -HUP mDNSResponder 2>/dev/null || true
  else
    fail=1
  fi
else
  echo "!! демон on-demand не слушает 127.0.0.1:$ONDEMAND_PORT — $RESOLVER_DIR НЕ меняю"
  echo "!! (корп. имена продолжат работать как раньше, через DNS VPN)"
  fail=1
fi

echo "==> Установка демона-логгера корп. сети/VPN (пилот MAC-детекта)..."
cp "$DIR/corp-vpn-diagd.sh" "$DIAG_SCRIPT"
chmod 755 "$DIAG_SCRIPT"
cp "$DIR/com.tradesoft.corp-vpn-diag.plist" "$DIAG_PLIST"
if launchctl list | grep -q "$DIAG_LABEL"; then
  launchctl unload "$DIAG_PLIST" 2>/dev/null || true
fi
launchctl load -w "$DIAG_PLIST"

echo "==> Установка демона очистки мёртвых маршрутов (corp-routes-clean)..."
if [ "$CLEAN_SELFTEST_OK" -eq 1 ]; then
  cp "$DIR/corp-routes-clean.sh" "$CLEAN_SCRIPT"
  chmod 755 "$CLEAN_SCRIPT"
else
  echo "!! ПРОВАЛ самопроверки — $CLEAN_SCRIPT НЕ обновлён."
  echo "!! (осталась предыдущая версия, если демон ставился ранее)"
fi
cp "$DIR/com.tradesoft.corp-routes-clean.plist" "$CLEAN_PLIST"
rm -f "$CLEAN_PREV" "$CLEAN_CUR" "$CLEAN_PGPREV" "$CLEAN_PGCUR"
: > "$CLEAN_LOG" 2>/dev/null || true
if launchctl list | grep -q "$CLEAN_LABEL"; then
  launchctl unload "$CLEAN_PLIST" 2>/dev/null || true
fi
launchctl load -w "$CLEAN_PLIST"

echo "==> Установка демона очистки БД aisql (db-clean) из $DB_CLEAN_REPO..."
# На macOS развёртывание db-clean выведено из эксплуатации (только Windows):
# его установщик выходит с SKIP и кодом 0 без файлов — это не провал,
# такие компоненты в проверке результата не участвуют.
DB_CLEAN_SKIP=0
if [ -x "$DB_CLEAN_REPO/install.sh" ]; then
  DB_CLEAN_OUT=$((cd "$DB_CLEAN_REPO" && ./install.sh) 2>&1)
  DB_CLEAN_RC=$?
  printf '%s\n' "$DB_CLEAN_OUT" | tail -3
  if [ "$DB_CLEAN_RC" -ne 0 ]; then
    echo "  [FAIL] установщик db-clean завершился с кодом $DB_CLEAN_RC"
    fail=1
  elif printf '%s\n' "$DB_CLEAN_OUT" | grep -q '^SKIP: db-clean на macOS'; then
    echo "  (db-clean пропущен на macOS, в проверке не участвует)"
    DB_CLEAN_SKIP=1
  fi
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

echo "==> Установка юзер-агента актуализации доменов (sites-sync, LaunchAgent $NOTIFY_UID)..."
# Контекст пользователя обязателен: Fernet-ключ servers.json лежит в его
# Keychain (root-демону недоступен). Привилегии — через ~/bin/sudo внутри.
if [ "${CLEANSITES_SELFTEST_OK:-0}" -eq 1 ]; then
  cp "$DIR/sites-sync.sh" "$SYNC_SCRIPT"
  chmod 755 "$SYNC_SCRIPT"
else
  echo "!! ПРОВАЛ самопроверки — $SYNC_SCRIPT НЕ обновлён."
  echo "!! (осталась предыдущая версия, если агент ставился ранее)"
fi
if [ ! -f "$SYNC_KEEP" ]; then
  # Шаблон в git — sites-keep.example.txt; sites-keep.txt (рабочий, в .gitignore)
  # используем как fallback для старых копий репозитория.
  KEEP_SRC="$DIR/sites-keep.example.txt"
  [ -f "$KEEP_SRC" ] || KEEP_SRC="$DIR/sites-keep.txt"
  if [ -f "$KEEP_SRC" ]; then
    cp "$KEEP_SRC" "$SYNC_KEEP"
    chmod 644 "$SYNC_KEEP"
    echo "  keep-файл создан из шаблона: $SYNC_KEEP"
  else
    echo "!! шаблон sites-keep.example.txt не найден — keep-файл не создан"
  fi
else
  echo "  (keep-файл уже есть, не перезаписываю: $SYNC_KEEP)"
fi
mkdir -p /Users/aleksei/Library/LaunchAgents
cp "$DIR/com.tradesoft.corp-sites-sync.plist" "$SYNC_PLIST"
chown aleksei:staff "$SYNC_PLIST"
mkdir -p "$SYNC_LOGDIR"
chown aleksei:staff "$SYNC_LOGDIR"
date +%s > "$SYNC_LOGDIR/last-ok"
chown aleksei:staff "$SYNC_LOGDIR/last-ok"
if launchctl print "gui/$NOTIFY_UID/$SYNC_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$NOTIFY_UID" "$SYNC_PLIST" 2>/dev/null || true
fi
launchctl bootstrap "gui/$NOTIFY_UID" "$SYNC_PLIST"

echo "==> Установка юзер-агента вотчера Karing (karing-watch, LaunchAgent $NOTIFY_UID)..."
# Каждые 10 мин + при логине: --check без VPN-гейта, при дрейфе -i
# с рестартом Karing (кулдаун 30 мин). Нужен на корп. Wi-Fi, где
# sites-sync не работает (требует поднятый VPN для MySQL-скана).
if [ "${KWATCH_SELFTEST_OK:-0}" -eq 1 ]; then
  cp "$DIR/karing-watch.sh" "$KWATCH_SCRIPT"
  chmod 755 "$KWATCH_SCRIPT"
else
  echo "!! ПРОВАЛ самопроверки — $KWATCH_SCRIPT НЕ обновлён."
  echo "!! (осталась предыдущая версия, если агент ставился ранее)"
fi
mkdir -p /Users/aleksei/Library/LaunchAgents
cp "$DIR/com.tradesoft.corp-karing-watch.plist" "$KWATCH_PLIST"
chown aleksei:staff "$KWATCH_PLIST"
mkdir -p "$KWATCH_LOGDIR"
chown aleksei:staff "$KWATCH_LOGDIR"
if launchctl print "gui/$NOTIFY_UID/$KWATCH_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$NOTIFY_UID" "$KWATCH_PLIST" 2>/dev/null || true
fi
launchctl bootstrap "gui/$NOTIFY_UID" "$KWATCH_PLIST"

echo "==> Установка агента WatchPaths (синк Karing сразу после правки конфигов)..."
# Не ждём плановых прогонов: правка /usr/local/etc/corp-networks.conf
# (или -auto) запускает karing-watch.sh --sync. VPN/Wi-Fi не нужны.
cp "$DIR/com.tradesoft.corp-karing-sync-onchange.plist" "$WSYNC_PLIST"
chown aleksei:staff "$WSYNC_PLIST"
if launchctl print "gui/$NOTIFY_UID/$WSYNC_LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$NOTIFY_UID" "$WSYNC_PLIST" 2>/dev/null || true
fi
launchctl bootstrap "gui/$NOTIFY_UID" "$WSYNC_PLIST"

echo "==> Установка рестартера Karing и wake-хука (~/.wakeup для sleepwatcher)..."
# karing-restart.sh — user-level рестарт Karing (вызывает ~/.wakeup сразу после
# сна). ~/.wakeup теперь ставится install.sh, а не руками: раньше копия в
# домашнем каталоге расходилась с репозиторием, и правки логики wake не
# доезжали до sleepwatcher.
if [ "${KRESTART_SELFTEST_OK:-0}" -eq 1 ]; then
  cp "$DIR/karing-restart.sh" "$KRESTART_SCRIPT"
  chmod 755 "$KRESTART_SCRIPT"
else
  echo "!! ПРОВАЛ самопроверки — $KRESTART_SCRIPT НЕ обновлён."
fi
mkdir -p "$WAKE_LOGDIR"
chown aleksei:staff "$WAKE_LOGDIR"
# Каталог логов/маркера должен быть доступен пользователю на запись: маркер
# ставит ~/.wakeup, читают его root-демоны.
chmod 755 "$WAKE_LOGDIR"
# Бэкапим только НЕ нашу версию: иначе повторный install затрёт оригинал
# (uninstall восстанавливает именно .bak).
if [ -f "$WAKEUP_SCRIPT" ] && ! grep -q "CORP_WAKE_MARKER" "$WAKEUP_SCRIPT" 2>/dev/null; then
  cp -p "$WAKEUP_SCRIPT" "$WAKEUP_SCRIPT.bak"
fi
if [ "${WAKE_SELFTEST_OK:-0}" -eq 1 ]; then
  cp "$DIR/reconnect-vpn-wake.sh" "$WAKEUP_SCRIPT"
  chmod 755 "$WAKEUP_SCRIPT"
  chown aleksei:staff "$WAKEUP_SCRIPT"
  echo "  [OK]   $WAKEUP_SCRIPT обновлён (бэкап: $WAKEUP_SCRIPT.bak)"
else
  echo "!! ПРОВАЛ самопроверки — $WAKEUP_SCRIPT НЕ обновлён (осталась прежняя версия)."
fi

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

if launchctl list | grep -q "$ONDEMAND_LABEL"; then
  echo "  [OK]   демон $ONDEMAND_LABEL загружен"
else
  echo "  [FAIL] демон $ONDEMAND_LABEL не загружен"
  fail=1
fi

if [ -x "$ONDEMAND_SCRIPT" ]; then
  echo "  [OK]   скрипт $ONDEMAND_SCRIPT"
else
  echo "  [FAIL] скрипт $ONDEMAND_SCRIPT отсутствует"
  fail=1
fi

res_count=$(grep -l '^# corp-vpn on-demand' "$RESOLVER_DIR"/* 2>/dev/null | wc -l | tr -d ' ')
if [ "${res_count:-0}" -gt 0 ]; then
  echo "  [OK]   резолверы on-demand: $res_count зон в $RESOLVER_DIR"
else
  echo "  [FAIL] в $RESOLVER_DIR нет резолверов on-demand"
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

if [ "$DB_CLEAN_SKIP" -eq 1 ]; then
  echo "  [--]   db-clean пропущен на macOS"
else
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

if launchctl print "gui/$NOTIFY_UID/$SYNC_LABEL" >/dev/null 2>&1; then
  echo "  [OK]   юзер-агент $SYNC_LABEL загружен"
else
  echo "  [FAIL] юзер-агент $SYNC_LABEL не загружен"
  fail=1
fi

if [ -x "$SYNC_SCRIPT" ]; then
  echo "  [OK]   скрипт $SYNC_SCRIPT"
else
  echo "  [FAIL] скрипт $SYNC_SCRIPT отсутствует"
  fail=1
fi

if launchctl print "gui/$NOTIFY_UID/$KWATCH_LABEL" >/dev/null 2>&1; then
  echo "  [OK]   юзер-агент $KWATCH_LABEL загружен"
else
  echo "  [FAIL] юзер-агент $KWATCH_LABEL не загружен"
  fail=1
fi

if [ -x "$KWATCH_SCRIPT" ]; then
  echo "  [OK]   скрипт $KWATCH_SCRIPT"
else
  echo "  [FAIL] скрипт $KWATCH_SCRIPT отсутствует"
  fail=1
fi

if launchctl print "gui/$NOTIFY_UID/$WSYNC_LABEL" >/dev/null 2>&1; then
  echo "  [OK]   юзер-агент $WSYNC_LABEL загружен"
else
  echo "  [FAIL] юзер-агент $WSYNC_LABEL не загружен"
  fail=1
fi

if [ -x "$KRESTART_SCRIPT" ]; then
  echo "  [OK]   скрипт рестарта Karing $KRESTART_SCRIPT"
else
  echo "  [FAIL] скрипт $KRESTART_SCRIPT отсутствует"
  fail=1
fi

if [ -x "$WAKEUP_SCRIPT" ]; then
  echo "  [OK]   wake-хук $WAKEUP_SCRIPT"
else
  echo "  [FAIL] wake-хук $WAKEUP_SCRIPT отсутствует/не исполняемый"
  fail=1
fi

if [ -w "$WAKE_LOGDIR" ]; then
  echo "  [OK]   каталог маркера/логов wake $WAKE_LOGDIR"
else
  echo "  [FAIL] $WAKE_LOGDIR недоступен на запись пользователю (маркер wake не создастся)"
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
  echo "VPN on demand — vpn-ondemand (DNS корп. зон поднимает туннель, простой 10 мин гасит)."
  echo "Ручной спрос для доступа по IP — corp-vpn.sh start (удержание 30 мин)."

  echo "Логгер сети/VPN — corp-vpn-diag (каждые 10с, /var/log/corp-vpn-diag.log)."
  echo "Очистка мёртвых маршрутов — corp-routes-clean (каждые 15с, /var/log/corp-routes-clean.log)."
  echo "Очистка БД aisql по заявкам Б24 — corp-db-clean (только Windows; на macOS пропущен)."
  echo "Уведомления (Notification Center) — corp-notify (LaunchAgent, каждые 10с)."
echo "Актуализация доменов — corp-sites-sync (LaunchAgent, 08:00/14:00/20:00 + догон)."
echo "Вотчер Karing — corp-karing-watch (LaunchAgent, каждые 10 мин + при логине)."
echo "После сна: ~/.wakeup (sleepwatcher) ставит маркер wake для демонов,"
echo "перезапускает Karing и проверяет сеть с повторами (лог ~/Library/Logs/corp-vpn/wake.log)."
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
