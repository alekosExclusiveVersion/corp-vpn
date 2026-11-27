#!/bin/bash
# ==========================================================
# Генератор direct-правил для Karing из единого файла
# корпоративных сетей (corp-networks.conf).
#
# Запуск:
#   ./karing-rules.sh            # JSON-группы для вставки в Karing
#   ./karing-rules.sh --singbox  # правила в формате sing-box
#   ./karing-rules.sh --dns      # статические DNS-записи RDP-хостов (JSON)
#   ./karing-rules.sh --check    # сверять live-конфиг Karing с corp-networks.conf
#   ./karing-rules.sh -i         # применить в конфиг Karing (с бэкапом)
#
# ВАЖНО про -i: работающий Karing держит конфигурацию в памяти и периодически
# перезаписывает ею файл, поэтому правки, сделанные -i, пропадают. Перед -i
# приложение нужно закрыть; --check показывает расхождения и предупреждает,
# что Karing запущен.
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
# DNS-статистика (karing_setting.json, dns.static_ips): RDP-хосты из
#           RDP_STATIC_IPS резолвятся в реальные IP, а не в fake-IP
#           198.20.0.x. Иначе сокет Windows App садится на utun4 и сессия
#           рвётся при каждом рестарте Karing (NetworkMonitor пишет
#           "VPN is inactive ... Status=unsatisfied"). Настройка живёт в
#           settings Karing и переживает рестарт; править service_core.json
#           бесполезно — Karing перезаписывает его из своей памяти.
# Группы "Корп L2TP" больше НЕТ: MySQL/корп. хосты маршрутизирует
# демон corp-vpn-routes (host-маршруты через ppp), поэтому Karing
# не должен перехватывать *.tradesoft.ru (иначе прибивает их к utun).
# ==========================================================
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${CORP_NETWORKS_CONF:-/usr/local/etc/corp-networks.conf}"
[ -f "$CONF" ] || CONF="$DIR/corp-networks.conf"
[ -f "$CONF" ] || CONF="$(dirname "$DIR")/corp-vpn/corp-networks.conf"

KARING_DIR="$HOME/Library/Group Containers/group.com.nebula.karing"
ROUTING_JSON="$KARING_DIR/karing_routing_group.json"
SUBSCRIBE_JSON="$KARING_DIR/karing_subscribe_use.json"
SETTINGS_JSON="$KARING_DIR/karing_setting.json"

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

# Домены автодетекта corp-learn.sh (по одному на строку). Демон
# corp-vpn-routes.sh уже маршрутизирует их через ppp; здесь они попадают
# в ts-network (direct_out), чтобы работали и без VPN на корп. Wi-Fi.
# Переопределяется через CORP_NETWORKS_AUTO (нужно selftest на фикстурах).
AUTO_CONF="${CORP_NETWORKS_AUTO:-/usr/local/etc/corp-networks-auto.conf}"
AUTO_SITE_DOMAINS="$(grep -vE '^[[:space:]]*(#|$)' "$AUTO_CONF" 2>/dev/null | tr '\n' ' ')"

# RDP-хосты, которым нужно принудительно задать реальный IP вместо fake-IP
# Karing. Формат: "host=ip host2=ip2" (IP явно, без резолва на лету —
# иначе можно записать fake-IP 198.20.0.x как "статический"). Хранится в
# dns.static_ips настроек Karing и не затирается при рестарте приложения.
RDP_STATIC_IPS="${RDP_STATIC_IPS:-}"
# Устаревшие хосты — удаляются из dns.static_ips при -i.
RDP_STATIC_IPS_DROP="${RDP_STATIC_IPS_DROP:-}"

to_json_array() {
  # Повторы убираются с сохранением порядка: SITE_DOMAINS и MYSQL_HOSTS
  # пересекаются (хост БД одновременно является сайтом), и без дедупа
  # один и тот же домен попадал в группу дважды.
  local first=1 v seen=" "
  for v in $1; do
    case "$seen" in *" $v "*) continue ;; esac
    seen="$seen$v "
    [ "$first" -eq 1 ] || printf ', '
    printf '"%s"' "$v"
    first=0
  done
}

