#!/bin/bash
# Автовосстановление сети после пробуждения (копируется в ~/.wakeup).
# Вызывается sleepwatcher: -w /Users/aleksei/.wakeup.
#
# Порядок важен (20.10.2026, разбор пробуждения 07:55:38):
#   1. маркер пробуждения ~/Library/Logs/corp-vpn/wake — root-демоны
#      (corp-vpn-routes, corp-wifi-routes, corp-routes-clean) по нему сбрасывают
#      кулдауны/таймеры/снимки и принудительно пересобирают маршруты, не
#      дожидаясь смены сессии ppp0 (иначе корп. /32 живут до 5 мин, а Karing
#      успевает увести их в utun);
#   2. Karing рестартует СРАЗУ и в фоне: после сна он часто «Connected», но
#      трафик через его utun мёртв (~90с до самовосстановления по логам), а
#      default-маршрут системы уже смотрит в этот utun — это и есть окно «нет
#      интернета»;
#   3. дальше прежняя логика: дождаться IP en0, guard корп. Wi-Fi / LAN,
#      поднять L2TP;
#   4. повторный маркер (VPN переподключается 2 раза, сессия ppp0 меняется) и
#      проверка сети с повторами 5/15/30/60с: внешняя проба + корп. проба.
#      Провал — второй рестарт Karing и баннер Notification Center.
#
# Отладка без побочных эффектов: WAKE_DRY_RUN=1 ~/.wakeup
VPN_NAME="vpn3-ts"
CONF=/usr/local/etc/corp-networks.conf
CORP_WIFI_EN0_MACS_DEFAULT="b6:be:0c:d5:9a:24"

LOGDIR=${CORP_WAKE_LOGDIR:-$HOME/Library/Logs/corp-vpn}
LOG=$LOGDIR/wake.log
WAKE_MARKER=${CORP_WAKE_MARKER:-$LOGDIR/wake}
KRESTART=${CORP_KARING_RESTART:-/usr/local/sbin/corp-karing-restart.sh}
[ -x "$KRESTART" ] || KRESTART="$HOME/Work/scripts/corp-vpn/karing-restart.sh"
CURL=${CORP_CURL:-/usr/bin/curl}
DRY=${WAKE_DRY_RUN:-0}
LOCK=/tmp/corp-wake.lock
CORP_DNS_PROBE=192.168.0.210

mkdir -p "$LOGDIR" 2>/dev/null
log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
    logger -t corp-vpn "wake: $*"
    [ "$DRY" = "1" ] && printf '%s\n' "$*"
}

# Один прогон за раз: sleepwatcher может выдать несколько wake-событий подряд,
# а два параллельных подъёма L2TP и рестарта Karing только мешают друг другу.
if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -z "$(find "$LOCK" -mmin +10 2>/dev/null)" ]; then
        log "уже выполняется (lock $LOCK) — выход"
        exit 0
    fi
    rmdir "$LOCK" 2>/dev/null || exit 0
    mkdir "$LOCK" || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Маркер для root-демонов: одна строка epoch. Не гасим и не перезаписываем
# нулём — каждый демон помнит последнее увиденное значение.
mark_wake() {
    if [ "$DRY" = "1" ]; then log "[dry] маркер wake -> $WAKE_MARKER"; return 0; fi
    date +%s > "$WAKE_MARKER" 2>/dev/null || log "WARN: не записал маркер $WAKE_MARKER"
}

# Karing: после сна состояние недостоверно, рестартуем безусловно. Если
# приложение закрыто — не навязываем (--launch-if-stopped всё же включает:
# именно Karing даёт интернет, а после wake он обычно и был запущен).
karing_wake() {
    if [ ! -x "$KRESTART" ]; then
        log "WARN: нет $KRESTART — Karing не перезапускаю"
        return 0
    fi
    log "Karing: рестарт после сна"
    if [ "$DRY" = "1" ]; then
        log "[dry] $KRESTART --force --launch-if-stopped --quiet"
        return 0
    fi
    "$KRESTART" --force --launch-if-stopped --quiet >>"$LOG" 2>&1
}

