#!/bin/bash
# ==========================================================
# karing-restart.sh — рестарт и аварийное закрытие Karing (user-level).
#
# Зачем: после пробуждения из сна Karing часто остаётся в состоянии
# "Connected", но трафик через его utun мёртв: default-маршрут системы смотрит
# в utun, а пакеты никуда не уходят. По логам 20.10.2026 окно без интернета
# после wake было ~90с (Karing переинициализировался сам только в 07:57:09 при
# пробуждении в 07:55:38).
#
# Две стратегии:
#   * рестарт (--force/--if-dead) — обычный путь: quit → open → ждём ТРАФИК
#     (не статус Connected: он врёт). Норма ~3–5с, предел UP_WAIT=8с.
#   * аварийное закрытие (--fallback) — если трафик не появился: выйти из
#     Karing (зависший процесс добивается TERM/KILL), убедиться, что default
#     ушёл с utun, сбросить DNS-кэш (иначе закэшированные fake-IP 198.20.x.x
#     живут после закрытия и сайты «не открываются») и проверить трафик.
#     Так интернет возвращается напрямую за ~10–15с вместо минут ожидания.
#
# Кто вызывает:
#   ~/.wakeup — `--force --launch-if-stopped` после сна, при провале `--fallback`;
#   вручную — `--if-dead` (рестарт только если внешняя проба не проходит).
#
# Успешный рестарт обновляет метку ~/Library/Logs/corp-karing-watch/last-resync,
# чтобы вотчер дрейфа не перезапустил Karing второй раз в пределах кулдауна.
# Провал метку НЕ обновляет (иначе провал усыплял бы вотчер на 30 минут), а
# пишет диагностическую ~/Library/Logs/corp-karing-watch/last-fail.
#
# Режимы:
#   --if-dead            рестарт только если проба интернета не проходит
#                        (по умолчанию; безопасно для ручного запуска);
#   --force              рестарт безусловно (wake-хук);
#   --fallback           закрыть Karing и вернуть трафик напрямую;
#   --launch-if-stopped  если Karing не запущен — не только рестарт, но и запуск;
#   --dry-run            без побочных эффектов (для проверки логики);
#   --quiet              не писать в stdout (для хука);
#   -h|--help            справка;
#   --selftest           проверки решений и закрытия зависшего Karing.
# ==========================================================
set -uo pipefail

LOGDIR=${CORP_WAKE_LOGDIR:-$HOME/Library/Logs/corp-vpn}
LOG=${KRESTART_LOG:-$LOGDIR/karing-restart.log}
KWATCH_LAST=${KRESTART_KWATCH_LAST:-$HOME/Library/Logs/corp-karing-watch/last-resync}
KWATCH_FAIL=${KRESTART_KWATCH_FAIL:-$HOME/Library/Logs/corp-karing-watch/last-fail}
# Таймауты рассчитаны на «минимальное время»: норма рестарта 3–5с. Ждать
# дольше смысла нет — если за 8с трафика нет, помогает только закрытие.
QUIT_WAIT=${KRESTART_QUIT_WAIT:-3}
KILL_WAIT=${KRESTART_KILL_WAIT:-2}
UP_WAIT=${KRESTART_UP_WAIT:-8}
PROBE_TIMEOUT=${KRESTART_PROBE_TIMEOUT:-2}
PROBE_URLS=${KRESTART_PROBE_URLS:-"https://1.1.1.1/ https://www.google.com/generate_204"}
TUNNEL_SVC=${KRESTART_TUNNEL_SVC:-"Karing (system)"}
CURL=${KRESTART_CURL:-/usr/bin/curl}
SUDO=${KRESTART_SUDO:-$HOME/bin/sudo}
DRY=${KRESTART_DRY_RUN:-0}
FAKE_TRAFFIC=${KRESTART_FAKE_TRAFFIC:-1}

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
  [ "${QUIET:-0}" = "1" ] || printf '%s\n' "$*"
}