group_json() {
  local ds d ip
  ds="$(to_json_array "$DOMAIN_SUFFIX")"
  d="$(to_json_array "$DOMAINS $SITE_DOMAINS $MYSQL_HOSTS $AUTO_SITE_DOMAINS")"
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
  d="$(to_json_array "$DOMAINS $SITE_DOMAINS $MYSQL_HOSTS $AUTO_SITE_DOMAINS")"
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

static_ips_json() {
  # Статические DNS-записи для dns.static_ips Karing (RDP-хосты -> реальные IP).
  python3 - "$RDP_STATIC_IPS" "$RDP_STATIC_IPS_DROP" <<'PY'
import json, sys
drop = sys.argv[2].split()
out = {}
for item in sys.argv[1].split():
    if '=' not in item:
        print(f'WARN: пропущено «{item}» — ожидался host=ip', file=sys.stderr)
        continue
    host, ip = item.split('=', 1)
    if host and ip:
        out.setdefault(host, [])
        if ip not in out[host]:
            out[host].append(ip)
print(json.dumps({"enable_static_ip": True, "static_ips": out, "drop": drop},
                 ensure_ascii=False, indent=2))
PY
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
  python3 - "$ROUTING_JSON" "$SUBSCRIBE_JSON" "$tmpdir" "$DOMAINS" "$SITE_DOMAINS" "$MYSQL_HOSTS" "$DOMAIN_SUFFIX" "$NET_ROUTES" "$VPN_SERVERS" "$AUTO_SITE_DOMAINS" "$SETTINGS_JSON" "$RDP_STATIC_IPS" "$RDP_STATIC_IPS_DROP" <<'PY'
import json, sys, shutil, time, os, socket
routing_path, subscribe_path, tmpdir = sys.argv[1:4]
settings_path, rdp_static_raw = sys.argv[11:13]
rdp_drop = sys.argv[13].split() if len(sys.argv) > 13 else []
corp_domains = (sys.argv[4] + ' ' + sys.argv[5] + ' ' + sys.argv[6] + ' ' + sys.argv[10]).split()
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
def dedup(seq):
    out, seen = [], set()
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out

def network_build(g):
    if g is None:
        return dict(direct_group)
    doms = list(g.get('domain', []))
    for d in corp_domains:
        if d not in doms:
            doms.append(d)
    # Список чистится целиком: перекрытие SITE_DOMAINS и MYSQL_HOSTS даёт
    # повторы, а apply() сохраняет существующие элементы, поэтому старые
    # дубли иначе остались бы навсегда.
    g['domain'] = dedup(doms)
    suffixes = list(g.get('domain_suffix', []))
    for s in domain_suffixes:
        if s not in suffixes:
            suffixes.append(s)
    g['domain_suffix'] = dedup(suffixes)
    existing = set(g.get('ip_cidr', []))
    for c in direct_group.get('ip_cidr', []):
        if c not in existing:
            g.setdefault('ip_cidr', []).append(c)
    g['ip_cidr'] = dedup(g['ip_cidr'])

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

# --- karing_setting.json: статические DNS-записи RDP-хостов ---
# service_core.json править бесполезно: Karing перезаписывает его из
# своей памяти при старте. Настройки (dns.static_ips) живут в settings
# и переживают рестарт. Личные записи не трогаем.
wanted = {}
for item in rdp_static_raw.split():
    if '=' in item:
        host, ip = item.split('=', 1)
        if host and ip:
            wanted.setdefault(host, [])
            if ip not in wanted[host]:
                wanted[host].append(ip)
settings = load(settings_path, None)
if settings is None:
    print('WARN: karing_setting.json отсутствует/не читается — static_ips не применены',
          file=sys.stderr)
else:
    dns = settings.setdefault('dns', {})
    dns['enable_static_ip'] = True
    static = dns.setdefault('static_ips', {})
    for host in rdp_drop:
        static.pop(host, None)
    for host, ips in wanted.items():
        # fake-IP из пула Karing не должен остаться "статическим"
        cur = [x for x in static.get(host, [])
               if not x.startswith(('198.18.', '198.19.', '198.20.', '198.21.'))]
        for ip in ips:
            if ip not in cur:
                cur.append(ip)
        static[host] = cur
    save(settings_path, settings)

print('OK: группа "ts-network" синхронизирована с corp-networks.conf')
print('    корп. домены/суффиксы/IP -> "ts-network" (direct_out)')
print('    личные правки остались в "На прямую"')
print(f'    DNS static_ips (RDP): {len(wanted)} хостов, удалено устаревших: '
      f'{len(rdp_drop)} -> karing_setting.json')
print('    ' + routing_path)
PY
  rm -rf "$tmpdir"
}

check() {
  # Только читает live-конфиг Karing и сверяет его с corp-networks.conf.
  # Ничего не изменяет. Код возврата: 0 — расхождений нет, 1 — есть дрейф,
  # 2 — конфиг не прочитан (пригодно как гейт в мониторинге).
  python3 - "$0" "$ROUTING_JSON" "$SUBSCRIBE_JSON" "$DOMAINS" "$SITE_DOMAINS" \
      "$MYSQL_HOSTS" "$DOMAIN_SUFFIX" "$NET_ROUTES" "$VPN_SERVERS" "$AUTO_SITE_DOMAINS" \
      "$SETTINGS_JSON" "$RDP_STATIC_IPS" "$RDP_STATIC_IPS_DROP" <<'PY'
import json, sys, os, socket, subprocess

self_name = sys.argv[1]
routing_path, subscribe_path = sys.argv[2:4]
settings_path, rdp_static_raw = sys.argv[11:13]
rdp_drop = sys.argv[13].split() if len(sys.argv) > 13 else []
DOMAINS, SITE_DOMAINS, MYSQL_HOSTS, DOMAIN_SUFFIX, NET_ROUTES, VPN_SERVERS, AUTO_DOMAINS = \
    (sys.argv[i].split() for i in range(4, 11))

managed = {
    'domain': DOMAINS + SITE_DOMAINS + MYSQL_HOSTS + AUTO_DOMAINS,
    'domain_suffix': DOMAIN_SUFFIX,
    'ip_cidr': NET_ROUTES + VPN_SERVERS,
}

unresolved = []
for host in MYSQL_HOSTS:
    try:
        for r in socket.getaddrinfo(host, None, socket.AF_INET):
            ip = r[4][0]
            if ip not in managed['ip_cidr']:
                managed['ip_cidr'].append(ip)
    except socket.gaierror:
        unresolved.append(host)

def uniq(seq):
    out, seen = [], set()
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out

managed = {k: uniq(v) for k, v in managed.items()}

try:
    with open(routing_path, encoding='utf-8') as f:
        routing = json.load(f)
except Exception as ex:
    print(f"Не удалось прочитать {routing_path}: {ex}", file=sys.stderr)
    sys.exit(2)

groups = []
for item in routing.get('items', []):
    groups.extend(item.get('groups', []))
ts = next((g for g in groups if g.get('name') == 'ts-network'), None)

print("Проверка дрейфа ts-network")
print("  конфиг: " + routing_path)

try:
    p = subprocess.run(['pgrep', '-f', 'Karing.app/Contents/MacOS/Karing'],
                       capture_output=True, text=True, check=False)
    pids = p.stdout.split()
except OSError:
    pids = []
if pids:
    print("  Karing: ЗАПУЩЕН (PID " + ", ".join(pids) + ") — он держит конфиг в памяти"
          " и перезапишет файл при следующем сохранении, поэтому -i не закрепится")
else:
    print("  Karing: не запущен — -i закрепится")

if ts is None:
    print("  группа ts-network: ОТСУТСТВУЕТ в live-конфиге")
    sys.exit(1)

drift = 0
for key in ('domain', 'domain_suffix', 'ip_cidr'):
    want = managed[key]
    live = ts.get(key, [])
    uniq = set(live)
    missing = [x for x in want if x not in uniq]
    extra = sorted(x for x in uniq if x not in set(want))
    dups = sorted(x for x in uniq if live.count(x) > 1)
    line = f"  {key:15} управляется {len(want):3}, в live {len(uniq):3} уникальных"
    if dups:
        drift += len(dups)
        line += f" (дублей: {len(dups)} — требует -i)"
    print(line)
    if key == 'ip_cidr' and unresolved:
        print(f"  {'':15} MySQL-хосты не резолвятся: {', '.join(unresolved)}"
              " — ip_cidr проверен не полностью")
    if missing:
        drift += len(missing)
        print(f"  {key:15} ОТСУТСТВУЮТ ({len(missing)}): {', '.join(sorted(missing))}")
    if extra:
        shown = ', '.join(extra[:10])
        more = f" и ещё {len(extra) - 10}" if len(extra) > 10 else ""
        print(f"  {'':15} лишние ({len(extra)}, личные правки — норма): {shown}{more}")

corp = set(managed['domain']) | set(managed['domain_suffix']) | set(managed['ip_cidr'])
direct = next((g for g in groups if g.get('name') == 'На прямую'), None)
if direct is None:
    print('  "На прямую"      группы нет (норма)')
else:
    leftover = [x for k in ('domain', 'domain_suffix', 'ip_cidr')
                for x in (direct.get(k) or []) if x in corp]
    if leftover:
        drift += len(leftover)
        print(f'  "На прямую"      корп. элементов не перенесено: '
              f"{len(leftover)}: {', '.join(sorted(leftover)[:10])}")
    else:
        print('  "На прямую"      корп. элементов не осталось')

try:
    with open(subscribe_path, encoding='utf-8') as f:
        sub = json.load(f)
    div = next((e for e in sub.get('diversion_group', [])
                if e.get('diversion_name') == 'ts-network'), None)
    if div and div.get('server_name') == 'direct_out':
        print("  diversion_group  ts-network -> direct_out: ок")
    else:
        drift += 1
        got = div.get('server_name') if div else 'нет записи'
        print(f"  diversion_group  ts-network -> НЕ direct_out ({got})")
except Exception as ex:
    print(f"  diversion_group  не прочитан: {ex}")

# --- DNS static_ips: RDP-хосты не должны резолвиться в fake-IP ---
wanted = {}
for item in rdp_static_raw.split():
    if '=' in item:
        host, ip = item.split('=', 1)
        if host and ip:
            wanted.setdefault(host, [])
            if ip not in wanted[host]:
                wanted[host].append(ip)
try:
    with open(settings_path, encoding='utf-8') as f:
        settings = json.load(f)
except Exception as ex:
    settings = None
    drift += 1
    print(f"  DNS static_ips  не прочитан {settings_path}: {ex}")
if settings is not None:
    dns = settings.get('dns', {})
    static = dns.get('static_ips', {})
    if not dns.get('enable_static_ip'):
        drift += 1
        print('  DNS static_ips  ОТКЛЮЧЕНЫ (enable_static_ip=false)')
    stale = [h for h in rdp_drop if h in static]
    miss = [f'{h}={ip}' for h, ips in wanted.items()
            for ip in ips if ip not in static.get(h, [])]
    if miss:
        drift += len(miss)
        print(f'  DNS static_ips  ОТСУТСТВУЮТ ({len(miss)}): '
              f"{', '.join(sorted(miss))}")
    if stale:
        drift += len(stale)
        print(f'  DNS static_ips  УСТАРЕВШИЕ ({len(stale)}): '
              f"{', '.join(sorted(stale))}")
    if not miss and not stale:
        print(f'  DNS static_ips  ок ({len(wanted)} хостов RDP, '
              f'всего записей {len(static)})')

print()
if drift:
    print(f"ДРЕЙФ: {drift} расхождений — применить: {self_name} -i "
          "(при выключенном Karing)")
    sys.exit(1)
print("Дрейфа нет: live-конфиг совпадает с corp-networks.conf")
PY
}

selftest() {
  # Проверка генератора и сверки дрейфа на фикстурах. Живой конфиг Karing
  # не читается и не меняется: подменяются HOME и CORP_NETWORKS_CONF.
  local pass=0 fail=0 tmp home conf kg
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  ck() {  # ck <имя> <ожидаемое> <фактическое>
    if [ "$2" = "$3" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      printf '  FAIL %s\n       ожидалось: %s\n       получено: %s\n' \
        "$1" "$2" "$3"
    fi
  }

  # --- to_json_array ---
  ck "to_json_array: пусто" "" "$(to_json_array '')"
  ck "to_json_array: один" '"a.ru"' "$(to_json_array 'a.ru')"
  ck "to_json_array: список" '"a.ru", "b.ru"' "$(to_json_array 'a.ru b.ru')"
  ck "to_json_array: дедуп с сохранением порядка" '"a.ru", "b.ru"' \
    "$(to_json_array 'a.ru b.ru a.ru b.ru a.ru')"
  ck "to_json_array: дедуп не теряет разные значения" '"a.ru", "b.ru", "c.ru"' \
    "$(to_json_array 'a.ru b.ru a.ru c.ru b.ru')"

  # --- фикстура конфига и live-конфига ---
  conf="$tmp/net.conf"
  cat > "$conf" <<'CONF'
SITE_DOMAINS="a.ru b.ru"
MYSQL_HOSTS=""
DOMAINS="m.ru"
DOMAIN_SUFFIX=".tradesoft.ru"
NET_ROUTES="192.168.0.0/16"
VPN_SERVERS="203.0.113.7"
RDP_STATIC_IPS="rdp.corp=192.0.2.10"
RDP_STATIC_IPS_DROP="old.rdp"
CONF
  printf '# пустой auto-конфиг (комменты игнорируются)\n' > "$tmp/auto-empty"
  printf 'auto-learn.ru\n' > "$tmp/auto-one"
  home="$tmp/home"
  kg="$home/Library/Group Containers/group.com.nebula.karing"
  mkdir -p "$kg"

  # live-конфиг, полностью совпадающий с conf
  python3 - "$kg/karing_routing_group.json" <<'PY'
import json, sys, os
doc = {
  "items": [{
    "groupid": "custom", "urlOrPath": "", "remark": "Самостоятельная настройка",
    "editAble": True,
    "groups": [
      {"groupid": "custom", "name": "ts-network", "type": "", "or": True,
       "domain": ["a.ru", "b.ru", "m.ru"],
       "domain_suffix": [".tradesoft.ru"],
       "ip_cidr": ["192.168.0.0/16", "203.0.113.7"]},
      {"groupid": "custom", "name": "На прямую", "type": "", "or": True,
       "domain": [".yandex.ru"]}
    ]
  }],
  "rule_set_items": []
}
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)
with open(sys.argv[1].replace('routing_group', 'subscribe_use'), 'w',
          encoding='utf-8') as f:
    json.dump({"diversion_group": [
        {"diversion_groupid": "custom", "diversion_name": "ts-network",
         "server_groupid": "direct", "server_name": "direct_out",
         "dns_servers": []}]}, f, ensure_ascii=False, indent=2)

settings = {
    "dns": {
        "enable_static_ip": True,
        "proxy_resolve_mode": "fakeip",
        "static_ips": {"rdp.corp": ["192.0.2.10"],
                       "personal.example": ["192.0.2.99"]},
    },
    "perapp": {"enable": False},
}
with open(os.path.join(os.path.dirname(sys.argv[1]), 'karing_setting.json'), 'w',
          encoding='utf-8') as f:
    json.dump(settings, f, ensure_ascii=False, indent=2)
PY

  out="$(HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-empty" "$DIR/karing-rules.sh" --check 2>&1)"
  ck "check: без дрейфа, код 0" "0" "$?"
  ck "check: без дрейфа, нет расхождений" "0" \
    "$(printf '%s' "$out" | grep -c '^ДРЕЙФ')"
  ck "check: чистая группа, дубли не отмечены" "0" \
    "$(printf '%s' "$out" | grep -c 'дублей')"

  # --- DNS static_ips для RDP (fake-IP рвёт сессию при рестарте Karing) ---
  ck "check: DNS static_ips ок" "1" \
    "$(printf '%s' "$out" | grep -c 'DNS static_ips  ок')"

  python3 - "$kg/karing_setting.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding='utf-8'))
d['dns']['static_ips'].pop('rdp.corp', None)
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
  out="$(HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-empty" "$DIR/karing-rules.sh" --check 2>&1)"
  ck "check: DNS static_ips отсутствует" "1" \
    "$(printf '%s' "$out" | grep -c 'DNS static_ips  ОТСУТСТВУЮТ (1): rdp\.corp=192\.0\.2\.10')"

  HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-empty" \
    "$DIR/karing-rules.sh" -i >/dev/null 2>&1
  ck "apply: код 0" "0" "$?"
  python3 - "$kg/karing_setting.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
