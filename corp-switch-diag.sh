#!/bin/bash
# Автономный диагностический логгер перехода между Wi-Fi сетями.
# Фиксирует смену IP/сети en0, статусы корп. VPN-профилей и Karing.
# Работает без sudo: пишет в /tmp/corp-switch-diag.log
# Запуск:  sh corp-switch-diag.sh  (или nohup ... &)
# Останов: pkill -f corp-switch-diag.sh

LOG=/tmp/corp-switch-diag.log
LOCK=/tmp/corp-switch-diag.pid

# PID-замок (одна копия)
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "already running pid=$(cat "$LOCK")" >&2
  exit 1
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

last_wifi=""
last_ip=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

wifi_name() { networksetup -getairportnetwork en0 2>/dev/null | sed 's/^Current Wi-Fi Network: //'; }

# Фактически ассоциирован ли Wi-Fi (en0 не "not associated")
wifi_associated() {
  local s
  s=$(wifi_name)
  case "$s" in
    ""|"You are not associated with an AirPort network."|"Not associated"*) return 1 ;;
  esac
  return 0
}

# Кто держит default-маршруты (интерфейсы)
default_ifaces() {
  netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $NF}' | sort -u | tr '\n' ' '
}

# Краткий статус каждого корп. профиля + Karing
nc_status() {
  local out=""
  for p in vpn3-ts vpn4 vpn2-ts vpn1-ts; do
    s=$(scutil --nc status "$p" 2>/dev/null | head -1)
    [ -n "$s" ] && out="$out $p=$s"
  done
  # Karing системный
  k=$(scutil --nc status "Karing (system)" 2>/dev/null | head -1)
  [ -n "$k" ] && out="$out Karing=$k"
  echo "$out"
}

log "=== corp-switch-diag started (pid $$) ==="
log "initial wifi=$(wifi_name) ip=$(ipconfig getifaddr en0) default-ifs=[$(default_ifaces)]"
log "initial VPN statuses:$(nc_status)"

while true; do
  cur_wifi=$(wifi_name)
  cur_ip=$(ipconfig getifaddr en0 2>/dev/null)
  cur_def=$(default_ifaces)
  if wifi_associated; then cur_assoc="assoc=$cur_wifi"; else cur_assoc="assoc=NONE"; fi

  changed=0
  if [ "$cur_wifi" != "$last_wifi" ] || [ "$cur_ip" != "$last_ip" ]; then
    log "NET-CHANGE wifi=[$last_wifi]->[$cur_wifi] $cur_assoc ip=[$last_ip]->[$cur_ip] default-ifs=[$cur_def] is_corp_ip=[$(echo "$cur_ip" | grep -cE '^192\.168\.128\.')] VPN:$(nc_status)"
    changed=1
  fi
  last_wifi="$cur_wifi"
  last_ip="$cur_ip"

  # Каждые 15с логируем статусы (по умолчанию — только при изменениях).
  # Для диагностики переключения пишем сеть и VPN каждые 15с тоже.
  if [ $(( $(date +%s) % 15 )) -lt 5 ]; then
    log "tick wifi=[$cur_wifi] $cur_assoc ip=[$cur_ip] default-ifs=[$cur_def] VPN:$(nc_status)"
  fi
  sleep 5
done