usage() {
  cat <<'EOF'
Использование: karing-restart.sh [--if-dead|--force|--fallback]
                                 [--launch-if-stopped] [--dry-run] [--quiet]
  --if-dead            рестарт только при провале внешней пробы (по умолчанию)
  --force              рестарт безусловно (для wake-хука)
  --fallback           закрыть Karing и вернуть трафик напрямую
  --launch-if-stopped  запускать Karing, если он не запущен
  --dry-run            ничего не менять (проверка логики)
  --quiet              без вывода в stdout
EOF
}

# --- обёртки внешних эффектов (в selftest подменяются) -----------------------
karing_running() { pgrep -f "Karing.app/Contents/MacOS/Karing" >/dev/null 2>&1; }

karing_quit() {
  [ "$DRY" = "1" ] && { log "[dry] quit Karing"; return 0; }
  /usr/bin/osascript -e 'tell application "Karing" to quit' >/dev/null 2>&1 || true
}

# Зависшее приложение не отвечает на AppleScript quit — добиваем.
karing_kill() {
  [ "$DRY" = "1" ] && { log "[dry] kill Karing"; return 0; }
  pkill -TERM -f "Karing.app/Contents/MacOS/Karing" >/dev/null 2>&1 || true
  t=0
  while karing_running && [ "$t" -lt "$KILL_WAIT" ]; do sleep 1; t=$((t + 1)); done
  if karing_running; then
    pkill -KILL -f "Karing.app/Contents/MacOS/Karing" >/dev/null 2>&1 || true
    sleep 1
  fi
}

# Выйти из Karing гарантированно: quit, пауза, при необходимости TERM/KILL.
karing_stop() {
  if [ "$DRY" = "1" ]; then log "[dry] stop Karing"; return 0; fi
  karing_running || { log "Karing уже не запущен"; return 0; }
  log "quit Karing"
  karing_quit
  t=0
  while karing_running && [ "$t" -lt "$QUIT_WAIT" ]; do sleep 1; t=$((t + 1)); done
  if karing_running; then
    log "WARN: Karing не закрылся за ${QUIT_WAIT}с — добиваю"
    karing_kill
  fi
  karing_running && log "WARN: процесс Karing всё ещё жив" || log "Karing закрыт"
}

karing_open() {
  [ "$DRY" = "1" ] && { log "[dry] open Karing"; return 0; }
  open -a Karing >/dev/null 2>&1 || true
}

tunnel_up() {
  [ "$(scutil --nc status "$TUNNEL_SVC" 2>/dev/null | head -1)" = "Connected" ]
}

# Интерфейс default-маршрута (utun* = трафик уходит в туннель Karing).
default_iface() {
  route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
}

default_via_utun() {
  case "$(default_iface)" in
    utun*) return 0 ;;
    *)     return 1 ;;
  esac
}

# Внешняя проба: любой 2xx/3xx от любого из URL = сеть жива. Таймаут короткий:
# живая сеть отвечает за ~0,2с, мёртвая не должна съедать секунды.
probe_net() {
  if [ "$DRY" = "1" ]; then [ "$FAKE_TRAFFIC" = "1" ]; return; fi
  for url in $PROBE_URLS; do
    code=$("$CURL" -m "$PROBE_TIMEOUT" -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
    case "$code" in
      2??|3??) return 0 ;;
    esac
  done
  return 1
}

# Ждём именно трафик, а не статус туннеля.
wait_traffic() {
  [ "$DRY" = "1" ] && { [ "$FAKE_TRAFFIC" = "1" ]; return; }
  t=0
  while [ "$t" -lt "$UP_WAIT" ]; do
    probe_net && return 0
    sleep 1; t=$((t + 1))
  done
  return 1
}

# Метка для karing-watch.sh: успешный рестарт считается его ресинком, иначе
# вотчер в течение кулдауна может перезапустить Karing ещё раз.
mark_resync() {
  [ "$DRY" = "1" ] && { log "[dry] mark last-resync"; return 0; }
  mkdir -p "$(dirname "$KWATCH_LAST")" 2>/dev/null
  date +%s > "$KWATCH_LAST" 2>/dev/null
}