s = d['dns']
assert s['enable_static_ip'] is True
assert s['static_ips'].get('rdp.corp') == ['192.0.2.10']
assert '192.0.2.99' in s['static_ips'].get('personal.example', []), 'личные записи потеряны'
print('ok')
PY
  ck "apply: static_ips восстановлены, личные записи целы" "0" "$?"

  python3 - "$kg/karing_setting.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding='utf-8'))
d['dns']['enable_static_ip'] = False
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
  out="$(HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-empty" "$DIR/karing-rules.sh" --check 2>&1)"
  ck "check: DNS static_ips отключены" "1" \
    "$(printf '%s' "$out" | grep -c 'DNS static_ips  ОТКЛЮЧЕНЫ')"

  python3 - "$kg/karing_setting.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding='utf-8'))
d['dns']['enable_static_ip'] = True
d['dns']['static_ips']['rdp.corp'] = ['198.20.0.5']  # fake-IP вместо реального
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
  out="$(HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-empty" "$DIR/karing-rules.sh" --check 2>&1)"
  ck "check: DNS static_ips с fake-IP" "1" \
    "$(printf '%s' "$out" | grep -c 'DNS static_ips  ОТСУТСТВУЮТ (1): rdp\.corp=192\.0\.2\.10')"

  HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-empty" \
    "$DIR/karing-rules.sh" -i >/dev/null 2>&1
  python3 - "$kg/karing_setting.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert d['dns']['static_ips']['rdp.corp'] == ['192.0.2.10'], 'fake-IP не убран'
