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
#  A1) Liveness-проба: если сеть не менялась, но корп. таргеты не отвечают
#      два тика подряд — это "зомби-Connected" (туннель числится Connected,
#      трафик мёртв). Тогда принудительно переподключаем. Мёртвый туннель =
#      провал ВСЕХ каналов пробы (ICMP до корп DNS, TCP до b24:443) —
#      только по ICMP kill'ить нельзя (20.10.2026 это рвало живые туннели,
#      когда сервер переставал пинговаться); DNS-канал убран — его может
#      подменить DNS-хайджек Karing'а (вечер 20.10.2026).
#
# Запускается LaunchDaemon'ом com.tradesoft.corp-vpn-watchdog каждые 30с.
#
# Guard «Mac спит?» (DarkWake, добавлен 29.10.2026): LaunchDaemon с StartInterval
# тикает и в DarkWake (lid закрыт, пользователь не активен — «Mac спит»). Без
# guard'а watchdog в такой момент видел «нет Connected-профиля» и молотил
# авто-подключение L2TP — отсюда «ночные» попытки в 00:xx/02:xx/03:xx при
# спящем Mac. Восстановление после сна делает wake-хук (~/.wakeup); watchdog
# в сне просто выходит. См. §3.6.1 CORP-VPN-SETUP.md.

LOCK=/tmp/corp-vpn-watchdog.lock
if ! mkdir "$LOCK" 2>/dev/null; then
    [ -z "$(find "$LOCK" -mmin +3 2>/dev/null)" ] && exit 0
    rmdir "$LOCK" 2>/dev/null || exit 0
    mkdir "$LOCK" || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# --- Guard «Mac спит?» (DarkWake) — корень «ночных» авто-подключений (29.10.2026) ---
# Аналог guard'а из ~/.wakeup (reconnect-vpn-wake.sh, fix 3f7c6ec): LaunchDaemon
# watchdog (StartInterval 30, RunAtLoad) получает тики и в DarkWake — крышка
# закрыта, пользователь не активен, для пользователя это «Mac спит», а по powerd
# это поддерживающий режим (maintenance). Watchdog без guard'а не знает о сне:
# в состоянии сна/no-IP у него нет Connected-профиля -> попадает в авто-подключение
# и молотит networksetup -connectpppoeservice (ночные попытки в 00:xx/02:xx/03:xx).
# Восстановление после сна делает wake-хук (~/.wakeup); здесь просто выходим.
# Fail-open: пустой/битый дамп -> unknown -> считаем Mac бодрствующим (как в хуке).
PM_DUMP=${CORP_WAKE_PM_DUMP:-}
pm_dump_warn() {
    [ "${PM_WARN_SILENT:-0}" = "1" ] && return 0
    logger "corp-vpn: watchdog: WARN: оффлайн-режим CORP_WAKE_PM_DUMP=$PM_DUMP: $1 — детектор сна недоступен, считаю Mac бодрствующим (fail-open)"
}
pm_dump() {
    if [ -n "$PM_DUMP" ]; then
        local dump
        if [ ! -r "$PM_DUMP" ]; then
            pm_dump_warn "файл не читается"
            return 0
        fi
        dump=$(tr '\n' ' ' < "$PM_DUMP" 2>/dev/null)
        case "$dump" in
            *IOPMrootDomain*) printf '%s' "$dump"; return 0 ;;
        esac
        if [ -z "$dump" ]; then
            pm_dump_warn "дамп пуст"
        else
            pm_dump_warn "в дампе нет IOPMrootDomain (повреждён)"
        fi
        printf '%s' "$dump"
        return 0
    fi
    ioreg -n IOPMrootDomain -r -d 1 2>/dev/null | tr '\n' ' '
}
pm_useractive() {
    [ -n "$PM_DUMP" ] && return 0
    pmset -g assertions 2>/dev/null | awk '$1=="UserIsActive"{print $2; exit}'
}
sleep_verdict() {
    case "$1" in
        *IOPMrootDomain*) ;;
        *) printf 'unknown'; return ;;
    esac
    case "$1" in
        *'"IOPMUserTriggeredFullWake" = Yes'*|*'"IOPMUserIsActive" = Yes'*|*'"Wake Type" = "User'*)
            printf 'awake'; return ;;
    esac
    case "${2:-}" in
        ''|*[!0-9]*) ;;
        0) ;;
        *) printf 'awake'; return ;;
    esac
    case "$1" in
        *'"AppleClamshellState" = Yes'*) printf 'asleep'; return ;;
    esac
    printf 'unknown'
}
mac_asleep() { [ "$(sleep_verdict "$(pm_dump)" "$(pm_useractive)")" = "asleep" ]; }

