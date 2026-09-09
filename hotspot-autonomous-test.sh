#!/usr/bin/env bash
set -u

VC="Karing (system)"
LOG=/tmp/hotspot-test.log
PROBES=("https://www.google.com" "https://api.opencode.ai" "https://one.one.one.one")

snap() {
  local ts nc_state ut defs dns ipnet gw
  ts=$(date '+%H:%M:%S')
  nc_state=$(scutil --nc list | grep -i "karing" | grep -oE '\(Connected\)|\(Disconnected\)' | head -1)
  nc_state=${nc_state:-unknown}
  ut=$(ifconfig utun4 2>/dev/null | grep -oE "mtu [0-9]+|inet [0-9.]+" | tr '\n' ' ')
  defs=$(netstat -rn -f inet | awk '/^default/{print $NF}' | sort -u | tr '\n' ' ')
  ipnet=$(ipconfig getifaddr en0 2>/dev/null; netstat -rn -f inet | awk '/^default/{print $3"->"$NF}' | tr '\n' ' ')
  dns=$(scutil --dns | awk '/nameserver\[/{print $3}' | head -2 | tr '\n' ' ')
  gw=$(arp -n 2>/dev/null | grep -i incomplete | head -1 | awk '{print $2" incomplete"}')
  printf 'SNAP %s\t%-13s en0IP[%s] defs[%s] utun4[%s] dns[%s] gw[%s]\n' "$ts" "$nc_state" "$ipnet" "$defs" "$ut" "$dns" "$gw" >> "$LOG"
}

probe() {
  local ts code label
  ts=$(date '+%H:%M:%S')
  for u in "${PROBES[@]}"; do
    code=$(curl -sS -o /dev/null -m 8 -w '%{http_code}' -I --noproxy '*' "$u" 2>/dev/null || echo 000)
    printf 'PROBE %s\t%s\t%s\n' "$ts" "$code" "$u" >> "$LOG"
  done
  # DNS-резолв отдельно: отличаем "DNS мёртв" от "маршрут мёртв"
  local r
  r=$(dscacheutil -q host -a name www.google.com 2>/dev/null | grep ip_address | head -1)
  printf 'DNSR  %s\t%s\n' "$ts" "${r:-FAIL}" >> "$LOG"
  # Попадание по IP без DNS (важно: на хотспоте nc до узла раньше работал)
  local ipc
  ipc=$(curl -sS -o /dev/null -m 6 -w '%{http_code}' --noproxy '*' --resolve api.opencode.ai:443:104.18.28.234 https://api.opencode.ai 2>/dev/null || echo 000)
  printf 'IPPR  %s\t%s\tapi.opencode.ai (104.18.28.234)\n' "$ts" "$ipc" >> "$LOG"
}

decide() {
  # Если хотя бы одна проба дала рабочий код и utun4 ушёл — интернет без Karing есть
  local ok=no
  if grep -q "PROBE.*200" "$LOG" || grep -q "PROBE.*204" "$LOG"; then ok=yes; fi
  printf 'VERDICT %s\tinternet_without_karing=%s\n' "$(date '+%H:%M:%S')" "$ok" > /dev/null
  echo "$ok"
}

printf 'BEGIN %s (pid %s)\n' "$(date '+%H:%M:%S')" "$$" > "$LOG"
snap
probe

printf 'STOP  %s stopping %s\n' "$(date '+%H:%M:%S')" "$VC" >> "$LOG"
scutil --nc stop "$VC" >/dev/null 2>&1
for i in $(seq 1 20); do
  if ! scutil --nc list | grep -i "karing" | grep -q "Connected"; then break; fi
  sleep 1
done
sleep 2
snap
probe

OK=$(decide)
printf 'DECIDE %s\tinternet_without_karing=%s\n' "$(date '+%H:%M:%S')" "$OK" >> "$LOG"

if [ "$OK" = "yes" ]; then
  printf 'ACTION %s\tKaring OFF оставлен выключенным (интернет работает) — opencode временно недоступен\n' "$(date '+%H:%M:%S')" >> "$LOG"
else
  printf 'ACTION %s\tKaring OFF интернета нет, возвращаю Karing\n' "$(date '+%H:%M:%S')" >> "$LOG"
  for attempt in 1 2 3; do
    scutil --nc start "$VC" >/dev/null 2>&1
    for i in $(seq 1 20); do
      if scutil --nc list | grep -i "karing" | grep -q "Connected"; then break; fi
      sleep 1
    done
    if scutil --nc list | grep -i "karing" | grep -q "Connected"; then
      printf 'RESTORE %s\tKaring Connected (попытка %s)\n' "$(date '+%H:%M:%S')" "$attempt" >> "$LOG"
      break
    fi
    printf 'RESTORE %s\tKaring ещё не Connected (попытка %s), повтор...\n' "$(date '+%H:%M:%S')" "$attempt" >> "$LOG"
  done
  snap
fi

printf 'END   %s см. /tmp/hotspot-test.log\n' "$(date '+%H:%M:%S')" >> "$LOG"
echo "done -> $LOG"