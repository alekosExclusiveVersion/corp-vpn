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
#   sites-sync.ok / skip / fail / rollback актуализация доменов
#     (corp-sites-sync): ok/skip — только баннер, fail/rollback — ещё
#     и в B24+Telegram
#   sites-learn.add новый домен в ts-network (corp-learn) — только баннер
#
# Обработка: байтовый указатель читает только НОВЫЕ строки файла (POS-файл).
# Дедупликация: одно и то же событие (event|message) не чаще раза в 30 сек
# (подавляем повторы, н-р на флапе VPN).

SIGNALS="${CORP_SIGNALS:-/var/run/corp-vpn-signals}"
POS="${CORP_NOTIFY_POS:-/tmp/corp-vpn-notify.pos}"
SEEN="${CORP_NOTIFY_SEEN:-/tmp/corp-vpn-notify.seen}"
MIN_GAP=30
NOTIFY_PY="${MONITORING_NOTIFY:-$HOME/Work/scripts/monitoring/notify.py}"

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
    db-clean.ok)      title="aisql: БД удалены" ;;
    db-clean.dryrun)  title="aisql: кандидаты на удаление" ;;
    db-clean.fail)    title="aisql: ошибка очистки" ;;
    sites-sync.ok)    title="домены: списки синхронизированы" ;;
    sites-sync.skip)  title="домены: прогоны пропущены" ;;
    sites-sync.fail)  title="домены: ошибка синхронизации" ;;
    sites-sync.rollback) title="домены: откат на бэкап" ;;
    sites-learn.add)  title="ts-network: новый домен" ;;
    *)                title="corp-vpn: $event" ;;
  esac
  osascript -e "display notification \"$msg\" with title \"$title\" sound name \"default\"" 2>/dev/null

  # Дублируем события очистки БД aisql в B24 и Telegram (секреты — Keychain).
  # Из sites-sync дублируем только аварии (fail/rollback): ok приходит
  # 3 раза в день и заспамит тему алертов.
  case "$event" in
    db-clean.*|sites-sync.fail|sites-sync.rollback)
      if [ -x "/opt/homebrew/bin/python3" ] && [ -f "$NOTIFY_PY" ]; then
        /opt/homebrew/bin/python3 "$NOTIFY_PY" "$title: $msg" "$title" >/dev/null 2>&1
      fi
      ;;
  esac
}

recently_shown() {
  key=$1
  [ -f "$SEEN" ] || return 1
  # Метка времени — ПОСЛЕДНЕЕ поле строки ($NF): сообщение может содержать
  # пробелы (напр. IP в routes-dead.del), $2 тогда не метка, а мусор,
  # и арифметика падала с "syntax error: invalid arithmetic operator".
  last=$(grep -F "$key " "$SEEN" 2>/dev/null | tail -1 | awk '{print $NF}')
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