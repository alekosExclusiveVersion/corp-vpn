#!/bin/bash
# ==========================================================
# Генератор direct-правил для Karing из единого файла
# корпоративных сетей (corp-networks.conf).
#
# Запуск:
#   ./karing-rules.sh            # JSON-группы для вставки в Karing
#   ./karing-rules.sh --singbox  # правила в формате sing-box
#   ./karing-rules.sh -i         # применить в конфиг Karing (с бэкапом)
#
# Группы:
#   "ts-network" — вся корпоративная зона из corp-networks.conf
#                  (домены SITE_DOMAINS, суффиксы DOMAIN_SUFFIX, IP
#                  NET_ROUTES/VPN_SERVERS/MYSQL_HOSTS) идёт напрямую
#                  (direct_out). При подключённом корп. VPN сайты
#                  перехватывает ppp-маршрут демона (/32 через ppp),
#                  а не Karing.
#   "На прямую"  — остаётся для личных правок пользователя (напр.
#                  .yandex.ru, .bitrix24.ru); корп. элементы из
#                  конфига из неё переносятся в ts-network.
# Группы "Корп L2TP" больше НЕТ: MySQL/корп. хосты маршрутизирует
# демон corp-vpn-routes (host-маршруты через ppp), поэтому Karing
# не должен перехватывать *.tradesoft.ru (иначе прибивает их к utun).
# ==========================================================
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF=/usr/local/etc/corp-networks.conf
[ -f "$CONF" ] || CONF="$DIR/corp-networks.conf"
[ -f "$CONF" ] || CONF="$(dirname "$DIR")/corp-vpn/corp-networks.conf"

KARING_DIR="$HOME/Library/Group Containers/group.com.nebula.karing"
ROUTING_JSON="$KARING_DIR/karing_routing_group.json"
SUBSCRIBE_JSON="$KARING_DIR/karing_subscribe_use.json"

# shellcheck disable=SC1090
. "$CONF"

# Сайты на корп. серверах (из conf; резервный дефолт на случай старого конфига)
SITE_DOMAINS="${SITE_DOMAINS:-www.amry.ru}"

# MySQL-серверы корп. инфраструктуры (из conf; резервный дефолт). На корп. Wi-Fi
# (VPN L2TP не поднимается) их трафик должен идти в direct_out, иначе уходит в
# нод Karing и сервер видит чужой IP. При поднятом L2TP демон corp-vpn-routes всё
# равно возвращает /32 на ppp0.
# ВАЖНО: MySQL-соединения идут по IP без SNI, поэтому домен в правиле не матчится
# sing-box'ом — нужен ip_cidr. Генератор резолвит MYSQL_HOSTS в IPv4 при каждом
# запуске и добавляет их в ip_cidr группы "На прямую".
MYSQL_HOSTS="${MYSQL_HOSTS:-}"

# Публичные IP VPN-серверов L2TP/IPSec. Они НЕ входят в NET_ROUTES (10/8,
# 192.168/16), поэтому Karing по умолчанию гонит их в узел (utun11), и IPSec
# не может установиться (UDP 500/4500, ESP). Пинем их в группу "На прямую"
# (direct_out) — тогда Karing выпускает их напрямую через en0 и корп VPN
# поднимается и на изолированной корп. Wi-Fi сети.
VPN_SERVERS="${VPN_SERVERS:-}"

to_json_array() {
  local first=1
  for v in $1; do
    [ "$first" -eq 1 ] || printf ', '
    printf '"%s"' "$v"
    first=0
  done
}

group_json() {
  local ds d ip
  ds="$(to_json_array "$DOMAIN_SUFFIX")"
  d="$(to_json_array "$DOMAINS $SITE_DOMAINS $MYSQL_HOSTS")"
  ip="$(to_json_array "$NET_ROUTES $VPN_SERVERS")"
  printf '{\n  "groupid": "custom",\n  "name": "ts-network",\n  "type": "",\n  "or": true,\n'
  [ -n "$ip" ] && printf '  "ip_cidr": [%s],\n' "$ip"
  [ -n "$ds" ] && printf '  "domain_suffix": [%s],\n' "$ds"
  [ -n "$d" ] && printf '  "domain": [%s]\n' "$d"
  printf '}\n'
}

singbox_rule() {
  local parts=() j="" first
  local ds d ip
  ds="$(to_json_array "$DOMAIN_SUFFIX")"
  d="$(to_json_array "$DOMAINS $SITE_DOMAINS $MYSQL_HOSTS")"
  ip="$(to_json_array "$NET_ROUTES $VPN_SERVERS")"
  [ -n "$ip" ] && parts+=("{\"ip_cidr\": [$ip]}")
  [ -n "$ds" ] && parts+=("{\"domain_suffix\": [$ds]}")
  [ -n "$d" ] && parts+=("{\"domain\": [$d]}")
  first=1
  j=""
  for p in "${parts[@]}"; do
    [ "$first" -eq 1 ] || j+=", "
    j+="$p"
    first=0
  done
  printf '{\n  "rules": [%s],\n  "outbound": "direct_out",\n' "$j"
  printf '  "name": "ts-network[Корпоративная сеть]",\n  "type": "logical",\n  "mode": "or"\n}\n'
}