print('ok')
PY
  ck "apply: fake-IP убран из static_ips" "0" "$?"

  python3 - "$kg/karing_setting.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding='utf-8'))
d['dns']['static_ips']['old.rdp'] = ['192.0.2.77']
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
  out="$(HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-empty" "$DIR/karing-rules.sh" --check 2>&1)"
  ck "check: устаревший RDP-хост замечен" "1" \
    "$(printf '%s' "$out" | grep -c 'DNS static_ips  УСТАРЕВШИЕ (1): old\.rdp')"
  HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-empty" \
    "$DIR/karing-rules.sh" -i >/dev/null 2>&1
  python3 - "$kg/karing_setting.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert 'old.rdp' not in d['dns']['static_ips'], 'устаревший хост не удалён'
print('ok')
PY
  ck "apply: устаревший RDP-хост удалён" "0" "$?"

  # --- auto-конфиг learn-находок входит в управляемый список ---
  # (выполняется на чистом live, до мутаций ниже).
  out="$(HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-one" "$DIR/karing-rules.sh" --check 2>&1)"
  ck "check: auto-домен вне live, код 1" "1" "$?"
  ck "check: назван отсутствующий auto-домен" "1" \
    "$(printf '%s' "$out" | grep -c '^  domain .*ОТСУТСТВУЮТ (1): auto-learn\.ru')"
  HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-one" \
    "$DIR/karing-rules.sh" \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert "auto-learn.ru" in d.get("domain",[]), "auto-домена нет в ts-network"
