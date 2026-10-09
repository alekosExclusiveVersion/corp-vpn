#!/bin/bash
# Фоновый диагностический логгер сети + корп. VPN (пилот MAC-детекта).
#
# Задачи:
#   1) собирать картину при переключении между Wi-Fi сетями (офис <-> хотспот):
#      IP en0, MAC en0, ARP-MAC шлюза, default-интерфейсы, состояние Karing,
#      статусы всех L2TP-профилей, наличие ppp0;
#   2) ловить момент ручной попытки поднять корп. VPN (смена статуса профиля),
#      чтобы видеть ошибку/результат попытки на внеофисной сети.
#
# Работает single-shot: каждый вызов делает один снимок и завершается.
# Запускается LaunchDaemon'ом com.tradesoft.corp-vpn-diag каждые 10 секунд.
# Показывает CHANGED при изменении сети/VPN, иначе tick — но каждые ~30с
# (3-й снимок) сам снимок пишется целиком, чтобы видеть медленную динамику.
#
# Лог: /var/log/corp-vpn-diag.log (по умолчанию; переопределить через CORP_DIAG_LOG).
# Вручную:  sh corp-vpn-diagd.sh
# Останов (если запущен вручную): pkill -f corp-vpn-diagd.sh

LOG="${CORP_DIAG_LOG:-/var/log/corp-vpn-diag.log}"
LOCK=/tmp/corp-vpn-diagd.pid

# PID-замок (одна копия)
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

PROFILES="vpn1-ts vpn2-ts vpn3-ts vpn4-ts"
STATE_DIR=/tmp/corp-vpn-diagd
mkdir -p "$STATE_DIR" 2>/dev/null
LAST="$STATE_DIR/last"
CNT="$STATE_DIR/count"

# Ограничиваем размер лога ~5000 строк (пилот)
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 5000 ]; then
  tail -2500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

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

# Является ли en0 корп. Wi-Fi по IP (критерий демонов, для контекста в логе).
is_corp_ip() { ipconfig getifaddr en0 2>/dev/null | grep -qE '^192\.168\.128\.'; }

stamp=$(date '+%H:%M:%S')
en0_ip=$(ipconfig getifaddr en0 2>/dev/null || echo "-")
en0_mac=$(ifconfig en0 2>/dev/null | awk '/^[[:space:]]*ether /{print $2}')
gm=$(gw_mac)
defs=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $NF}' | sort -u | tr '\n' ' ' | sed 's/ $//')
karing=$(scutil --nc status "Karing (system)" 2>/dev/null | head -1)
vpn=""
for p in $PROFILES; do
  s=$(scutil --nc status "$p" 2>/dev/null | head -1)
  [ -n "$s" ] && vpn="$vpn $p=$s"
done
if ifconfig ppp0 >/dev/null 2>&1; then ppp="ppp=ON"; else ppp="ppp=off"; fi

corp="not-corp"
is_corp_ip && corp="corp"

# Битые fakeip-маршруты Karing (когда пакеты к 198.20.0.x уходят в en0 вместо utun4)
# = известный баг, симптом "домен через Karing = 000, а с реальным IP = 200".
fp_badroutes=$(netstat -rn -f inet 2>/dev/null | awk '
  $1 ~ /^198\.(18|19|20|21)\./ && $4 !~ /^utun/ { printf "%s(%s) ", $1, $4 }
')

# Фантомный шлюз из fake-IP у host-маршрута: назначение реальное, шлюз не
# резолвится в ARP, поэтому пакет физическим интерфейсом уйти не может
# (инцидент p7ru5 30.09.2026: 212.41.11.239 -> 198.20.0.35 -> en0).
# Метрика только в лог: отдельный сигнал не шлём, чтобы не плодить уведомления —
# сам факт и лечение живут в corp-routes-clean.sh (--check, PHANTOM new/confirmed).
gw_badroutes=$(netstat -rn -f inet 2>/dev/null | awk '
  $2 ~ /^198\.(18|19|20|21)\./ && $3 ~ /H/ && $4 !~ /^utun/ && $4 != "lo0" &&
  $1 !~ /^198\.(18|19|20|21)\./ { printf "%s(gw=%s if=%s) ", $1, $2, $4 }
')

# Сигнал о появлении/исчезновении битых fakeip-маршрутов (только на переходе).
# Файл-очередь читает юзер-агент corp-notify.sh и показывает уведомление.
SIGNALS="${CORP_SIGNALS:-/var/run/corp-vpn-signals}"
signal() { echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2" >> "$SIGNALS"; }
BAD_LAST="$STATE_DIR/badroutes.last"
bad_now=$(printf '%s' "$fp_badroutes" | sed 's/ $//')
bad_last=$(cat "$BAD_LAST" 2>/dev/null)
if [ "$bad_now" != "$bad_last" ]; then
  if [ -n "$bad_now" ]; then
    log "BADROUTES_ON $stamp {$bad_now}"
    signal "badroutes.on" "битые fake-IP: {$bad_now}"
  else
    log "BADROUTES_OFF $stamp"
    signal "badroutes.off" "битые fake-IP исчезли"
  fi
fi
echo "$bad_now" > "$BAD_LAST"

fp="ip=$en0_ip mac_en0=$en0_mac gw_mac=${gm:-?} defs=[$defs] $corp karing=$karing$vpn $ppp"
[ -n "$fp_badroutes" ] && fp="$fp BADROUTES={$fp_badroutes}"
[ -n "$gw_badroutes" ] && fp="$fp PHANTOMG={$gw_badroutes}"
last=$(cat "$LAST" 2>/dev/null)

c=0; [ -f "$CNT" ] && c=$(cat "$CNT" 2>/dev/null)
if [ "$fp" != "$last" ]; then
  log "CHANGED $stamp $fp"
  c=0
elif [ $((c % 3)) -eq 0 ]; then
  log "tick    $stamp $fp"
fi
c=$((c + 1)); echo "$c" > "$CNT"
echo "$fp" > "$LAST"
exit 0