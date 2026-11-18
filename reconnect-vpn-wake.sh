#!/bin/bash
# Автовосстановление сети после пробуждения (копируется в ~/.wakeup).
# Вызывается sleepwatcher: -w /Users/aleksei/.wakeup.
#
# Нулевой шаг — guard «Mac спит?» (28.10.2026): sleepwatcher -w подписан на
# события пробуждения, а пробуждение бывает и «тёмным» (DarkWake: крышка
# закрыта, дисплея нет, система лишь обслуживает себя — rtc/Maintenance,
# SleepService каждые ~15 мин на батарее). Восстанавливать там нечего и вредно:
# dial и рестарт Karing бодят машину, а через 2–45 с она снова засыпает прямо
# посреди последовательности. Реально за 28.10 все 35 стартов хука совпали с
# настоящим Wake (Δ+0…2с), т.е. это страховка, а не объяснение ночной
# активности: ночью VPN трогает root-демон vpn-watchdog (StartInterval 30,
# работает и в DarkWake — /tmp/corp-vpn-notify.seen, 02:41:10/05:56:07/06:56:37).
# Поэтому ДО lock/маркера/Karing проверяем, что пробуждение пользовательское;
# иначе тихий выход rc=0 без восстановительных действий — только след для
# watchdog (/tmp/corp-vpn-wake-hook.last, чтобы он не влез в тот же тик).
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
# Отладка детектора сна: CORP_WAKE_PM_DUMP=<файл с дампом IOPMrootDomain> —
# детектор читает дамп из файла и не опрашивает pmset (полностью оффлайн).
VPN_NAME="vpn3-ts"
CONF=/usr/local/etc/corp-networks.conf
CORP_WIFI_EN0_MACS_DEFAULT="b6:be:0c:d5:9a:24"

LOGDIR=${CORP_WAKE_LOGDIR:-$HOME/Library/Logs/corp-vpn}
LOG=$LOGDIR/wake.log
WAKE_MARKER=${CORP_WAKE_MARKER:-$LOGDIR/wake}
KRESTART=${CORP_KARING_RESTART:-/usr/local/sbin/corp-karing-restart.sh}
[ -x "$KRESTART" ] || KRESTART="$HOME/Work/scripts/corp-vpn/karing-restart.sh"
# Синк правил ts-network (VPN не нужен, Karing закрыт — без запуска).
KWATCH=${CORP_KARING_WATCH:-/usr/local/sbin/corp-karing-watch.sh}
[ -x "$KWATCH" ] || KWATCH="$HOME/Work/scripts/corp-vpn/karing-watch.sh"
CURL=${CORP_CURL:-/usr/bin/curl}
DRY=${WAKE_DRY_RUN:-0}
# Детектор сна: пусто — боевой режим (ioreg + pmset), путь к файлу — оффлайн-
# режим (дамп IOPMrootDomain из файла, pmset не опрашивается) для тестов.
PM_DUMP=${CORP_WAKE_PM_DUMP:-}
LOCK=/tmp/corp-wake.lock
CORP_DNS_PROBE=192.168.0.210
# «Свежий след» wake-хука: watchdog читает mtime этого файла и 3 мин не
# вмешивается (не авто-поднимает VPN и не рубит «зомби»). Гонка 23:07
# 20.10.2026: хук поднимал vpn3-ts, watchdog в тот же тик авто-подключил
# vpn4-ts — жили два параллельных pppd-диала, один потом деградировал.
WAKE_HOOK_FILE=${CORP_WAKE_HOOK_FILE:-/tmp/corp-vpn-wake-hook.last}

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