print("ok")' \
    >/dev/null 2>&1
  ck "group_json: auto-домен попадает в ts-network" "0" "$?"

  # корп. домен, оставшийся в «На прямую», — дрейф
  python3 - "$kg/karing_routing_group.json" <<'PY'
import json, sys
p = sys.argv[1]
doc = json.load(open(p, encoding='utf-8'))
for g in doc['items'][0]['groups']:
    if g['name'] == 'На прямую':
        g['domain'] = [".yandex.ru", "a.ru"]
json.dump(doc, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
  out="$(HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-empty" "$DIR/karing-rules.sh" --check 2>&1)"
  ck "check: остаток в «На прямую», код 1" "1" "$?"
  ck "check: назван унесённый домен" "1" \
    "$(printf '%s' "$out" | grep -c 'корп. элементов не перенесено.*a\.ru')"

  # подменяем «На прямую» на чистую и убираем домен из ts-network
  python3 - "$kg/karing_routing_group.json" <<'PY'
import json, sys
p = sys.argv[1]
doc = json.load(open(p, encoding='utf-8'))
groups = doc['items'][0]['groups']
for g in groups:
    if g['name'] == 'ts-network':
        g['domain'] = ["a.ru", "m.ru", "a.ru"]   # пропущен b.ru + дубль
    if g['name'] == 'На прямую':
        g['domain'] = [".yandex.ru"]