if mac_asleep; then
    logger "corp-vpn: watchdog: Mac во сне (DarkWake) — авто-подключение пропущено"
    exit 0
fi

PROFILES="vpn3-ts vpn4-ts vpn2-ts"

# Подключены ли к корп. Wi-Fi.
# На корп. Wi-Fi L2TP/IPSec не поднимается (сетевое оборудование глушит L2TP-в-ESP),
# поэтому корп. VPN там не подключаем — на этом Wi-Fi он бесполезен и только
# молотит попытки.
# Критерий — эталоны из corp-networks.conf: приватный MAC en0 (основной, работает
# и без IP) и ARP-MAC шлюза (вторичный, требует IP). Хотспот телефона раздаёт ту
# же подсеть 192.168.128.0/24, но его MAC en0 другой (3e:e9:15:74:f3:be), поэтому
# по одной подсети сети не различить — только по MAC.
# SSID/ассоциацию через networksetup получить НЕЛЬЗЯ (отдаёт "not associated"
# даже при рабочей сети без DHCP), поэтому MAC/IP-детект — основной.
#
# ПИЛОТ (сбор данных): рядом с вердиктом логируем ARP-MAC реального шлюза и
# приватный MAC en0 (corp-vpn: pilot [verdict] gw_mac=... mac_en0=...) через
# logger — раз в log-запись при смене.

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
#
# ВАЖНО (19.10): приватный MAC en0 — per-network признак, он присваивается при
# ассоциации и доступен СРАЗУ, ещё до выдачи IP по DHCP. Поэтому проверяем его
# НЕЗАВИСИМО от наличия IP. Раньше вердикт требовал одновременно IP и MAC, и
# после сна/переассоциации окно "no-ip" (1-2 тика) трактовалось как «не корп»:
# watchdog шёл поднимать L2TP на корп. Wi-Fi, где он не работает, и молотил
# попытки по всем профилям (см. §3.6.1 в CORP-VPN-SETUP.md).
is_corp_wifi() {
    local ip verdict mac gm
    ip=$(ipconfig getifaddr en0 2>/dev/null)
    mac=$(en0_mac)
    gm=$(gw_mac)
    verdict=""
    # Основной признак: приватный MAC en0 (не требует IP).
    if [ -n "$mac" ]; then
        case " $CORP_WIFI_EN0_MACS_DEFAULT " in
            *" $mac "*) verdict="corp" ;;
        esac
    fi
    # Вторичный признак: ARP-MAC шлюза (нужен IP, чтобы ARP вообще резолвился).
    if [ -z "$verdict" ] && [ -n "$ip" ] && [ -n "$gm" ]; then
        case " $CORP_WIFI_GATEWAY_MACS_DEFAULT " in
            *" $gm "*) verdict="corp" ;;
        esac
    fi
    if [ -z "$verdict" ]; then
        if [ -n "$mac" ] || [ -n "$ip" ]; then
            verdict="not-corp"
        else
            verdict="no-ip"
        fi
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

