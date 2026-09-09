#!/bin/sh

# Юзер-агент уведомлений (LaunchAgent com.tradesoft.corp-notify, каждые 10 сек,
# от пользователя). Читает сигнальную очередь root-демонов
# (/var/run/corp-vpn-signals) и показывает баннеры Notification Center.
#
# Сигналы (строки: ts|event|message):
#   routes-dead.del   мёртвый маршрут удалён (corp-routes-clean)
#   routes-dead.fail  не удалось удалить мёртвый маршрут
#   badroutes.on      появились битые fake-IP маршруты (corp-vpn-diagd)
#   badroutes.off     битые fake-IP исчезли
#   vpn.up / vpn.down корп VPN поднялся/отключился (corp-vpn-routes)
#
# Обработка: байтовый указатель читает только НОВЫЕ строки файла (POS-файл).
# Дедупликация: одно и то же событие (event|message) не чаще раза в 30 сек
# (подавляем повторы, н-р на флапе VPN).

SIGNALS="${CORP_SIGNALS:-/var/run/corp-vpn-signals}"
POS="${CORP_NOTIFY_POS:-/tmp/corp-vpn-notify.pos}"
SEEN="${CORP_NOTIFY_SEEN:-/tmp/corp-vpn-notify.seen}"
MIN_GAP=30

notify() {
  event=$1
  msg=$2
  case "$event" in
    routes-dead.del)  title="corp-vpn: маршрут исправлен" ;;
    routes-dead.fail) title="corp-vpn: не удалось удалить маршрут" ;;
    badroutes.on)     title="corp-vpn: битые fake-IP маршруты" ;;
    badroutes.off)    title="corp-vpn: маршруты чисты" ;;
    vpn.up)           title="corp-vpn: VPN активен" ;;
    vpn.down)         title="corp-vpn: VPN отключился" ;;
    *)                title="corp-vpn: $event" ;;
  esac
  osascript -e "display notification \"$msg\" with title \"$title\" sound name \"default\"" 2>/dev/null
}

recently_shown() {
  key=$1
  [ -f "$SEEN" ] || return 1
  last=$(grep -F "$key " "$SEEN" 2>/dev/null | tail -1 | awk '{print $2}')
  [ -n "$last" ] || return 1
  now=$(date +%s)
  [ $(( now - last )) -lt "$MIN_GAP" ]
}

mark_shown() {
  echo "$1 $(date +%s)" >> "$SEEN"
  if [ "$(wc -l < "$SEEN")" -gt 100 ]; then
    tail -100 "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
  fi
}

[ -r "$SIGNALS" ] || exit 0

total=$(wc -c < "$SIGNALS" 2>/dev/null || echo 0)
prev=0
[ -f "$POS" ] && prev=$(cat "$POS" 2>/dev/null || echo 0)
# Файл мог быть обрезан (ротация у root-демона): байтовый указатель невалиден.
# Пропускаем текущее содержимое целиком (события ротации редки, 1/200+), чтобы
# не перечитывать старые строки и не спамить баннерами.
if [ "$total" -lt "$prev" ] 2>/dev/null; then
  echo "$total" > "$POS"
  exit 0
fi

if [ "$total" -gt "$prev" ]; then
  tail -c +$(( prev + 1 )) "$SIGNALS" | tr -d '\r' | while IFS='|' read -r ts event msg; do
    [ -n "$event" ] || continue
    key="$event|$msg"
    if ! recently_shown "$key"; then
      notify "$event" "$msg"
      mark_shown "$key"
    fi
  done
fi

echo "$total" > "$POS"
exit 0