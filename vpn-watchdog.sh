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

PROFILES="vpn3-ts vpn4-ts vpn2-ts"

# Подключены ли к корп. Wi-Fi (en0 в подсети 192.168.128.0/24).
# На корп. Wi-Fi L2TP/IPSec не поднимается (сетевое оборудование глушит L2TP-в-ESP),
# поэтому корп. VPN там не подключаем — на этом Wi-Fi он бесполезен и только
# молотит попытки.
# Критерий по IP en0: корп. Wi-Fi единственный выдаёт подсеть 192.168.128.0/24.
# SSID/ассоциацию через networksetup здесь получить НЕЛЬЗЯ (отдаёт "not associated"
# даже при рабочей сети без DHCP), поэтому IP-детект — основной.
# ДОПОЛНИТЕЛЬНО (08.09): хотспот телефона раздаёт ту же 192.168.128.0/24, но
# приватный MAC en0 per-network отличается (корп b6:be:0c:d5:9a:24 vs хотспот
# 3e:e9:15:74:f3:be) — см. CORP_WIFI_EN0_MACS в конфиге.
#
# ПИЛОТ (сбор данных): хотспот телефона тоже раздаёт 192.168.128.0/24, поэтому
# по IP сети не различить. Вердикт решений оставляем прежним (по IP), а рядом
# логируем ARP-MAC реального шлюза и приватный MAC en0
# (corp-vpn: pilot [verdict] gw_mac=... mac_en0=...) через logger — раз в
# log-запись при смене. Решение НЕ меняется, пока списки
# CORP_WIFI_GATEWAY_MACS/CORP_WIFI_EN0_MACS не задействованы в логике.

# ARP-MAC реального шлюза (default через НЕ-туннельный интерфейс).
gw_mac() {
    local gw ifs
    ifs=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print}')
    [ -n "$ifs" ] || return 1
    gw=$(echo "$ifs" | awk '$NF!~/^utun/{print $2; exit}')
    [ -n "$gw" ] || gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
    [ -n "$gw" ] && [ "$gw" != "0.0.0.0" ] && [ "$gw" != "default" ] || return 1
    arp -n "$gw" 2>/dev/null | awk '{print $4; exit}'
}

PILOT_STATE=/tmp/corp-vpn-diagd/pilot-watchdog.last

# Приватный MAC en0 — per-network признак (стабилен в рамках сети/SSID).
en0_mac() { ifconfig en0 2>/dev/null | awk '/ether/{print $2; exit}'; }

pilot_log_verdict() {
    local gm line
    gm=$(gw_mac)
    line="$1 gw_mac=${gm:-?} mac_en0=$(en0_mac)"
    if [ ! -f "$PILOT_STATE" ] || [ "$(cat "$PILOT_STATE" 2>/dev/null)" != "$line" ]; then
        logger "corp-vpn: pilot $line"
        echo "$line" > "$PILOT_STATE"
    fi
}

CORP_WIFI_EN0_MACS_DEFAULT="b6:be:0c:d5:9a:24"
CORP_WIFI_GATEWAY_MACS_DEFAULT="54:b8:a:cf:80:0"

# Вердикт «корп. сеть»: корп, если per-network приватный MAC en0 ИЛИ ARP-MAC
# шлюза совпадает с эталонами (см. corp-networks.conf). Второй признак
# подстраховывает, но на хотспоте ARP-шлюза обычно не резолвится вовсе.
is_corp_wifi() {
    local ip verdict mac gm
    ip=$(ipconfig getifaddr en0 2>/dev/null)
    mac=$(en0_mac)
    gm=$(gw_mac)
    if [ -n "$ip" ] && [ -n "$mac" ]; then
        case " $CORP_WIFI_EN0_MACS_DEFAULT $CORP_WIFI_GATEWAY_MACS_DEFAULT " in
            *" $mac "*|*" $gm "*) verdict="corp" ;;
            *) verdict="not-corp" ;;
        esac
    else
        verdict="no-ip"
    fi
    pilot_log_verdict "$verdict"
    [ "$verdict" = "corp" ]
}