# Провал НЕ обновляет last-resync: иначе вотчер 30 минут не будет пытаться.
mark_fail() {
  [ "$DRY" = "1" ] && { log "[dry] mark last-fail"; return 0; }
  mkdir -p "$(dirname "$KWATCH_FAIL")" 2>/dev/null
  date +%s > "$KWATCH_FAIL" 2>/dev/null
}

# Сброс DNS-кэша: после закрытия Karing в кэше остаются fake-IP (198.20.x.x),
# и сайты «не открываются», хотя интернет уже есть. mDNSResponder требует root —
# берём пароль из Keychain через обёртку (без GUI, неинтерактивно).
flush_dns() {
  dscacheutil -flushcache >/dev/null 2>&1 || true
  if [ "$DRY" = "1" ]; then log "[dry] flush DNS"; return 0; fi
  if [ -x "$SUDO" ]; then
    "$SUDO" killall -HUP mDNSResponder >/dev/null 2>&1 || \
      log "WARN: не удалось перезапустить mDNSResponder (sudo?)"
  else
    log "WARN: нет $SUDO — DNS-кэш сброшен только dscacheutil"
  fi
}

# Чистое решение: что делать. Вынесено отдельно, чтобы selftest проверял
# именно эту логику без запуска приложения.
# <running 0|1> <net_ok 0|1> <mode force|if-dead> <launch_if_stopped 0|1>
decide() {
  running=$1; net=$2; mode=$3; launch=$4
  if [ "$running" != "1" ] && [ "$launch" != "1" ]; then
    printf 'skip:not-running'; return 0
  fi
  case "$mode" in
    force)   printf 'restart:forced' ;;
    if-dead)
      if [ "$net" = "1" ]; then printf 'skip:net-ok'
      else printf 'restart:dead'; fi ;;
    *)       printf 'skip:bad-mode' ;;
  esac
}

do_restart() {
  t0=$(date +%s)
  karing_stop
  log "open Karing"
  karing_open
  if wait_traffic; then
    log "traffic ok after $(( $(date +%s) - t0 ))s"
    mark_resync
    return 0
  fi
  log "FAIL: трафика нет за ${UP_WAIT}с после рестарта (t+$(( $(date +%s) - t0 ))s)"
  mark_fail
  return 1
}

# Аварийный выход: закрыть Karing и вернуть прямой трафик.
do_fallback() {
  t0=$(date +%s)
  log "fallback: закрываю Karing, трафик напрямую"
  karing_stop
  if tunnel_up; then
    log "WARN: сервис Connected после выхода — снимаю туннель"
    [ "$DRY" = "1" ] || scutil --nc stop "$TUNNEL_SVC" >/dev/null 2>&1 || true
    t=0
    while tunnel_up && [ "$t" -lt 5 ]; do sleep 1; t=$((t + 1)); done
  fi
  # default должен уйти с utun; если не ушёл — трафик всё равно в никуда.
  t=0
  while default_via_utun && [ "$t" -lt 3 ]; do sleep 1; t=$((t + 1)); done
  if default_via_utun; then
    log "WARN: default остался на $(default_iface)"
  else
    log "default -> $(default_iface) (t+$(( $(date +%s) - t0 ))s)"
  fi
  flush_dns
  if wait_traffic; then
    log "fallback OK: интернет напрямую за $(( $(date +%s) - t0 ))s"
    return 0
  fi
  log "FAIL: fallback не дал трафика за ${UP_WAIT}с (t+$(( $(date +%s) - t0 ))s)"
  mark_fail
  return 1
}

