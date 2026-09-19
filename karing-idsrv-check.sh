#!/usr/bin/env bash
# Проверка durable-настроек Karing для ID-сервера Ассистента (диагностика 18.09.2026, §9.9/CORP-VPN-SETUP.md).
# Должны сохраняться после полного рестарта Karing:
#   1) домены .service.ast / .xn--80akicokc0aablc.xn--p1ai в группе «🌏 GFW» (karing_routing_group.json);
#   2) perapp.enable=false (karing_setting.json).
# Использование: bash karing-idsrv-check.sh  (без аргументов, read-only)
set -u

GC=~/Library/Group\ Containers/group.com.nebula.karing
RC="karing_routing_group.json  не найден (Karing не запускался или другой путь)"
SC="karing_setting.json  не найден"
ok=0; fail=0

pass() { printf '  PASS  %s\n' "$1"; ok=$((ok+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo '== 1) karing_routing_group.json: группа «🌏 GFW» содержит оба домена'
if [[ -f "$GC/karing_routing_group.json" ]]; then
  for d in service.ast xn--80akicokc0aablc; do
    if python3 - "$GC/karing_routing_group.json" "$d" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
txt=json.dumps(c,ensure_ascii=False)
sys.exit(0 if sys.argv[2] in txt else 1)
PY
    then pass "домен содержит '$d'"; else bad "домен '$d' отсутствует в routing_group"; fi
  done
else
  bad "$RC"; fail=$((fail+1))
fi

echo '== 2) karing_setting.json: perapp.enable=false'
if [[ -f "$GC/karing_setting.json" ]]; then
  if python3 - "$GC/karing_setting.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
sys.exit(0 if d.get('perapp',{}).get('enable') is False else 1)
PY
  then pass "perapp.enable=false"; else bad "perapp.enable != false (снова включён?)"; fi
else
  bad "$SC"; fail=$((fail+1))
fi

echo '== 3) service_core.json: правило «GFW» ведёт ID-домены в нод'
if [[ -f "$GC/service_core.json" ]]; then
  python3 - "$GC/service_core.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))

def domains(node, acc):
    if isinstance(node, dict):
        d=node.get('domain_suffix') or node.get('domain') or []
        acc.update(x for x in d if x)
        for v in node.values(): domains(v, acc)
    elif isinstance(node, list):
        for v in node: domains(v, acc)

found=False
for i,r in enumerate(c.get('route',{}).get('rules',[])):
    acc=set(); domains(r, acc)
    if any('service.ast' in x or '80akicok' in x for x in acc):
        print(f"  INFO  правило R{i}: outbound={r.get('outbound')} (именовано: {r.get('name','')})")
        found=True
if not found:
    print("  FAIL  правило с ID-доменами не найдено в route.rules")
PY
else
  echo "  WARN  service_core.json отсутствует (Karing остановлен — проверка правил невозможна)"
fi

echo '== 4) DNS через Karing (рабочий хост — публичный punycode)'
if ! command -v dig >/dev/null 2>&1 || ! dig +time=2 +tries=1 +short @10.20.0.2 id.xn--80akicokc0aablc.xn--p1ai 2>/dev/null | grep -qE '^[0-9]'; then
  echo "  WARN  DNS 10.20.0.2 не отвечает (Karing/TUN выключен? пропускаем)"
else
  ip=$(dig +time=2 +tries=1 +short @10.20.0.2 id.xn--80akicokc0aablc.xn--p1ai 2>/dev/null | grep -E '^[0-9]' | head -1)
  echo "  INFO  id.xn--80akicokc0aablc.xn--p1ai -> $ip"
  if [[ -z "$ip" ]]; then bad "публичный ID-домен не резолвится"; else pass "публичный ID-домен резолвится"; fi
fi

echo
echo "Итого: PASS=$ok FAIL=$fail"
[[ $fail -eq 0 ]]