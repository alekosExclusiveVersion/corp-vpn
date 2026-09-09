#!/usr/bin/env bash
set -u

VC="Karing (system)"
LOG=/tmp/karing-isolate.log
PROBES=("https://www.google.com" "https://api.opencode.ai" "https://one.one.one.one")

snap() {
  local ts nc_state ut defs
  ts=$(date '+%H:%M:%S')
  nc_state=$(scutil --nc list | grep -i "karing" | grep -oE '\(Connected\)|\(Disconnected\)' | head -1)
  nc_state=${nc_state:-unknown}
  ut=$(ifconfig utun4 2>/dev/null | grep -oE "mtu [0-9]+|inet [0-9.]+" | tr '\n' ' ')
  defs=$(netstat -rn -f inet | awk '/^default/{print $NF}' | sort -u | tr '\n' ' ')
  dns=$(scutil --dns | awk '/nameserver\[/{print $3}' | head -2 | tr '\n' ' ')
  printf 'SNAP %s\t%-13s utun4[%s] defs[%s] dns[%s]\n' "$ts" "$nc_state" "$ut" "$defs" "$dns" >> "$LOG"
}

probe() {
  local ts code
  ts=$(date '+%H:%M:%S')
  for u in "${PROBES[@]}"; do
    code=$(curl -sS -o /dev/null -m 8 -w '%{http_code}' -I "$u" 2>/dev/null || echo 000)
    printf 'PROBE %s\t%s\t%s\n' "$ts" "$code" "$u" >> "$LOG"
  done
}

restore() {
  printf 'RESTORE %s start restore of %s\n' "$(date '+%H:%M:%S')" "$VC" >> "$LOG"
  scutil --nc start "$VC" >/dev/null 2>&1
  for i in $(seq 1 30); do
    if scutil --nc list | grep -i "karing" | grep -q "Connected"; then break; fi
    sleep 1
  done
  printf 'RESTORE %s after start: %s\n' "$(date '+%H:%M:%S')" \
    "$(scutil --nc list | grep -i karing | grep -oE '\(Connected\)|\(Disconnected\)' | head -1)" >> "$LOG"
  snap
}

restore_on_signal() {
  trap - TERM INT HUP EXIT
  restore
  exit 0
}
trap restore EXIT
trap restore_on_signal TERM INT HUP

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

printf 'END   %s (auto-restore via trap)\n' "$(date '+%H:%M:%S')" >> "$LOG"
exit 0