# Подключены ли к корп. сети по LAN-кабелю (проводное соединение).
# Ищем на НЕ-Wi-Fi интерфейсах (en0 = Wi-Fi) IP из корп. подсети 192.168.128.0/24.
# Проводные интерфейсы на этой машине — en4/en5/en6 (Thunderbolt Dock) и bridge0.
# Если любой не-Wi-Fi интерфейс получил корп. IP — LAN-кабель воткнут в корп. сеть,
# корп. ресурсы доступны напрямую, VPN не нужен.
is_corp_lan() {
    local iface ip
    for iface in $(ifconfig -lu 2>/dev/null); do
        # Пропускаем Wi-Fi (en0), туннели и служебные интерфейсы macOS,
        # чтобы ловить именно проводные Ethernet-интерфейсы.
        case "$iface" in
            en0|lo|utun*|gif*|stf*|anpi*|awdl*|llw*|ppp*|vnic*|ap*) continue ;;
        esac
        ip=$(ipconfig getifaddr "$iface" 2>/dev/null)
        if [ -n "$ip" ] && printf '%s' "$ip" | grep -qE '^192\.168\.128\.'; then
            return 0
        fi
    done
    return 1
}

# Корп. DNS и первый host:port из PROBE_HOSTS (обязаны маршрутизироваться через ppp0).
PROBE_DNS_IP="192.168.0.210"
PROBE_DNS_PORT=53
CONF=/usr/local/etc/corp-networks.conf
PROBE_HOSTS_DEFAULT="sup5.tradesoft.corp:4000"
if [ -f "$CONF" ] && grep -qE '^PROBE_HOSTS=' "$CONF"; then
    # Значение в конфиге в кавычках (PROBE_HOSTS="a:1 b:2 ...") — снимаем кавычки.
    PROBE_HOSTS_DEFAULT="$(grep -E '^PROBE_HOSTS=' "$CONF" | head -1 | cut -d= -f2- | tr -d '"' | awk '{print $1}')"
fi
# Эталоны корп. сети (приватный MAC en0 + ARP-MAC шлюза) — из конфига, если заданы.
for v in CORP_WIFI_EN0_MACS CORP_WIFI_GATEWAY_MACS; do
    if [ -f "$CONF" ] && grep -qE "^$v=" "$CONF"; then
        val=$(grep -E "^$v=" "$CONF" | head -1 | cut -d= -f2- | tr -d '"' | tr -d '\n')
        case "$v" in
            CORP_WIFI_EN0_MACS)   CORP_WIFI_EN0_MACS_DEFAULT="$val" ;;
            CORP_WIFI_GATEWAY_MACS) CORP_WIFI_GATEWAY_MACS_DEFAULT="$val" ;;
        esac
    fi
done
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

# "Туннель жив": ICMP-эхо из-под ppp0 (src = IP туннеля) до корп. DNS.
# НЕ используем TCP:53/UDP:53 — корп. DNS фильтрует TCP-запросы на 53,
# отчего старая проба всегда "взводила" ложный dead tunnel и watchdog
# каждые 30с молотил перезапуск (рестарт -> флап маршрутов -> чёрная дыра
# для RDP). ICMP по /32 через ppp0 — проверенный стабильный критерий.
tunnel_alive() {
    local srvip ok=""
    srvip=$(ifconfig ppp0 2>/dev/null | awk '/^[[:space:]]*inet /{print $2; exit}')
    [ -n "$srvip" ] || return 1
    for d in 192.168.0.210 192.168.0.220; do
        if ping -c 1 -t 3 -S "$srvip" "$d" >/dev/null 2>&1; then
            ok=1
            break
        fi
    done
    [ -n "$ok" ]
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

# --- Корп. Wi-Fi или LAN: VPN не поднимаем ---
# На корп. Wi-Fi L2TP/IPSec не работает (сеть глушит L2TP-в-ESP). На корп. LAN
# (проводное подключение) корп. ресурсы доступны напрямую — VPN не нужен.
# В обоих случаях, если профиль числится Connected — это зомби/бесполезный
# туннель, гасим его и не пытаемся поднять.
if is_corp_wifi; then
    for p in $PROFILES; do
        if [ "$(scutil --nc status "$p" 2>/dev/null | head -1)" = "Connected" ]; then
            scutil --nc stop "$p" 2>/dev/null
            logger "corp-vpn: $p torn down on corp Wi-Fi (L2TP blocked there)"
        fi
    done
    logger "corp-vpn: on corp Wi-Fi — VPN auto-connect skipped"
    exit 0
fi

if is_corp_lan; then
    for p in $PROFILES; do
        if [ "$(scutil --nc status "$p" 2>/dev/null | head -1)" = "Connected" ]; then
            scutil --nc stop "$p" 2>/dev/null
            logger "corp-vpn: $p torn down on corp LAN (wired, resources accessible directly)"
        fi
    done
    logger "corp-vpn: on corp LAN (wired) — VPN auto-connect skipped"
    exit 0
fi

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
