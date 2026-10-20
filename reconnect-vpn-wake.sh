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
#   2. Karing рестартует СРАЗУ (синхронно, ~3–5с): после сна он часто
#      «Connected», но трафик через его utun мёртв (~90с до самовосстановления
#      по логам), а default-маршрут системы уже смотрит в этот utun — это и есть
#      окно «нет интернета». Ждём ТРАФИК, а не статус Connected (он врёт);
#   3. если рестарт не дал трафика за ~10с — аварийный fallback: закрыть Karing
#      (зависший процесс добивается TERM/KILL), убедиться, что default ушёл с
#      utun, сбросить DNS-кэш (иначе закэшированные fake-IP 198.20.x.x живут
#      после закрытия и сайты «не открываются»). Трафик идёт напрямую;
#   4. дальше прежняя логика: дождаться IP en0, guard корп. Wi-Fi / LAN,
#      поднять L2TP (с проверкой на зомби-туннель);
#   5. повторный маркер (VPN переподключается 2 раза, сессия ppp0 меняется) и
#      проверка сети с повторами 3/5/7с (15с вместо прежних 60с): внешняя проба
#      + корп. проба. Лечение по симптому: мертва внешняя сеть → fallback
#      Karing; жива внешняя, мертва корп. → переподключение L2TP.
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

# Чистое решение «чем лечить» — вынесено отдельно, чтобы selftest проверял
# именно эту логику без сети и без Karing.
# <net 0|1> <corp 0|1> <expect_corp 0|1> <karing_closed 0|1> <default_utun 0|1>
#   l2tp     — интернет есть, корп. путь мёртв: виноват L2TP;
#   fallback — интернета нет, default в utun Karing: закрыть Karing;
#   upstream — интернета нет, но Karing уже закрыт / default не в utun:
#              дело не в Karing (Wi-Fi, роутер, апстрим);
#   report   — провал не классифицируется (например, корп. проба при не-VPN
#              режиме) — только баннер.
choose_fix() {
    net=$1; corp=$2; expect_corp=$3; closed=$4; utun=$5
    if [ "$net" = "0" ]; then
        if [ "$closed" = "1" ] || [ "$utun" != "1" ]; then printf 'upstream'
        else printf 'fallback'; fi
    elif [ "$expect_corp" = "1" ] && [ "$corp" = "0" ]; then
        printf 'l2tp'
    else
        printf 'report'
    fi
}

default_iface() {
    route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}

default_via_utun() {
    case "$(default_iface)" in
        utun*) return 0 ;;
        *)     return 1 ;;
    esac
}

selftest() {
    st_pass=0; st_fail=0
    teq() {
        if [ "$2" = "$3" ]; then printf '[PASS] %s\n' "$1"; st_pass=$((st_pass + 1))
        else printf '[FAIL] %s — ожидалось [%s], получено [%s]\n' "$1" "$2" "$3"; st_fail=$((st_fail + 1)); fi
    }
    # Мертва внешняя сеть, Karing держит default в utun -> закрываем Karing.
    teq "нет сети + default в utun + Karing открыт -> fallback" "fallback" "$(choose_fix 0 0 1 0 1)"
    # Уже закрывали — второй раз не надо, причина не в Karing.
    teq "нет сети + default в utun + Karing уже закрыт -> upstream" "upstream" "$(choose_fix 0 0 1 1 1)"
    # default не в utun — закрывать нечего.
    teq "нет сети + default не в utun -> upstream" "upstream" "$(choose_fix 0 0 1 0 0)"
    # Интернет есть, корп. путь мёртв -> L2TP.
    teq "интернет есть + корп. мёртв + ожидаем корп. -> l2tp" "l2tp" "$(choose_fix 1 0 1 0 1)"
    teq "интернет есть + корп. жив -> report" "report" "$(choose_fix 1 1 1 0 1)"
    # Корп. путь не ожидается (корп. Wi-Fi/LAN) — L2TP не трогаем.
    teq "корп. не ожидается + корп. мёртв -> report" "report" "$(choose_fix 1 0 0 0 1)"
    # default_via_utun: класс багов «fallback сделали, а default остался в utun».
    route() { printf '%s\n' "$ST_ROUTE"; }
    ST_ROUTE='  interface: utun5'
    default_via_utun; teq "default: utun5 -> туннель Karing" "0" "$?"
    ST_ROUTE='  interface: en0'
    default_via_utun; teq "default: en0 -> напрямую" "1" "$?"
    ST_ROUTE=''
    default_via_utun; teq "default: пусто -> не utun" "1" "$?"

    printf 'selftest: %s passed, %s failed (rc=%s)\n' "$st_pass" "$st_fail" \
        "$([ "$st_fail" -gt 0 ] && echo 1 || echo 0)"
    [ "$st_fail" -gt 0 ] && return 1
    return 0
}

case "${1:-}" in
    --selftest) selftest; exit $? ;;
esac

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
# Синхронно: рестартер сам ждёт трафик (~3–5с норма, предел 8с), и его код
# возврата нужен, чтобы сразу решить про fallback, не теряя секунды.
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
    if "$KRESTART" --force --launch-if-stopped --quiet >>"$LOG" 2>&1; then
        log "Karing: трафик после рестарта есть (t+$(( $(date +%s) - T0 ))s)"
        return 0
    fi
    log "Karing: рестарт не дал трафика (t+$(( $(date +%s) - T0 ))s)"
    return 1
}

