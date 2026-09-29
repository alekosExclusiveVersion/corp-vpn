#!/bin/bash
# ==========================================================
# Генератор direct-правил для Karing из единого файла
# корпоративных сетей (corp-networks.conf).
#
# Запуск:
#   ./karing-rules.sh            # JSON-группы для вставки в Karing
#   ./karing-rules.sh --singbox  # правила в формате sing-box
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

print('OK: группа "ts-network" синхронизирована с corp-networks.conf')
print('    корп. домены/суффиксы/IP -> "ts-network" (direct_out)')
print('    личные правки остались в "На прямую"')
print('    ' + routing_path)
PY
  rm -rf "$tmpdir"
}

check() {
  # Только читает live-конфиг Karing и сверяет его с corp-networks.conf.
  # Ничего не изменяет. Код возврата: 0 — расхождений нет, 1 — есть дрейф,
  # 2 — конфиг не прочитан (пригодно как гейт в мониторинге).
  python3 - "$0" "$ROUTING_JSON" "$SUBSCRIBE_JSON" "$DOMAINS" "$SITE_DOMAINS" \
      "$MYSQL_HOSTS" "$DOMAIN_SUFFIX" "$NET_ROUTES" "$VPN_SERVERS" <<'PY'
import json, sys, os, socket, subprocess

self_name = sys.argv[1]
routing_path, subscribe_path = sys.argv[2:4]
DOMAINS, SITE_DOMAINS, MYSQL_HOSTS, DOMAIN_SUFFIX, NET_ROUTES, VPN_SERVERS = \
    (sys.argv[i].split() for i in range(4, 10))

managed = {
    'domain': DOMAINS + SITE_DOMAINS + MYSQL_HOSTS,
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
        print(f"  {'':15} ОТСУТСТВУЮТ ({len(missing)}): {', '.join(sorted(missing))}")
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
CONF
  home="$tmp/home"
  kg="$home/Library/Group Containers/group.com.nebula.karing"
  mkdir -p "$kg"

  # live-конфиг, полностью совпадающий с conf
  python3 - "$kg/karing_routing_group.json" <<'PY'
import json, sys
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
PY

  out="$(HOME="$home" CORP_NETWORKS_CONF="$conf" "$DIR/karing-rules.sh" --check 2>&1)"
  ck "check: без дрейфа, код 0" "0" "$?"
  ck "check: без дрейфа, нет расхождений" "0" \
    "$(printf '%s' "$out" | grep -c '^ДРЕЙФ')"
  ck "check: чистая группа, дубли не отмечены" "0" \
    "$(printf '%s' "$out" | grep -c 'дублей')"

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
  out="$(HOME="$home" CORP_NETWORKS_CONF="$conf" "$DIR/karing-rules.sh" --check 2>&1)"
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

  out="$(HOME="$home" CORP_NETWORKS_CONF="$conf" "$DIR/karing-rules.sh" --check 2>&1)"
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
  HOME="$home" CORP_NETWORKS_CONF="$conf" "$DIR/karing-rules.sh" --check >/dev/null 2>&1
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
  fi

  printf 'selftest: %d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  -i|--apply)  apply ;;
  --check)     check ;;
  --selftest)  selftest ;;
  --singbox)   singbox_rule ;;
  *)           group_json ;;
esac