# «Свежий след» wake-хука: файл mtime моложе 180 с => хук шуршал сейчас.
# Используется watchdog'ом (vpn-watchdog.sh), оффлайн-проверяется selftest.
wake_hook_busy() {
    local ts
    [ -f "$WAKE_HOOK_FILE" ] || return 1
    ts=$(stat -f %m "$WAKE_HOOK_FILE" 2>/dev/null) || return 1
    [ -n "$ts" ] || return 1
    [ $(( $(date +%s) - ts )) -lt 180 ]
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

# --- Детектор сна (guard «Mac спит?») --------------------------------------
# Различать «настоящее» пробуждение и DarkWake умеет сам powerd, и он же
# складывает признаки в IOPMrootDomain (14 мс на чтение, pmset -g log — 1,6 с,
# поэтому лог не парсим). Сверено с pmset -g log за 28.10.2026:
#   • настоящий wake 08:05:07 (крышка): UserIsActive "lidopen", [DeclUser kDisp],
#     IOPMUserTriggeredFullWake=Yes, IOPMUserIsActive=Yes;
#   • DarkWake 06:40:16 (обслуживание): ни одного UserIsActive-ассерта,
#     [PrevIdle SysAct kCPU] — без DeclUser/kDisp, крышка закрыта.
# Пустой/битый дамп -> unknown -> НЕ спим: пропустить восстановление хуже, чем
# сделать его лишний раз (fail-open). Но молчать об этом нельзя: в оффлайн-
# режиме битый/отсутствующий CORP_WAKE_PM_DUMP тихо выключает весь guard
# «Mac спит?» — пишем WARN, чтобы причина была видна в логе. Предупреждение
# выходит ровно одно на прогон: деградация даёт вердикт unknown, а значит guard
# не уходит в повторную пробу (флаг в $(...) не выживает — не заводим его).
pm_dump_warn() {
    [ "${PM_WARN_SILENT:-0}" = "1" ] && return 0
    # Только в лог/системный лог (stderr для dry): pm_dump вызывается внутри
    # $(...) и любой stdout отсюда попал бы в «дамп» и в вердикт детектора.
    log "WARN: оффлайн-режим CORP_WAKE_PM_DUMP=$PM_DUMP: $1 — детектор сна недоступен, считаю Mac бодрствующим (fail-open)" >&2
}
pm_dump() {
    if [ -n "$PM_DUMP" ]; then
        local dump
        # Проверяем читаемость ДО redirection: ошибку `tr < $PM_DUMP` печатает
        # сам bash и подавить её изнутри команды нельзя.
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

# Число ассертов UserIsActive (второй, независимый от ioreg, признак «человек
# за машиной»). В оффлайн-режиме не опрашивается.
pm_useractive() {
    [ -n "$PM_DUMP" ] && return 0
    pmset -g assertions 2>/dev/null | awk '$1=="UserIsActive"{print $2; exit}'
}

# asleep|awake|unknown. Чистая функция: <дамп IOPMrootDomain> <UserIsActive|"">.
sleep_verdict() {
    case "$1" in
        *IOPMrootDomain*) ;;
        *) printf 'unknown'; return ;;
    esac
    # Есть пользовательские признаки — это настоящее пробуждение.
    case "$1" in
        *'"IOPMUserTriggeredFullWake" = Yes'*|*'"IOPMUserIsActive" = Yes'*|*'"Wake Type" = "User'*)
            printf 'awake'; return ;;
    esac
    # Живой ассерт UserIsActive тоже доказывает присутствие человека.
    case "${2:-}" in
        ''|*[!0-9]*) ;;                 # нет данных — не доказательство
        0)           ;;
        *) printf 'awake'; return ;;
    esac
    # Пользователя нет и крышка закрыта — DarkWake, восстанавливать нечего.
    case "$1" in
        *'"AppleClamshellState" = Yes'*) printf 'asleep'; return ;;
    esac
    printf 'unknown'
}