# Аварийный режим: выйти из Karing и вернуть прямой трафик.
karing_fallback() {
    if [ ! -x "$KRESTART" ]; then
        log "WARN: нет $KRESTART — fallback невозможен"
        return 1
    fi
    if [ "$DRY" = "1" ]; then
        log "[dry] $KRESTART --fallback --quiet"
        return 0
    fi
    if "$KRESTART" --fallback --quiet >>"$LOG" 2>&1; then
        log "Karing закрыт: интернет напрямую (t+$(( $(date +%s) - T0 ))s)"
        return 0
    fi
    log "Karing: fallback не дал трафика (t+$(( $(date +%s) - T0 ))s)"
    return 1
}

# Эталон приватного MAC en0 корп. Wi-Fi — из corp-networks.conf, если задан.
CORP_WIFI_EN0_MACS="$CORP_WIFI_EN0_MACS_DEFAULT"
if [ -f "$CONF" ] && grep -qE '^CORP_WIFI_EN0_MACS=' "$CONF"; then
    CORP_WIFI_EN0_MACS="$(grep -E '^CORP_WIFI_EN0_MACS=' "$CONF" | head -1 | cut -d= -f2- | tr -d '"' | tr -d '\n')"
    [ -n "$CORP_WIFI_EN0_MACS" ] || CORP_WIFI_EN0_MACS="$CORP_WIFI_EN0_MACS_DEFAULT"
fi

# Внешняя проба: любой 2xx/3xx = интернет есть. Таймаут 2с: живая сеть
# отвечает за ~0,2с, а мёртвая не должна съедать секунды.
net_ok() {
    code=$("$CURL" -m 2 -sS -o /dev/null -w '%{http_code}' https://1.1.1.1/ 2>/dev/null)
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

# Проверка с повторами. Ожидаем внешнюю сеть всегда, корп. путь — только когда
# он должен идти через VPN. По умолчанию 3/5/7с (15с): живая сеть отвечает за
# доли секунды, а прежние 5/15/30/60 (60с) — это чистые потери в аварии.
# После переподключения L2TP даём больше времени: "5 10 15".
verify() { # <expect_corp> <задержки...>
    expect_corp=$1; shift
    for d in "$@"; do
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

notify_info() {
    log "INFO: $1"
    /usr/bin/osascript -e "display notification \"$1\" with title \"corp-vpn: сеть после сна\"" >/dev/null 2>&1 || true
}

notify_fail() {
    log "FAIL: $1"
    /usr/bin/osascript -e "display notification \"$1\" with title \"corp-vpn: сеть после сна\"" >/dev/null 2>&1 || true
}

T0=$(date +%s)
log "=== wake: старт (dry=$DRY) ==="

# 1. Маркер — первым делом, ещё до ожидания IP: демонам важно начать
#    пересборку как можно раньше.
mark_wake

# 2. Karing — синхронно, до L2TP. Это самый частый виновник окна «нет сети»,
#    и его надо лечить первым. Не помогло — сразу закрываем и идём напрямую.
KARING_CLOSED=0
if [ "$DRY" = "1" ]; then
    karing_wake
elif ! karing_wake; then
    if karing_fallback; then
        KARING_CLOSED=1
    fi
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

# 6. Проверка. Лечим по симптому: мертва внешняя сеть → Karing; жива внешняя,
#    мертва корп. → L2TP. Второй рестарт Karing вслепую не делаем: если первый
#    за ~10с не дал трафика, рабочее действие — закрыть (fallback), а не ждать
#    ещё раз.
EXPECT_CORP=0
[ "$MODE" = "vpn" ] && EXPECT_CORP=1
VERIFY_OK=0
if [ "$DRY" = "1" ]; then
    log "[dry] verify: пропущено"
    VERIFY_OK=1
elif verify "$EXPECT_CORP" 3 5 7; then
    VERIFY_OK=1
else
    n=0; net_ok && n=1
    c=0; corp_ok && c=1
    utun=0; default_via_utun && utun=1
    fix=$(choose_fix "$n" "$c" "$EXPECT_CORP" "$KARING_CLOSED" "$utun")
    log "verify провален: net=$n corp=$c utun=$utun karing_closed=$KARING_CLOSED -> $fix"
    case "$fix" in
        l2tp)
            log "лечу L2TP: переподключение"
            vpn_redial
            mark_wake
            verify 1 5 10 15 && VERIFY_OK=1
            ;;
        fallback)
            log "лечу Karing: закрываю и иду напрямую"
            if karing_fallback; then
                KARING_CLOSED=1
                notify_info "Karing не поднялся — закрыт, интернет напрямую. Сайты через Karing недоступны."
                mark_wake
                verify "$EXPECT_CORP" 3 5 7 && VERIFY_OK=1
            fi
            ;;
        upstream)
            log "Karing не при чём: default → $(default_iface), ждём Wi-Fi/апстрим"
            ;;
        *)
            ;;
    esac
fi

if [ "$VERIFY_OK" = "1" ]; then
    log "=== wake: ok (t+$(( $(date +%s) - T0 ))s) ==="
    exit 0
fi

# 7. Диагноз для баннера — чтобы не гонять пользователя по ложному следу.
n=0; net_ok && n=1
c=0; corp_ok && c=1
if [ "$n" = "0" ]; then
    if default_via_utun; then
        notify_fail "нет интернета: default в $(default_iface), Karing не отвечает (fallback не помог) — нужен ручной разбор: $LOG"
    else
        notify_fail "нет интернета напрямую (default → $(default_iface)): проблема в Wi-Fi/апстриме, не в Karing: $LOG"
    fi
elif [ "$EXPECT_CORP" = "1" ] && [ "$c" = "0" ]; then
    notify_fail "интернет есть, корп. доступ (L2TP $VPN_NAME) не восстановился — нужен ручной разбор: $LOG"
else
    notify_fail "сеть так и не восстановилась (режим $MODE, net=$n corp=$c) — нужен ручной разбор: $LOG"
fi
exit 1
