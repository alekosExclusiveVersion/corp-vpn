#!/bin/bash
# ==========================================================
# karing-restart.sh — рестарт Karing (user-level, без root).
#
# Зачем: после пробуждения из сна Karing часто остаётся в состоянии
# "Connected", но трафик через его utun мёртв: default-маршрут системы смотрит
# в utun, а пакеты никуда не уходят. По логам 20.10.2026 окно без интернета
# после wake было ~90с (Karing переинициализировался сам только в 07:57:09 при
# пробуждении в 07:55:38). Рестарт приложения даёт детерминированное чистое
# состояние за ~15–25с.
#
# Кто вызывает:
#   ~/.wakeup (sleepwatcher) — `--force --launch-if-stopped` сразу после wake;
#   вручную — `--if-dead` (рестарт только если внешняя проба не проходит).
#
# После рестарта обновляется метка ~/Library/Logs/corp-karing-watch/last-resync,
# чтобы вотчер дрейфа (karing-watch.sh) не перезапустил Karing второй раз в
# пределах своего кулдауна (30 мин).
#
# Режимы:
#   --if-dead            рестарт только если проба интернета не проходит
#                        (по умолчанию; безопасно для ручного запуска);
#   --force              рестарт безусловно (wake-хук: состояние после сна
#                        недостоверно, проба может «повиснуть» на мёртвом utun);
#   --launch-if-stopped  если Karing не запущен — не только рестарт, но и запуск
#                        (без флага закрытое приложение не трогаем: значит,
#                        пользователь закрыл его осознанно);
#   --quiet              не писать в stdout (для хука);
#   -h|--help            справка;
#   --selftest           проверки логики решений (без Karing, без сети).
# ==========================================================
set -uo pipefail

LOGDIR=${CORP_WAKE_LOGDIR:-$HOME/Library/Logs/corp-vpn}
LOG=${KRESTART_LOG:-$LOGDIR/karing-restart.log}
KWATCH_LAST=${KRESTART_KWATCH_LAST:-$HOME/Library/Logs/corp-karing-watch/last-resync}
QUIT_WAIT=${KRESTART_QUIT_WAIT:-10}
UP_WAIT=${KRESTART_UP_WAIT:-25}
PROBE_URLS=${KRESTART_PROBE_URLS:-"https://1.1.1.1/ https://www.google.com/generate_204"}
TUNNEL_SVC=${KRESTART_TUNNEL_SVC:-"Karing (system)"}
CURL=${KRESTART_CURL:-/usr/bin/curl}

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
  [ "${QUIET:-0}" = "1" ] || printf '%s\n' "$*"
}

usage() {
  cat <<'EOF'
Использование: karing-restart.sh [--if-dead|--force] [--launch-if-stopped] [--quiet]
  --if-dead            рестарт только при провале внешней пробы (по умолчанию)
  --force              рестарт безусловно (для wake-хука)
  --launch-if-stopped  запускать Karing, если он не запущен
  --quiet              без вывода в stdout
EOF
}

# --- обёртки внешних эффектов (в selftest подменяются) -----------------------
karing_running() { pgrep -f "Karing.app/Contents/MacOS/Karing" >/dev/null 2>&1; }

karing_quit() {
  /usr/bin/osascript -e 'tell application "Karing" to quit' >/dev/null 2>&1 || true
}

karing_open() { open -a Karing >/dev/null 2>&1 || true; }

tunnel_up() {
  [ "$(scutil --nc status "$TUNNEL_SVC" 2>/dev/null | head -1)" = "Connected" ]
}

# Внешняя проба: любой 2xx/3xx от любого из URL = сеть жива.
probe_net() {
  for url in $PROBE_URLS; do
    code=$("$CURL" -m 4 -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
    case "$code" in
      2??|3??) return 0 ;;
    esac
  done
  return 1
}

wait_tunnel() {
  t=0
  while [ "$t" -lt "$UP_WAIT" ]; do
    tunnel_up && return 0
    sleep 1
    t=$((t + 1))
  done
  return 1
}

# Метка для karing-watch.sh: этот рестарт считается его ресинком, иначе вотчер
# в течение кулдауна может перезапустить Karing ещё раз.
mark_resync() {
  mkdir -p "$(dirname "$KWATCH_LAST")" 2>/dev/null
  date +%s > "$KWATCH_LAST" 2>/dev/null
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
  if karing_running; then
    log "quit Karing"
    karing_quit
    t=0
    while karing_running && [ "$t" -lt "$QUIT_WAIT" ]; do
      sleep 1; t=$((t + 1))
    done
    karing_running && log "WARN: Karing не закрылся за ${QUIT_WAIT}с, продолжаю"
  fi
  log "open Karing"
  karing_open
  if wait_tunnel; then
    log "tunnel up after $(( $(date +%s) - t0 ))s"
  else
    log "WARN: tunnel не поднялся за ${UP_WAIT}с"
  fi
  mark_resync
  if probe_net; then
    log "net probe ok after $(( $(date +%s) - t0 ))s"
    return 0
  fi
  log "net probe FAIL after $(( $(date +%s) - t0 ))s"
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
    --launch-if-stopped) LAUNCH=1 ;;
    --quiet)             QUIET=1 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "karing-restart: неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done
export QUIET

running=0; karing_running && running=1
net=skip
# При --force пробу не делаем: после сна она может «повиснуть» на мёртвом utun
# и съесть 4–8с до рестарта, который всё равно нужен.
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