selftest() {
  st_pass=0; st_fail=0
  t() {
    if [ "$2" = "0" ]; then printf '[PASS] %s\n' "$1"; st_pass=$((st_pass + 1))
    else printf '[FAIL] %s\n' "$1"; st_fail=$((st_fail + 1)); fi
  }
  teq() {
    if [ "$2" = "$3" ]; then t "$1" 0
    else t "$1 — ожидалось [$2], получено [$3]" 1; fi
  }
  # Решения: force не зависит от пробы, if-dead зависит, закрытое приложение
  # без --launch-if-stopped не трогаем.
  teq "decide: force + запущен -> restart" "restart:forced" "$(decide 1 0 force 0)"
  teq "decide: force + не запущен без --launch -> skip" "skip:not-running" "$(decide 0 0 force 0)"
  teq "decide: force + не запущен с --launch -> restart" "restart:forced" "$(decide 0 0 force 1)"
  teq "decide: force игнорирует живую пробу -> restart" "restart:forced" "$(decide 1 1 force 0)"
  teq "decide: if-dead + сеть жива -> skip" "skip:net-ok" "$(decide 1 1 if-dead 0)"
  teq "decide: if-dead + сеть мертва -> restart" "restart:dead" "$(decide 1 0 if-dead 0)"
  teq "decide: if-dead + не запущен без --launch -> skip" "skip:not-running" "$(decide 0 0 if-dead 0)"
  teq "decide: неизвестный режим -> skip" "skip:bad-mode" "$(decide 1 0 no-such-mode 1)"

  # default_via_utun: класс багов «fallback сделали, но default остался в utun».
  route() { printf '%s\n' "$ST_ROUTE_DEFAULT"; }
  ST_ROUTE_DEFAULT='   route to: default
destination: default
       mask: default
    gateway: link#25
  interface: utun5
      flags: <UP,GATEWAY,DIFERR,STATIC,IFSCOPE,IFREF,UTUN>'
  default_via_utun; t "default: utun5 — трафик в туннеле Karing" "$([ $? -eq 0 ] && echo 0 || echo 1)"
  ST_ROUTE_DEFAULT='   route to: default
destination: default
  interface: en0'
  default_via_utun; t "default: en0 — прямой трафик" "$([ $? -eq 1 ] && echo 0 || echo 1)"
  ST_ROUTE_DEFAULT=''
  default_via_utun; t "default: пусто (нет маршрута) — не utun" "$([ $? -eq 1 ] && echo 0 || echo 1)"

  # Зависший Karing: quit не сработал — обязателен TERM/KILL, иначе utun
  # останется держать default и fallback не даст интернета.
  sleep() { :; }
  st_hung=1; st_killed=0
  karing_running() { [ "$st_hung" = "1" ]; }
  karing_quit() { :; }
  karing_kill() { st_killed=1; st_hung=0; }
  karing_stop >/dev/null 2>&1
  teq "fallback: зависший Karing добивается kill" "1" "$st_killed"

  printf 'selftest: %s passed, %s failed (rc=%s)\n' "$st_pass" "$st_fail" \
    "$([ "$st_fail" -gt 0 ] && echo 1 || echo 0)"
  [ "$st_fail" -gt 0 ] && return 1
  return 0
}

case "${1:-}" in
  --selftest|--self-test) selftest; exit $? ;;
esac

MODE=if-dead
LAUNCH=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --if-dead)           MODE=if-dead ;;
    --force)             MODE=force ;;
    --fallback)          MODE=fallback ;;
    --launch-if-stopped) LAUNCH=1 ;;
    --dry-run)           DRY=1 ;;
    --quiet)             QUIET=1 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "karing-restart: неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done
export QUIET

case "$MODE" in
  fallback)
    log "start mode=fallback action=close"
    do_fallback
    exit $?
    ;;
esac

running=0; karing_running && running=1
net=skip
# При --force пробу не делаем: после сна она может «повиснуть» на мёртвом utun
# и съесть секунды до рестарта, который всё равно нужен.
if [ "$MODE" != "force" ]; then
  net=0
  probe_net && net=1
fi
action=$(decide "$running" "$net" "$MODE" "$LAUNCH")
log "start mode=$MODE running=$running net_ok=$net action=$action"

case "$action" in
  restart:*) do_restart ;;
  *)         exit 0 ;;
esac
