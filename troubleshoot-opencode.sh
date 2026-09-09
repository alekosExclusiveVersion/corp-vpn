#!/bin/bash
# Автономный диагностический замер доступности opencode-чата на текущей сети.
# Цель: найти точку обрыва api.opencode.ai, когда Karing включён, на разных Wi-Fi
# (корп. сеть работает, хотспот/дома — нет). Без sudo: пишет в /tmp/opencode-hotspot-diag.log
# Запуск:  sh troubleshoot-opencode.sh [COUNT] [INTERVAL]
#   COUNT     — число замеров (по умолчанию 8)
#   INTERVAL  — секунд между замерами (по умолчанию 15)
# По завершении печатает путь к логу и EXIT 0.

LOG=/tmp/opencode-hotspot-diag.log
LOCK=/tmp/opencode-hotspot-diag.pid
KARING_BASE="/Users/aleksei/Library/Group Containers/group.com.nebula.karing"

COUNT=${1:-8}
INTERVAL=${2:-15}

# PID-замок (одна копия)
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "already running pid=$(cat "$LOCK")" >&2
  exit 1
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

default_ifaces() { netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $NF}' | sort -u | tr '\n' ' '; }

mac_en0() { ifconfig en0 2>/dev/null | awk '/ether/{print $2}'; }

# gw_mac из ARP (пытаемся получить; не всегда доступен без ping)
gw_mac() {
  local gw ip
  ip=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
  [ -z "$ip" ] && { echo "?"; return; }
  arp -a -n 2>/dev/null | awk -v ip="$ip" '$2 ~ "^\\(" ip "\\)"{gsub(/[()]/,"",$2); print $4; exit}'
}

route_dst_via() {
  local dst="$1"
  route -n get "$dst" 2>/dev/null | awk -v d="$dst" '/interface:|gateway:/{printf "%s ", $2} END{print ""}'
}

# host-маршруты /32 по интересующим IP (интерфейс)
host_routes() {
  netstat -rn -f inet 2>/dev/null | awk '$1 ~ /\/32$/ || $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1, $2, $NF}'
}

# Скрипт интерактивной диагностики через Clash API Karing (без вывода секрета)
clash_probe() {
  python3 - "$KARING_BASE" <<'PYEOF'
import json, sys, urllib.request
base = sys.argv[1]
try:
    cfg = json.load(open(base + '/service_core.json'))
except Exception as e:
    print('clash_err: cannot read service_core.json:', e); sys.exit()
api = cfg.get('experimental', {}).get('clash_api', {})
host = api.get('external_controller') or '127.0.0.1:3057'
secret = api.get('secret') or ''
def get(path):
    r = urllib.request.Request('http://' + host + path)
    if secret: r.add_header('Authorization', 'Bearer ' + secret)
    try:
        return json.load(urllib.request.urlopen(r, timeout=4))
    except Exception as e:
        return {'err': str(e)}
p = get('/proxies')
if 'err' in p:
    print('proxies_err:', p['err']); 
else:
    for name, pr in p.get('proxies', {}).items():
        t = pr.get('type')
        if t in ('urltest',) or (t in ('Selector', 'Fallback') and pr.get('now')):
            print('proxy[%s] type=%s now=%s alive=%s' % (name, t, pr.get('now'), pr.get('alive')))
c = get('/connections')
if 'err' in c:
    print('connections_err:', c['err'])
else:
    seen = set()
    for conn in c.get('connections', []):
        md = conn.get('metadata', {})
        h = md.get('host') or md.get('destinationIP')
        if h and ('opencode' in str(h).lower() or 'gstatic' in str(h).lower() or 'generate_204' in str(h).lower()):
            key = (str(h), md.get('destinationPort'))
            if key in seen: continue
            seen.add(key)
            print('conn host=%s port=%s chains=%s rule=%s payload=%s' % (
                key[0], key[1], conn.get('chains'), md.get('rule'), md.get('rulePayload')))
PYEOF
}

measure() {
  local n="$1"
  log "===== measurement #$n ====="
  log "net wifi-ip=$(ipconfig getifaddr en0 2>/dev/null) mac_en0=$(mac_en0) gw_mac=$(gw_mac) default-ifs=[$(default_ifaces)]"
  log "route api.opencode.ai(198.20.0.15): $(route_dst_via 198.20.0.15)"
  log "route node.geodema(212.193.31.221): $(route_dst_via 212.193.31.221)"
  log "host-routes: $(host_routes | tr '\n' '; ')"
  log "nc node 212.193.31.221:443 -> $(nc -z -w4 212.193.31.221 443 2>/dev/null && echo OK || echo FAIL)"
  log "curl direct api.opencode.ai -> $(curl -m6 -s -o /dev/null -w '%{http_code} t=%{time_total}s ip=%{remote_ip}' https://api.opencode.ai/ 2>&1)"
  log "curl via 127.0.0.1:3067 api.opencode.ai -> $(curl -m6 -s -x http://127.0.0.1:3067 -o /dev/null -w '%{http_code} t=%{time_total}s' https://api.opencode.ai/ 2>&1)"
  log "curl gstatic(204) direct -> $(curl -m6 -s -o /dev/null -w '%{http_code} t=%{time_total}s' https://www.gstatic.com/generate_204 2>&1)"
  log "clash:"
  clash_probe | sed 's/^/    /' >> "$LOG"
}

: > "$LOG"
log "=== troubleshoot-opencode started pid $$ count=$COUNT interval=${INTERVAL}s ==="
measure 0

for i in $(seq 1 "$COUNT"); do
  sleep "$INTERVAL"
  measure "$i"
done

log "=== troubleshoot-opencode finished ==="
echo "готово. Лог: $LOG"