json.dump(doc, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY

  out="$(HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-empty" "$DIR/karing-rules.sh" --check 2>&1)"
  ck "check: дрейф, код 1" "1" "$?"
  ck "check: назван отсутствующий домен" "1" \
    "$(printf '%s' "$out" | grep -c 'ОТСУТСТВУЮТ (1): b\.ru')"
  ck "check: дубль замечен" "1" \
    "$(printf '%s' "$out" | grep -c 'дублей: 1')"

  # неверный outbound в diversion_group
  python3 - "$kg/karing_subscribe_use.json" <<'PY'
import json, sys
p = sys.argv[1]
doc = json.load(open(p, encoding='utf-8'))
doc['diversion_group'][0]['server_name'] = 'proxy'
json.dump(doc, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
  HOME="$home" CORP_NETWORKS_CONF="$conf" CORP_NETWORKS_AUTO="$tmp/auto-empty" "$DIR/karing-rules.sh" --check >/dev/null 2>&1
  ck "check: неверный outbound, код 1" "1" "$?"

  # --- генераторы отдают валидный JSON на боевом conf ---
  real_conf="$DIR/corp-networks.conf"
  if [ -f "$real_conf" ]; then
    CORP_NETWORKS_CONF="$real_conf" "$DIR/karing-rules.sh" \
      | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["name"]=="ts-network" and d.get("domain")
for k in ("domain","domain_suffix","ip_cidr"):
    v=d.get(k,[])
    assert len(v)==len(set(v)), k+" содержит дубли"
print("ok")' \
      >/dev/null 2>&1
    ck "group_json: валидный JSON ts-network без дублей" "0" "$?"
    CORP_NETWORKS_CONF="$real_conf" "$DIR/karing-rules.sh" --singbox \
      | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["outbound"]=="direct_out" and d.get("rules")
for r in d["rules"]:
    for k,v in r.items():
        assert len(v)==len(set(v)), k+" содержит дубли"
print("ok")' \
      >/dev/null 2>&1
    ck "singbox: валидный JSON direct_out без дублей" "0" "$?"
    CORP_NETWORKS_CONF="$real_conf" "$DIR/karing-rules.sh" --dns \
      | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["enable_static_ip"] is True
assert d["drop"] == ["testing26.tradesoft.corp"]
assert d.get("static_ips") and all(isinstance(v,list) for v in d["static_ips"].values())
print("ok")' \
      >/dev/null 2>&1
    ck "dns: валидный JSON static_ips для RDP-хостов" "0" "$?"
  fi

  printf 'selftest: %d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  -i|--apply)  apply ;;
  --check)     check ;;
  --selftest)  selftest ;;
  --singbox)   singbox_rule ;;
  --dns)       static_ips_json ;;
  *)           group_json ;;
esac