# Эталон приватного MAC en0 корп. Wi-Fi — из corp-networks.conf, если задан.
CORP_WIFI_EN0_MACS="$CORP_WIFI_EN0_MACS_DEFAULT"
if [ -f "$CONF" ] && grep -qE '^CORP_WIFI_EN0_MACS=' "$CONF"; then
    CORP_WIFI_EN0_MACS="$(grep -E '^CORP_WIFI_EN0_MACS=' "$CONF" | head -1 | cut -d= -f2- | tr -d '"' | tr -d '\n')"
    [ -n "$CORP_WIFI_EN0_MACS" ] || CORP_WIFI_EN0_MACS="$CORP_WIFI_EN0_MACS_DEFAULT"
fi

# Внешняя проба: любой 2xx/3xx = интернет есть.
net_ok() {
    code=$("$CURL" -m 4 -sS -o /dev/null -w '%{http_code}' https://1.1.1.1/ 2>/dev/null)
    case "$code" in 2??|3??) return 0 ;; esac
    return 1
}

# Корп. проба: корп. DNS отвечает (через ppp0 или напрямую на корп. сети).
corp_ok() { ping -c 1 -t 2 "$CORP_DNS_PROBE" >/dev/null 2>&1; }

vpn_connected() {
    [ "$(scutil --nc status "$VPN_NAME" 2>/dev/null | head -1)" = "Connected" ]
}

# Подъём L2TP до Connected (до 3 попыток, между ними stop + пауза).
vpn_connect() {
    for attempt in 1 2 3; do
        networksetup -connectpppoeservice "$VPN_NAME" 2>/dev/null
        i=0
        while [ "$i" -lt 10 ]; do
            sleep 2
            if vpn_connected; then
                log "$VPN_NAME connected (attempt $attempt, t+$(( $(date +%s) - T0 ))s)"
                return 0
            fi
            i=$((i + 1))
        done
        scutil --nc stop "$VPN_NAME" 2>/dev/null
        sleep 3
    done
    log "$VPN_NAME connect failed after 3 attempts"
    return 1
}

# Корп. путь после подъёма туннеля появляется не мгновенно (DNS, маршруты).
wait_corp() { # <секунд>
    left=${1:-20}
    while [ "$left" -gt 0 ]; do
        corp_ok && return 0
        sleep 2
        left=$((left - 2))
    done
    return 1
}

# «Connected» после сна часто зомби: configd помнит старую сессию, трафик мёртв.
# Переподключаем сразу, не ожидая 2 тика watchdog (~35–40с без корп. сети).
vpn_redial() {
    log "L2TP: зомби-туннель (Connected, корп. проба не проходит) — переподключ"
    scutil --nc stop "$VPN_NAME" 2>/dev/null
    sleep 2
    vpn_connect
}

# Проверка с повторами: 5/15/30/60с от момента вызова. Ожидаем внешнюю сеть
# всегда, корп. путь — только когда он должен идти через VPN.
verify() {
    expect_corp=$1
    for d in 5 10 15 30; do
        sleep "$d"
        n=0; net_ok && n=1
        c=0; corp_ok && c=1
        if [ "$n" = "1" ] && { [ "$expect_corp" != "1" ] || [ "$c" = "1" ]; }; then
            log "verify ok: net=$n corp=$c (t+$(( $(date +%s) - T0 ))s)"
            return 0
        fi
        log "verify: net=$n corp=$c (t+$(( $(date +%s) - T0 ))s), ждём"
    done
    return 1
}

notify_fail() {
    msg=$1
    log "FAIL: $msg"
    /usr/bin/osascript -e "display notification \"$msg\" with title \"corp-vpn: сеть после сна\"" >/dev/null 2>&1 || true
}

T0=$(date +%s)
log "=== wake: старт (dry=$DRY) ==="

# 1. Маркер — первым делом, ещё до ожидания IP: демонам важно начать
#    пересборку как можно раньше.
mark_wake

# 2. Karing — параллельно с ожиданием сети и подъёмом L2TP.
KR_PID=""
if [ "$DRY" = "1" ]; then
    karing_wake
else
    karing_wake &
    KR_PID=$!
    log "Karing restart запущен в фоне (pid $KR_PID)"
fi

# 3. Ждём адрес на en0 (как раньше, до 30с).
for i in $(seq 1 15); do
    EN0_IP=$(ipconfig getifaddr en0 2>/dev/null)
    if [ -n "$EN0_IP" ]; then break; fi
    sleep 2