mac_asleep() { [ "$(sleep_verdict "$(pm_dump)" "$(pm_useractive)")" = "asleep" ]; }

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

    # wake_hook_busy: свежий след = busy, старый/отсутствующий = нет.
    ST_TMP=$(mktemp -d)
    ST_HOOK="$ST_TMP/wake-hook"
    WAKE_HOOK_FILE="$ST_HOOK"
    [ -e "$ST_HOOK" ] && rm -f "$ST_HOOK"
    wake_hook_busy; teq "wake-след: файла нет -> не busy" "1" "$?"
    : > "$ST_HOOK"
    wake_hook_busy; teq "wake-след: свежий файл -> busy" "0" "$?"
    touch -t "$(date -r $(( $(date +%s) - 200 )) '+%Y%m%d%H%M.%S')" "$ST_HOOK"
    wake_hook_busy; teq "wake-след: файл старше 180с -> не busy" "1" "$?"
    WAKE_HOOK_FILE=$CORP_WAKE_HOOK_FILE
    rm -rf "$ST_TMP"

    # Детектор сна: тёмное пробуждение (крышка закрыта, пользователя нет) —
    # именно оно приходит ночью на батарее — против настоящего wake.
    ST_DARK='+-o IOPMrootDomain <class IOPMrootDomain> { "Wake Type" = "Maintenance" "IOPMUserTriggeredFullWake" = No "AppleClamshellState" = Yes "IOPMUserIsActive" = No }'
    ST_WAKE='+-o IOPMrootDomain <class IOPMrootDomain> { "Wake Type" = "UserActivity Assertion" "IOPMUserTriggeredFullWake" = Yes "AppleClamshellState" = No "IOPMUserIsActive" = Yes }'
    ST_LIDOPEN='+-o IOPMrootDomain <class IOPMrootDomain> { "IOPMUserTriggeredFullWake" = No "AppleClamshellState" = No "IOPMUserIsActive" = No }'
    teq "сон: DarkWake + крышка закрыта -> asleep" "asleep" "$(sleep_verdict "$ST_DARK" 0)"
    teq "сон: DarkWake без данных об ассертах -> asleep" "asleep" "$(sleep_verdict "$ST_DARK" '')"
    teq "сон: настоящий wake -> awake" "awake" "$(sleep_verdict "$ST_WAKE" 1)"
    teq "сон: DarkWake + живой ассерт UserIsActive -> awake" "awake" "$(sleep_verdict "$ST_DARK" 1)"
    teq "сон: крышка открыта, признаков пользователя нет -> unknown" "unknown" "$(sleep_verdict "$ST_LIDOPEN" 0)"
    teq "сон: мусор вместо дампа -> unknown" "unknown" "$(sleep_verdict "hello" 0)"
    teq "сон: пустой дамп -> unknown" "unknown" "$(sleep_verdict "" '')"

    # mac_asleep целиком: дамп из файла (оффлайн-режим) + подмена pm_useractive.
    ST_TMP2=$(mktemp -d)
    ST_SAVED_PM="$PM_DUMP"
    # Тестовые дампы специально битые (в т.ч. /dev/null) — WARN о деградации
    # оффлайн-режима тут ожидаем и в боевой лог попадать не должен.
    ST_SAVED_QUIET="${PM_WARN_SILENT:-0}"
    PM_WARN_SILENT=1
    printf '%s\n' "$ST_DARK" > "$ST_TMP2/dark"
    printf '%s\n' "$ST_WAKE" > "$ST_TMP2/awake"
    pm_useractive() { printf '%s\n' "${ST_UA:-}"; }
    PM_DUMP="$ST_TMP2/dark"; ST_UA=0; mac_asleep; teq "сон: дамп DarkWake + UA=0 -> спим" "0" "$?"
    PM_DUMP="$ST_TMP2/dark"; ST_UA=1; mac_asleep; teq "сон: дамп DarkWake + UA=1 -> не спим" "1" "$?"
    PM_DUMP="$ST_TMP2/awake"; ST_UA=1; mac_asleep; teq "сон: дамп wake -> не спим" "1" "$?"
    PM_DUMP=/dev/null;         ST_UA=0; mac_asleep; teq "сон: пустой дамп -> не спим (fail-open)" "1" "$?"
    PM_DUMP="$ST_SAVED_PM"
    PM_WARN_SILENT="$ST_SAVED_QUIET"
    rm -rf "$ST_TMP2"

    printf 'selftest: %s passed, %s failed (rc=%s)\n' "$st_pass" "$st_fail" \
        "$([ "$st_fail" -gt 0 ] && echo 1 || echo 0)"
    [ "$st_fail" -gt 0 ] && return 1
    return 0
}

case "${1:-}" in
    --selftest) selftest; exit $? ;;
esac

# Guard «Mac спит?» — до lock, маркера, Karing и dial. Повтор через 1 с: на
# настоящем wake powerd выставляет user-active за доли секунды, а ложный
# пропуск (нет сети до следующего пробуждения) недопустим.
if mac_asleep; then
    sleep 1
    if mac_asleep; then
        # След «хук шуршал» ставим и на пропуске: вход в хук состоялся (его
        # вызвало событие sleepwatcher), и пока след свежий, watchdog не
        # авто-подключает VPN и не рубит «зомби» — на DarkWake именно это
        # будит машину и рвёт сессию. Без записи следа пропуск по сну
        # выглядел для watchdog'а как «хука не было» — hold-off терялся.
        if [ "$DRY" = "1" ]; then
            log "[dry] след wake-хука -> $WAKE_HOOK_FILE (пропуск по сну) — не пишу"
        else
            date +%s > "$WAKE_HOOK_FILE" 2>/dev/null || \
                log "WARN: не записал след wake-хука $WAKE_HOOK_FILE"
        fi
        log "Mac во сне (DarkWake: крышка закрыта, пользователя нет) — восстановление не нужно, rc=0"
        exit 0
    fi
    log "детектор сна: первая проба «спит», повторная «бодрствует» — продолжаю"
fi

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