apply() {
  # Синхронизирует группы Karing с corp-networks.conf (с бэкапами):
  #   - группа "На прямую" создаётся из конфига ТОЛЬКО если её нет,
  #     а сайты из SITE_DOMAINS добавляются в её `domain` -> direct_out
  #     (личные правки, напр. .yandex.ru, сохраняются);
  #   - назначения diversion_group и запись final -> currentSelected.
  # Группу "Корп L2TP" (мост) НЕ создаёт: корп. хосты маршрутизирует
  # демон corp-vpn-routes через ppp, Karing их не перехватывает.
  # Работает и при отсутствующих файлах (создаёт с нуля).
  local tmpdir
  tmpdir="$(mktemp -d)"
  group_json > "$tmpdir/direct.json"
  python3 - "$ROUTING_JSON" "$SUBSCRIBE_JSON" "$tmpdir" "$DOMAINS" "$SITE_DOMAINS" "$MYSQL_HOSTS" "$DOMAIN_SUFFIX" "$NET_ROUTES" "$VPN_SERVERS" <<'PY'
import json, sys, shutil, time, os, socket
routing_path, subscribe_path, tmpdir = sys.argv[1:4]
corp_domains = (sys.argv[4] + ' ' + sys.argv[5] + ' ' + sys.argv[6]).split()
mysql_hosts = sys.argv[6].split()
domain_suffixes = sys.argv[7].split() if len(sys.argv) > 7 else []
NET_ROUTES = sys.argv[8].split() if len(sys.argv) > 8 else []
VPN_SERVERS = sys.argv[9].split() if len(sys.argv) > 9 else []
now = time.strftime('%Y%m%d-%H%M%S')

def mysql_ips(hosts):
    out = []
    for h in hosts:
        try:
            for r in socket.getaddrinfo(h, None, socket.AF_INET):
                ip = r[4][0]
                if ip not in out:
                    out.append(ip)
        except socket.gaierror:
            print('WARN: не резолвится MySQL-host:', h, file=sys.stderr)
    return out

def load(path, default):
    if os.path.exists(path):
        try:
            with open(path, encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            pass
    return default

def save(path, data):
    if os.path.exists(path):
        shutil.copy(path, path + '.bak.' + now)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

with open(os.path.join(tmpdir, 'direct.json'), encoding='utf-8') as f:
    direct_group = json.load(f)
mysql_ips = mysql_ips(mysql_hosts)
if mysql_ips:
    direct_group.setdefault('ip_cidr', [])
    for ip in mysql_ips:
        if ip not in direct_group['ip_cidr']:
            direct_group['ip_cidr'].append(ip)

# --- karing_routing_group.json ---
routing = load(routing_path, {})
items = routing.setdefault('items', [])
if not items:
    items.append({"groupid": "custom", "urlOrPath": "", "remark": "Самостоятельная настройка",
                  "editAble": True, "groups": []})
groups = list(items[0].setdefault('groups', []))

def upsert_group(name, build):
    idx = next((i for i, g in enumerate(groups) if g.get('name') == name), None)
    if idx is None:
        groups.append(build(None))
        return
    build(groups[idx])

# Группа "Корп L2TP" больше не создаётся (см. шапку файла):
# корп. хосты маршрутизирует демон corp-vpn-routes через ppp,
# поэтому правил, уводящих *.tradesoft.ru в туннель Karing, нет.

# Группа "ts-network" (direct_out): вся корпоративная зона из конфига
# (домены SITE_DOMAINS/DOMAINS/MYSQL_HOSTS, суффиксы DOMAIN_SUFFIX, IP
# NET_ROUTES/VPN_SERVERS/MYSQL_HOSTS). Существующая группа сохраняет
# личные правки; корп. элементы добавляются в неё.
def network_build(g):
    if g is None:
        return dict(direct_group)
    doms = list(g.get('domain', []))
    for d in corp_domains:
        if d not in doms:
            doms.append(d)
    g['domain'] = doms
    suffixes = list(g.get('domain_suffix', []))
    for s in domain_suffixes:
        if s not in suffixes:
            suffixes.append(s)
    g['domain_suffix'] = suffixes
    existing = set(g.get('ip_cidr', []))
    for c in direct_group.get('ip_cidr', []):
        if c not in existing:
            g.setdefault('ip_cidr', []).append(c)

upsert_group('ts-network', network_build)

# "На прямую": корп. элементы переносятся в ts-network, личные правки
# (напр. .yandex.ru, .bitrix24.ru, .parts-*) остаются в группе.
corp_set = set(corp_domains)
corp_suffix_set = set(domain_suffixes)
corp_ip_set = set(direct_group.get('ip_cidr', []))
for g in groups:
    if g.get('name') == 'На прямую':
        g['domain'] = [d for d in g.get('domain', []) if d not in corp_set]
        g['domain_suffix'] = [s for s in g.get('domain_suffix', []) if s not in corp_suffix_set]
        g['ip_cidr'] = [c for c in g.get('ip_cidr', []) if c not in corp_ip_set]
        break

items[0]['groups'] = groups
routing.setdefault('rule_set_items', [])
save(routing_path, routing)

# --- karing_subscribe_use.json: назначения групп -> outbound ---
sub = load(subscribe_path, {})
div = sub.setdefault('diversion_group', [])

def upsert(name, entry):
    for i, e in enumerate(div):
        if e.get('diversion_name') == name:
            div[i] = entry
            return
    div.append(entry)

upsert('ts-network', {"diversion_groupid": "custom", "diversion_name": "ts-network",
                      "server_groupid": "direct", "server_name": "direct_out", "dns_servers": []})
if not any(e.get('diversion_groupid') == 'final' for e in div):
    div.append({"diversion_groupid": "final", "diversion_name": "",
                "server_groupid": "currentSelected", "server_name": "", "dns_servers": []})
sub['diversion_group'] = div
save(subscribe_path, sub)

print('OK: группа "ts-network" синхронизирована с corp-networks.conf')
print('    корп. домены/суффиксы/IP -> "ts-network" (direct_out)')
print('    личные правки остались в "На прямую"')
print('    ' + routing_path)
PY
  rm -rf "$tmpdir"
}

case "${1:-}" in
  -i|--apply) apply ;;
  --singbox)  singbox_rule ;;
  *)          group_json ;;
esac