# Одинаковые «пропускаем»-записи пишем не чаще раза в 10 минут: тик каждые
# 30 с иначе забивает лог (26.11.2026: на корп. Wi-Fi 120 строк в час).
log_state() {
    local key f ts
    key="$1"; shift
    f="$STATE_DIR/$key.logged"
    ts=$(stat -f %m "$f" 2>/dev/null); ts=${ts:-0}
    [ $(( $(date +%s) - ts )) -ge 600 ] || return 0
    logger "$*"
    : > "$f" 2>/dev/null || true
}

# --- Диал-шторм/модалки (23.10.2026, ночь: цепочка vpn3->vpn4->vpn2) ---
# Каждая сетап-попытка networksetup -connectpppoeservice идёт через
# NESMLegacySession в Aqua-сессии пользователя, и при неудаче macOS
# показывает модалку «Подключение VPN — Сервер L2TP-VPN не ответил»
# (по одной на попытку; попытка может висеть до ~30-65 мин). Поэтому:
#   1) dial делается БЕЗ блокировки watchdog'а (guard 25s — networksetup
#      иногда висит до часов, логи ручья 23:18->00:24);
#   2) одна попытка на тик (round-robin по профилям), не цикл по трём;
#   3) после неудачного dial'а — общий cooldown-маркер на 180s: и watchdog,
#      и wake-хук (~/.wakeup, пользовательский context) его уважают. Макер
#      общий файл /tmp/corp-vpn-dial-cooldown (mtime), user может создать/править.
DIAL_COOLDOWN_FILE=/tmp/corp-vpn-dial-cooldown
DIAL_COOLDOWN_SECS=180
RR_FILE=$STATE_DIR/rr_idx

dial_cooldown_fresh() {
    local ts
    [ -f "$DIAL_COOLDOWN_FILE" ] || return 1
    ts=$(stat -f %m "$DIAL_COOLDOWN_FILE" 2>/dev/null) || return 1
    [ -n "$ts" ] || return 1
    [ $(( $(date +%s) - ts )) -lt "$DIAL_COOLDOWN_SECS" ]
}
set_dial_cooldown() {
    date +%s > "$DIAL_COOLDOWN_FILE" 2>/dev/null
    # root создаёт файл 644 — делаем 666, чтобы user wake-хук мог обновить
    # (или создать свой) маркер после своих неудачных попыток.
    chmod 666 "$DIAL_COOLDOWN_FILE" 2>/dev/null
}
clear_dial_cooldown() { rm -f "$DIAL_COOLDOWN_FILE" 2>/dev/null || true; }
trigger_dialog_sweeper() {
    cu=$(stat -f%Su /dev/console 2>/dev/null)
    [ -n "$cu" ] && [ "$cu" != "root" ] || return 0
    uid=$(id -u "$cu" 2>/dev/null) || return 0
    [ -x /usr/local/sbin/vpn-dialog-sweeper.sh ] || return 0
    launchctl asuser "$uid" /usr/local/sbin/vpn-dialog-sweeper.sh 600 \
        >/dev/null 2>&1 &
}

# Неблокирующий dial: networksetup иногда не возвращается десятками минут
# (сессия не стартует) — рушим процесс networksetup через 25s, а возможный
# «осиротевший» диал затем зачищаем scutil --nc stop (вызывающая сторона).
ns_dial() { # <profile>
    networksetup -connectpppoeservice "$1" 2>/dev/null &
    local pid=$!
    ( sleep 25; kill "$pid" 2>/dev/null; sleep 3; kill -9 "$pid" 2>/dev/null ) & local guard=$!
    wait "$pid" 2>/dev/null
    kill "$guard" 2>/dev/null
    return 0
}