# След для watchdog: "хук был свежим" (см. wake_hook_busy / vpn-watchdog.sh).
# В dry-run не пишем — прогон без побочных эффектов.
if [ "$DRY" != "1" ]; then
    date +%s > "$WAKE_HOOK_FILE" 2>/dev/null
fi

# Маркер для root-демонов: одна строка epoch. Не гасим и не перезаписываем
# нулём — каждый демон помнит последнее увиденное значение.
mark_wake() {
    if [ "$DRY" = "1" ]; then log "[dry] маркер wake -> $WAKE_MARKER"; return 0; fi
    date +%s > "$WAKE_MARKER" 2>/dev/null || log "WARN: не записал маркер $WAKE_MARKER"
}

# Правила ts-network после wake: Karing мог сохранить старый снимок
# конфига, а сеть после сна меняется (корп. Wi-Fi <-> домашний). Синк
# идёт по дрейфу и VPN не требует.
karing_rules_sync() {
    [ -x "$KWATCH" ] || return 0
    if [ "$DRY" = "1" ]; then
        log "[dry] $KWATCH --sync"
        return 0
    fi
    if "$KWATCH" --sync >>"$LOG" 2>&1; then
        log "Karing: правила ts-network сверены с corp-networks.conf"
    else
        log "WARN: Karing: синк правил не удался (см. corp-karing-watch)"
    fi
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
        karing_rules_sync
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
        karing_rules_sync
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
# networksetup может висеть десятками минут (ночь 23.10.2026) — диал асинхронный
# с guard 25s. После полного провала — общий с watchdog'ом cooldown-маркер
# /tmp/corp-vpn-dial-cooldown (10 мин): каждая попытка в GUI-контексте рисует
# модалку «Сервер L2TP-VPN не ответил», штормить не нужно.
DIAL_COOLDOWN_FILE=/tmp/corp-vpn-dial-cooldown
DIAL_COOLDOWN_SECS=600
dial_cooldown_fresh() {
    local ts
    [ -f "$DIAL_COOLDOWN_FILE" ] || return 1
    ts=$(stat -f %m "$DIAL_COOLDOWN_FILE" 2>/dev/null) || return 1
    [ -n "$ts" ] || return 1
    [ $(( $(date +%s) - ts )) -lt "$DIAL_COOLDOWN_SECS" ]
}
ns_dial() { # <profile>
    networksetup -connectpppoeservice "$1" 2>/dev/null &
    local pid=$!
    ( sleep 25; kill "$pid" 2>/dev/null; sleep 3; kill -9 "$pid" 2>/dev/null ) & local guard=$!
    wait "$pid" 2>/dev/null
    kill "$guard" 2>/dev/null
}

vpn_connect() {
    if dial_cooldown_fresh; then
        log "$VPN_NAME: dial cooldown (<600s после неудачи) — попытка пропущена"
        return 1
    fi
    for attempt in 1 2 3; do
        ns_dial "$VPN_NAME"
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
    date +%s > "$DIAL_COOLDOWN_FILE" 2>/dev/null
    return 1
}

# Корп. путь после подъёма туннеля появляется не мгновенно (DNS, маршруты).
wait_corp() { # <секунд>
    # Дедлайн по часам, а не по сумме sleep: сама проба (ping -t 2) стоит до
    # 2 с, и «wait_corp 8» растягивался до 20 с — ровно столько лишнего ждал
    # redial зомби-L2TP в замере 20.10.2026.
    st_end=$(( $(date +%s) + ${1:-20} ))
    while :; do
        corp_ok && return 0
        [ "$(date +%s)" -ge "$st_end" ] && return 1
        sleep 2
    done
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

# 0. Свипер модалок VPN: macOS при неудачном дial'е показывает модалку
#    «Подключение VPN — Сервер L2TP-VPN не ответил» с OK (neagent/Settings),
#    и человек обязан её закрывать вручную. В течение 10 мин после сна свипер
#    закрывает сам. Работает только в этом окне, не фоновый надзор.
if [ "$DRY" != "1" ]; then
    nohup /usr/local/sbin/vpn-dialog-sweeper.sh 600 >/dev/null 2>&1 &
    [ -x /usr/local/sbin/vpn-dialog-sweeper.sh ] || \
        nohup "$HOME/Work/scripts/corp-vpn/vpn-dialog-sweeper.sh" 600 >/dev/null 2>&1 &
fi

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
        # Живой корп. DNS отвечает за 1–2с, поэтому 8с (4 пробы) достаточно,
        # чтобы отличить зомби-туннель от медленного подъёма. Было 15с — это
        # ровно столько лишнего ждал redial в замере 20.10.2026.
        if wait_corp 8; then
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