done
log "en0 ip=${EN0_IP:-none} (t+$(( $(date +%s) - T0 ))s)"

# 4. Классификация сети после сна.
#    Корп. Wi-Fi: L2TP/IPSec там не поднимается (сеть глушит L2TP-в-ESP),
#    поэтому не пытаемся даже один раз — иначе уходит ~80с впустую на 3
#    попытки. Признак — per-network приватный MAC en0: он присваивается при
#    ассоциации и доступен сразу, ещё до выдачи IP по DHCP.
MODE=vpn
EN0_MAC=$(ifconfig en0 2>/dev/null | awk '/ether/{print $2; exit}')
if [ -n "$EN0_MAC" ]; then
    case " $CORP_WIFI_EN0_MACS " in
        *" $EN0_MAC "*)
            MODE=corp-wifi
            log "on corp Wi-Fi after wake (mac_en0=$EN0_MAC) — VPN reconnect skipped"
            ;;
    esac
fi

#    Корп. LAN-кабель: VPN не нужен и не поднимаем.
if [ "$MODE" = "vpn" ]; then
    for iface in $(ifconfig -lu 2>/dev/null); do
        case "$iface" in
            en0|lo|utun*|gif*|stf*|anpi*|awdl*|llw*|ppp*|vnic*|ap*) continue ;;
        esac
        EN0_IP=""
        EN0_IP=$(ipconfig getifaddr "$iface" 2>/dev/null)
        if [ -n "$EN0_IP" ] && printf '%s' "$EN0_IP" | grep -qE '^192\.168\.128\.'; then
            MODE=corp-lan
            log "on corp LAN after wake ($iface $EN0_IP) — VPN reconnect skipped"
            break
        fi
    done
fi

# 5. Подъём L2TP (только вне корп. сети). «Connected» после сна не доверяем:
#    в 08:28 20.10.2026 профиль был Connected, а корп. DNS не отвечал 83с,
#    пока watchdog не сбросил зомби-туннель. Проверяем корп. путь и при
#    провале переподключаемся сразу.
if [ "$MODE" = "vpn" ]; then
    if [ "$DRY" = "1" ]; then
        log "[dry] $VPN_NAME: check connected / networksetup -connectpppoeservice (до 3 попыток)"
    elif vpn_connected; then
        log "$VPN_NAME уже Connected после сна"
        if wait_corp 15; then
            log "корп. путь жив (t+$(( $(date +%s) - T0 ))s)"
        else
            vpn_redial
            wait_corp 20 || log "корп. путь всё ещё не отвечает после переподключения"
        fi
    else
        vpn_connect
    fi
    # Сессия ppp0 после wake меняется (в логах 20.10: .175 -> .103) — маркер
    # повторяем, чтобы демон пересобрал маршруты уже по финальной сессии.
    mark_wake
fi

# 6. Дожидаемся фонового рестарта Karing.
if [ -n "$KR_PID" ]; then
    wait "$KR_PID" 2>/dev/null
    log "Karing restart finished (rc=$?, t+$(( $(date +%s) - T0 ))s)"
fi

# 7. Проверка и, при провале, один повторный рестарт Karing.
EXPECT_CORP=0
[ "$MODE" = "vpn" ] && EXPECT_CORP=1
if [ "$DRY" = "1" ]; then
    log "[dry] verify: пропущено"
elif ! verify "$EXPECT_CORP"; then
    # Выбираем лечение по тому, что именно мертво: перезапуск Karing не лечит
    # L2TP, а переподключение L2TP не лечит сломанный utun Karing.
    if [ "$MODE" = "vpn" ] && net_ok && ! corp_ok; then
        log "verify: интернет есть, корп. путь мёртв — переподключаю L2TP"
        vpn_redial
    else
        log "verify: внешняя сеть не восстановилась — рестарт Karing"
        karing_wake
    fi
    mark_wake
    if verify "$EXPECT_CORP"; then
        log "=== wake: ok после восстановления (t+$(( $(date +%s) - T0 ))s) ==="
        exit 0
    fi
    notify_fail "сеть так и не восстановилась (режим $MODE) — нужен ручной разбор: $LOG"
    exit 1
fi

log "=== wake: ok (t+$(( $(date +%s) - T0 ))s) ==="
exit 0
