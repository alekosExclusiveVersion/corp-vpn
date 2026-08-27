#!/bin/bash
# Watchdog: держит один активный корпоративный VPN (L2TP/IPSec).
# Профили — это L2TP-сервисы. Подключаются через networksetup
# -connectpppoeservice (проверенный рабочий метод для L2TP на этой машине;
# scutil --nc start для L2TP не работает — keychain PSK).
#
# Две задачи:
#  A2) Детект смены сети по IP en0: туннель L2TP/IPSec привязан к IP физического
#      интерфейса, поэтому при смене Wi-Fi (телефон -> корп и т.п.) он умирает,
#      но configd может ещё держать stale "Connected". При смене IP en0 сразу
#      принудительно переподключаем (scutil --nc status тут не помощник).
#  A1) Liveness-проба: если сеть не менялась, но корп. таргеты (корп DNS
#      192.168.0.210:53 и первый из PROBE_HOSTS через ppp0) не отвечают два тика
#      подряд — это "зомби-Connected" (туннель числится Connected, трафик мёртв).
#      Тогда тоже принудительно переподключаем.
#
# Запускается LaunchDaemon'ом com.tradesoft.corp-vpn-watchdog каждые 30с.

LOCK=/tmp/corp-vpn-watchdog.lock
if ! mkdir "$LOCK" 2>/dev/null; then
    [ -z "$(find "$LOCK" -mmin +3 2>/dev/null)" ] && exit 0
    rmdir "$LOCK" 2>/dev/null || exit 0
    mkdir "$LOCK" || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

PROFILES="vpn3-ts vpn4 vpn2-ts"

# Корп. DNS и первый host:port из PROBE_HOSTS (обязаны маршрутизироваться через ppp0).
PROBE_DNS_IP="192.168.0.210"
PROBE_DNS_PORT=53
CONF=/usr/local/etc/corp-networks.conf
PROBE_HOSTS_DEFAULT="sup5.tradesoft.corp:4000"
if [ -f "$CONF" ] && grep -qE '^PROBE_HOSTS=' "$CONF"; then
    # Значение в конфиге в кавычках (PROBE_HOSTS="a:1 b:2 ...") — снимаем кавычки.
    PROBE_HOSTS_DEFAULT="$(grep -E '^PROBE_HOSTS=' "$CONF" | head -1 | cut -d= -f2- | tr -d '"' | awk '{print $1}')"
fi
PROBE_HOST="${PROBE_HOSTS_DEFAULT%:*}"
PROBE_PORT="${PROBE_HOSTS_DEFAULT##*:}"

STATE_DIR=/tmp/corp-vpn-watchdog-state
mkdir -p "$STATE_DIR" 2>/dev/null
LAST_IP_FILE="$STATE_DIR/last_en0_ip"
FAIL_FILE="$STATE_DIR/consec_fail"

# Текущий IP физического интерфейса en0 (канал к интернету/корп Wi-Fi).
en0_ip() {
    ipconfig getifaddr en0 2>/dev/null
}

# "Туннель жив": оба корп. таргета отвечают (через ppp0). Корп Wi-Fi изолирован,
# поэтому недоступность обоих = туннель мёртв, а не сеть.
tunnel_alive() {
    nc -z -G 3 "$PROBE_DNS_IP" "$PROBE_DNS_PORT" >/dev/null 2>&1 || return 1
    nc -z -G 3 "$PROBE_HOST" "$PROBE_PORT" >/dev/null 2>&1
}

# Принудительный перезапуск профиля (сброс stale-состояния + подъём заново).
restart_profile() {
    local p="$1"
    scutil --nc stop "$p" 2>/dev/null
    sleep 2
    if command -v networksetup >/dev/null 2>&1; then
        networksetup -connectpppoeservice "$p" 2>/dev/null
    else
        scutil --nc start "$p" 2>/dev/null
    fi
    for i in $(seq 1 10); do
        sleep 2
        if [ "$(scutil --nc status "$p" 2>/dev/null | head -1)" = "Connected" ]; then
            return 0
        fi
    done
    return 1
}

# --- Состояние с прошлого тика ---
last_ip="$(cat "$LAST_IP_FILE" 2>/dev/null)"
cur_ip="$(en0_ip)"
old_ip="$last_ip"
echo "$cur_ip" > "$LAST_IP_FILE"
last_ip="$old_ip"

# --- Какой профиль сейчас числится Connected? ---
connected=""
for p in $PROFILES; do
    if [ "$(scutil --nc status "$p" 2>/dev/null | head -1)" = "Connected" ]; then
        connected="$p"
        break
    fi
done

if [ -n "$connected" ]; then
    # A2: смена IP en0 => туннель гарантированно мёртв, перезапускаем сразу.
    if [ -n "$last_ip" ] && [ -n "$cur_ip" ] && [ "$cur_ip" != "$last_ip" ]; then
        logger "corp-vpn: en0 IP changed ($last_ip -> $cur_ip), restarting $connected"
        if restart_profile "$connected"; then
            logger "corp-vpn: $connected reconnected after network change"
        else
            logger "corp-vpn: failed to reconnect $connected after network change"
        fi
        echo 0 > "$FAIL_FILE"
        exit 0
    fi

    # A1: сеть не менялась, проверяем живость трафика.
    if tunnel_alive; then
        echo 0 > "$FAIL_FILE"
        exit 0
    fi
    # Проба провалилась — считаем подряд идущие неудачи.
    fail=$(cat "$FAIL_FILE" 2>/dev/null); fail=${fail:-0}
    fail=$((fail + 1))
    echo "$fail" > "$FAIL_FILE"
    if [ "$fail" -ge 2 ]; then
        logger "corp-vpn: dead tunnel detected (probe failed $fail times), restarting $connected"
        if restart_profile "$connected"; then
            logger "corp-vpn: $connected reconnected after dead-tunnel restart"
        else
            logger "corp-vpn: failed to reconnect $connected (dead tunnel)"
        fi
        echo 0 > "$FAIL_FILE"
    fi
    exit 0
fi

# Нет активного профиля — поднимаем по приоритету (existing logic).
for p in $PROFILES; do
    if command -v networksetup >/dev/null 2>&1; then
        networksetup -connectpppoeservice "$p" 2>/dev/null
    else
        scutil --nc start "$p" 2>/dev/null
    fi
    for i in $(seq 1 10); do
        sleep 2
        if [ "$(scutil --nc status "$p" 2>/dev/null | head -1)" = "Connected" ]; then
            logger "corp-vpn: $p auto-connected by watchdog"
            exit 0
        fi
    done
    scutil --nc stop "$p" 2>/dev/null
done

logger "corp-vpn: watchdog failed to connect any profile"