# «Свежий след» wake-хука (sleepwatcher ~/.wakeup): моложе 180 с = хук сейчас
# переподключает L2TP сам. Гонка 23:07 20.10.2026: хук поднимал vpn3-ts,
# watchdog в тот же тик авто-подключил vpn4-ts — жили два параллельных
# pppd-диала, один потом деградировал и съел SA. Пока хук свежий — watchdog
# не вмешивается ни в auto-connect, ни в "dead tunnel".
WAKE_HOOK_FILE=${CORP_WAKE_HOOK_FILE:-/tmp/corp-vpn-wake-hook.last}
wake_hook_busy() {
    local ts
    [ -f "$WAKE_HOOK_FILE" ] || return 1
    ts=$(stat -f %m "$WAKE_HOOK_FILE" 2>/dev/null) || return 1
    [ -n "$ts" ] || return 1
    [ $(( $(date +%s) - ts )) -lt 180 ]
}

if wake_hook_busy; then
    logger "corp-vpn: wake hook busy (recent $WAKE_HOOK_FILE) — watchdog hold off"
    exit 0
fi

# Текущий IP физического интерфейса en0 (канал к интернету/корп Wi-Fi).
en0_ip() {
    ipconfig getifaddr en0 2>/dev/null
}

# "Туннель жив": провалились ли ВСЕ каналы через ppp0 (src = IP туннеля).
# Туннель считаем мёртвым только если одновременно не отвечают два
# независимых канала:
#   1) ICMP-эхо до корп. DNS (192.168.0.210/220) — основной канал;
#   2) TCP-коннект до b24 (192.168.0.33:443).
# История: изначально пробу делали по TCP:53/UDP:53 — корп. DNS фильтрует
# TCP-запросы на 53, проба всегда фейлилась, watchdog молотил рестарты
# каждые 30с. Тогда оставили один ICMP-канал — но 20.10.2026 17:29 это
# убило ЖИВОЙ туннель: серверы перестали отвечать только на пинг, при
# этом TCP до b24 и UDP-DNS работали (поймано живым логом проб). Фикс
# (коммит 4cb6958): мёртвый туннель = провал всех трёх каналов.
# Уточнение (вечер 20.10.2026, смерти 23:13/23:38 с no echo-reply): при
# мёртвом ESP dig до 192.168.0.210 продолжал отвечать — запрос попадал под
# DNS-хайджек Karing (fake-IP/relay во внешний DNS, b24.tradesoft.ru
# резолвится из интернета), т.е. UDP-DNS канал мог врать «жив» на мёртвом
# туннеле. Поэтому из probe убран; два не-обманных канала: ICMP и TCP
# (TCP в utun Karing закрыть нечем — до 192.168.0.33 снаружи не достучаться,
# так что false-«alive» через Karing невозможен).
tunnel_alive() {
    local srvip
    srvip=$(ifconfig ppp0 2>/dev/null | awk '/^[[:space:]]*inet /{print $2; exit}')
    [ -n "$srvip" ] || return 1
    if ping -c 1 -t 3 -S "$srvip" 192.168.0.210 >/dev/null 2>&1 || \
       ping -c 1 -t 3 -S "$srvip" 192.168.0.220 >/dev/null 2>&1; then
        return 0
    fi
    if nc -z -G 2 192.168.0.33 443 >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Принудительный перезапуск профиля (сброс stale-состояния + подъём заново).
restart_profile() {
    local p="$1"
    scutil --nc stop "$p" 2>/dev/null
    sleep 2
    ns_dial "$p"
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
    log_state corp-wifi "corp-vpn: on corp Wi-Fi — VPN auto-connect skipped"
    exit 0
fi

if is_corp_lan; then
    for p in $PROFILES; do
        if [ "$(scutil --nc status "$p" 2>/dev/null | head -1)" = "Connected" ]; then
            scutil --nc stop "$p" 2>/dev/null
            logger "corp-vpn: $p torn down on corp LAN (wired, resources accessible directly)"
        fi
    done
    log_state corp-lan "corp-vpn: on corp LAN (wired) — VPN auto-connect skipped"
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
            clear_dial_cooldown
        else
            logger "corp-vpn: failed to reconnect $connected after network change"
            scutil --nc stop "$connected" 2>/dev/null
            set_dial_cooldown
            trigger_dialog_sweeper
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
            clear_dial_cooldown
        else
            logger "corp-vpn: failed to reconnect $connected (dead tunnel)"
            scutil --nc stop "$connected" 2>/dev/null
            set_dial_cooldown
            trigger_dialog_sweeper
        fi
        echo 0 > "$FAIL_FILE"
    fi
    exit 0
fi

# --- On-demand: без свежего спроса туннель не поднимаем (25.11.2026) ---
# Корп. имена резолвятся только при поднятом туннеле, поэтому спрос на VPN
# появляется ровно тогда, когда кто-то обращается к корп. зоне: DNS-запрос
# перехватывает vpn-ondemand.py и ставит маркер /tmp/corp-vpn-demand.
# Ручной спрос — `corp-vpn.sh start` (маркер + удержание, см. /tmp/corp-vpn-hold).
# CORP_ONDEMAND=0 в corp-networks.conf возвращает прежнее поведение
# (watchdog держит туннель постоянно).
DEMAND_FILE=/tmp/corp-vpn-demand
DEMAND_TTL=300
ONDEMAND=1
if [ -f "$CONF" ] && grep -qE '^CORP_ONDEMAND=' "$CONF"; then
    ONDEMAND="$(grep -E '^CORP_ONDEMAND=' "$CONF" | head -1 | cut -d= -f2- | tr -d '"' | tr -d '\n')"
fi

demand_fresh() {
    local ts
    [ -f "$DEMAND_FILE" ] || return 1
    ts=$(stat -f %m "$DEMAND_FILE" 2>/dev/null) || return 1
    [ -n "$ts" ] || return 1
    [ $(( $(date +%s) - ts )) -le "$DEMAND_TTL" ]
}

# «Нет спроса» пишем в лог не чаще раза в 10 минут: тик каждые 30с.
NO_DEMAND_LOG=$STATE_DIR/no-demand.logged
log_no_demand() {
    local ts
    ts=$(stat -f %m "$NO_DEMAND_LOG" 2>/dev/null) || ts=0
    [ $(( $(date +%s) - ts )) -ge 600 ] || return 0
    logger "corp-vpn: нет спроса на корп. сеть (маркер старше ${DEMAND_TTL}s) — auto-connect пропущен"
    : > "$NO_DEMAND_LOG" 2>/dev/null || true
}

# Нет активного профиля — поднимаем по приоритету.
# Анти-шторм: (а) cooldown после неудачного dial'а — не дёргаем macOS 3 мин
# (каждая попытка в GUI = модалка); (б) одна попытка за тик, round-robin
# по $PROFILES (networksetup может висеть минуты — ns_dial с guard 25s).
if [ "$ONDEMAND" = "1" ] && ! demand_fresh; then
    log_no_demand
    exit 0
fi

if dial_cooldown_fresh; then
    logger "corp-vpn: dial cooldown (<${DIAL_COOLDOWN_SECS}s после неудачи) — auto-connect пропущен"
    exit 0
fi

idx=$(cat "$RR_FILE" 2>/dev/null); idx=${idx:-0}
set -- $PROFILES
p=$(eval "echo \${$(( idx % $# + 1 ))}")
echo $(( idx + 1 )) > "$RR_FILE"
logger "corp-vpn: auto-connect attempt $p (round-robin)"
ns_dial "$p"
for i in $(seq 1 10); do
    sleep 2
    if [ "$(scutil --nc status "$p" 2>/dev/null | head -1)" = "Connected" ]; then
        logger "corp-vpn: $p auto-connected by watchdog"
        clear_dial_cooldown
        exit 0
    fi
done
# Не подключился: гасим возможный осиротевший диал (ns_dial мог убить
# networksetup уже после старта сессии) и ставим общий cooldown.
scutil --nc stop "$p" 2>/dev/null
set_dial_cooldown
trigger_dialog_sweeper
logger "corp-vpn: $p dial failed — cooldown ${DIAL_COOLDOWN_SECS}s"
