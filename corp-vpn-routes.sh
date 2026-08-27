#!/bin/sh

# Единый источник корпоративных сетей — /usr/local/etc/corp-networks.conf.
# При отсутствии файла используем встроенные значения по умолчанию.
# Автодетект corp-learn.sh дописывает домены в corp-networks-auto.conf
# (AUTO_SITE_DOMAINS, по одному домену на строку).
CONF=/usr/local/etc/corp-networks.conf
AUTO_CONF=/usr/local/etc/corp-networks-auto.conf
CORP_SERVICES="vpn2-ts vpn3-ts vpn4"
NET_ROUTES="10.0.0.0/8 192.168.0.0/16"
LOCAL_ROUTES=""
MYSQL_HOSTS="p7ru1.tradesoft.ru p7ru2.tradesoft.ru p7ru3.tradesoft.ru p7ru4.tradesoft.ru p7ru5.tradesoft.ru p7ru8.tradesoft.ru p5g21.tradesoft.ru p5g25.tradesoft.ru p5g29.tradesoft.ru ext4.tradesoft.ru"
SITE_DOMAINS="www.amry.ru"
PROBE_HOSTS="sup5.tradesoft.corp:4000 projects.prj:80 servicedesk-report.office.tradesoft.ru:443"
AUTO_SITE_DOMAINS=""
if [ -f "$CONF" ]; then
  . "$CONF"
fi
# Домены автодетекта (corp-learn.sh), по одному на строку в AUTO_CONF.
if [ -f "$AUTO_CONF" ]; then
  AUTO_SITE_DOMAINS=$(grep -vE '^[[:space:]]*(#|$)' "$AUTO_CONF" | tr '\n' ' ')
fi
STATE=/var/run/corp-vpn-routes.state
LOCAL_STATE=/var/run/corp-vpn-local.state

find_iface() {
  for svc in $CORP_SERVICES; do
    out=$(scutil --nc status "$svc" 2>/dev/null)
    case "$out" in
      Connected*)
        iface=$(echo "$out" | awk '/InterfaceName/{print $3; exit}')
        if [ -n "$iface" ]; then
          echo "$iface"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

host_ip() {
  dig +short +time=1 +tries=1 "$1" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

ip2int() {
  IFS=. read -r a b c d <<EOF
$1
EOF
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int2ip() {
  v=$1
  echo "$(( (v >> 24) & 255 )).$(( (v >> 16) & 255 )).$(( (v >> 8) & 255 )).$(( v & 255 ))"
}

cidr_mask() {
  cidr=$1
  val=$(( 0xFFFFFFFF << (32 - cidr) ))
  int2ip $(( val & 0xFFFFFFFF ))
}

cidr_net() {
  ip=${1%/*}
  cidr=${1#*/}
  mask=$(( 0xFFFFFFFF << (32 - cidr) ))
  int2ip $(( ( $(ip2int "$ip") ) & mask ))
}

net_of() {
  ip=$1
  mhex=${2#0x}
  mask=$(( 16#$mhex ))
  int2ip $(( ( $(ip2int "$ip") ) & mask ))
}

mask_to_cidr() {
  mhex=${1#0x}
  mask=$(( 16#$mhex ))
  bits=0
  v=$mask
  while [ "$v" -gt 0 ]; do
    bits=$(( bits + (v & 1) ))
    v=$(( v >> 1 ))
  done
  echo "$bits"
}

is_tunnel_iface() {
  case "$1" in
    ppp*|utun*|lo0|gif*|stf*|anpi*|awdl*|llw*|bridge*|ap*|vnic*) return 0 ;;
  esac
  return 1
}

is_physical_iface() {
  case "$1" in
    en*|eth*) return 0 ;;
  esac
  return 1
}

# Локальные подсети: явный LOCAL_ROUTES + подсети физических интерфейсов.
get_local_subnets() {
  for r in $LOCAL_ROUTES; do
    echo "$r"
  done
  ifconfig 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      [A-Za-z0-9]*:* ) iface=${line%%:*} ;;
    esac
    case "$line" in
      *[[:space:]]inet[[:space:]]*) ;;
      *) continue ;;
    esac
    is_tunnel_iface "$iface" && continue
    ip=$(echo "$line" | awk '{print $2}')
    mask=$(echo "$line" | awk '{print $4}')
    net=$(net_of "$ip" "$mask")
    cidr=$(mask_to_cidr "$mask")
    echo "$net/$cidr"
  done | sort -u
}

# Путь до локальной сети: "-interface en0" или "-gateway 192.168.31.1".
local_path() {
  out=$(route -n get "$1" 2>/dev/null) || return 1
  ifc=$(echo "$out" | awk '/interface:/{print $2; exit}')
  gw=$(echo "$out" | awk '/gateway:/{print $2; exit}')
  if [ -n "$ifc" ] && is_physical_iface "$ifc"; then
    echo "-interface $ifc"
    return 0
  fi
  if [ -n "$gw" ] && [ "$gw" != "default" ] && [ "$gw" != "0.0.0.0" ]; then
    if local_path_gw_physical "$gw"; then
      echo "-gateway $gw"
      return 0
    fi
  fi
  return 1
}

local_path_gw_physical() {
  out=$(route -n get "$1" 2>/dev/null) || return 1
  ifc=$(echo "$out" | awk '/interface:/{print $2; exit}')
  [ -n "$ifc" ] && is_physical_iface "$ifc"
}

# Снапшот путей до локальных сетей. Делаем ТОЛЬКО при выключенном туннеле,
# иначе route -n get вернёт ppp и мы зафиксируем неверный путь.
refresh_local_snapshot() {
  tmp="$LOCAL_STATE.tmp.$$"
  : > "$tmp"
  for r in $(get_local_subnets); do
    net=$(cidr_net "$r")
    cidr=${r#*/}
    p1=$(ip2int "$net")
    probe=$(int2ip $(( p1 + 1 )))
    path=$(local_path "$probe") || continue
    echo "local:$net:$cidr:$path" >> "$tmp"
  done
  mv "$tmp" "$LOCAL_STATE"
}

add_local_routes() {
  [ -f "$LOCAL_STATE" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      local:*)
        IFS=: read -r _tag net cidr path <<EOF
$line
EOF
        mask=$(cidr_mask "$cidr")
        if route -n add -net "$net" -netmask "$mask" $path >/dev/null 2>&1; then
          echo "local:$net:$mask:$path" >> "$STATE"
        fi
        ;;
    esac
  done < "$LOCAL_STATE"
}

tunnel_alive() {
  if [ -f "$STATE" ]; then
    while IFS= read -r line; do
      case "$line" in
        probe:*)
          hp=${line#probe:}
          if nc -z -G 3 "${hp%:*}" "${hp##*:}" >/dev/null 2>&1; then
            return 0
          fi
          ;;
      esac
    done < "$STATE"
  fi
  for hp in $PROBE_HOSTS; do
    h=${hp%:*}
    p=${hp##*:}
    if nc -z -G 3 "$h" "$p" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

route_via_ppp() {
  route -n get "$1" 2>/dev/null | grep -q 'interface: ppp'
}

del_routes() {
  if [ -f "$STATE" ]; then
    while IFS= read -r line; do
      case "$line" in
        probe:*) continue ;;
        local:*)
          IFS=: read -r _tag net mask path <<EOF
$line
EOF
          route -n delete -net "$net" -netmask "$mask" >/dev/null 2>&1
          continue
          ;;
      esac
      [ -n "$line" ] || continue
      if route_via_ppp "$line"; then
        route -n delete -host "$line" >/dev/null 2>&1
      fi
    done < "$STATE"
  fi
  rm -f "$STATE"
  for r in $NET_ROUTES; do
    probe=$(cidr_net "$r")
    p1=$(ip2int "$probe")
    probe=$(int2ip $(( p1 + 1 )))
    if route_via_ppp "$probe"; then
      route -n delete -net "$r" >/dev/null 2>&1
    fi
  done
}

# Переключает host-маршрут на корп. интерфейс, даже если его уже занял
# другой туннель (например, Karing прибивает *.tradesoft.ru к utun).
# Удаляет чужой маршрут и добавляет свой.
add_host_route() {
  ip="$1"
  if route -n add -host "$ip" -interface "$iface" >/dev/null 2>&1; then
    return 0
  fi
  if ! route_via_ppp "$ip"; then
    route -n delete -host "$ip" >/dev/null 2>&1
    route -n add -host "$ip" -interface "$iface" >/dev/null 2>&1
  fi
}

# Каждые 5с перепроверяет маршруты из STATE и возвращает на корп. интерфейс
# всё, что Karing/иные туннели успели перебить.
assert_routes() {
  # Сетевые маршруты корп. зон всегда через ppp.
  for r in $NET_ROUTES; do
    probe=$(cidr_net "$r")
    if ! route_via_ppp "$probe"; then
      route -n delete -net "$r" >/dev/null 2>&1
      route -n add -net "$r" -interface "$iface" >/dev/null 2>&1
    fi
  done
  [ -f "$STATE" ] || return 0
  while IFS= read -r ip; do
    case "$ip" in
      probe:*|local:*) continue ;;
      "") continue ;;
      \#*) continue ;;
    esac
    if ! route_via_ppp "$ip"; then
      add_host_route "$ip"
    fi
  done < "$STATE"
}

add_routes() {
  iface="$1"
  # Восстанавливаем сетевые маршруты корп. зон через ppp: удаляем чужие
  # (en0/utun/Karing), затем добавляем свои. Приоритет у ppp0.
  for r in $NET_ROUTES; do
    probe=$(cidr_net "$r")
    if ! route_via_ppp "$probe"; then
      route -n delete -net "$r" >/dev/null 2>&1
    fi
    route -n add -net "$r" -interface "$iface" >/dev/null 2>&1
  done
  : > "$STATE"
  for h in $MYSQL_HOSTS; do
    for ip in $(host_ip "$h"); do
      add_host_route "$ip"
      echo "$ip" >> "$STATE"
    done
  done
  for h in $SITE_DOMAINS $AUTO_SITE_DOMAINS; do
    for ip in $(host_ip "$h"); do
      add_host_route "$ip"
      echo "$ip" >> "$STATE"
    done
  done
  for hp in $PROBE_HOSTS; do
    h=${hp%:*}
    p=${hp##*:}
    ip=$(host_ip "$h")
    [ -n "$ip" ] || continue
    echo "probe:$ip:$p" >> "$STATE"
  done
  add_local_routes
}

# Идентификатор VPN-сессии (уникален для каждого переподключения).
# Сравнивается каждые 5с: если VPN переподключился (сменился IP ppp0 или
# service), force-флаг заставляет пересобрать маршруты, даже если имя
# интерфейса то же (ppp0).
vpn_session_id() {
  if [ -n "$iface" ]; then
    ip=$(ifconfig "$iface" 2>/dev/null | grep '^[[:space:]]*inet ' | awk '{print $2}')
    mtu=$(ifconfig "$iface" 2>/dev/null | awk '/<UP.*RUNNING/{print "up"}')
    echo "$iface:$ip"
  fi
}

last_iface=""
last_session=""
last_resolve=0
fail=0
dead_until=0
last_probe=0
last_local_snap=0
while true; do
  now=$(date +%s)
  iface=$(find_iface)
  session=$(vpn_session_id)

  # Кулдаун после ложного Connected: не доверяем configd,
  # возвращаем маршруты только когда туннель снова отвечает на пробы.
  if [ "$now" -lt "$dead_until" ]; then
    if [ $((now - last_probe)) -ge 10 ]; then
      last_probe=$now
      if tunnel_alive; then
        dead_until=0
        fail=0
      else
        iface=""
      fi
    else
      iface=""
    fi
  fi

  # Снапшот путей до локальных сетей — только при выключенном туннеле,
  # иначе route -n get вернёт ppp и зафиксируем неверный путь.
  if [ -z "$iface" ] && [ $((now - last_local_snap)) -ge 30 ]; then
    last_local_snap=$now
    refresh_local_snapshot
  fi

  if [ -n "$iface" ]; then
    # Пересобираем маршруты если: сменился интерфейс, сменился IP сессии
    # (VPN переподключился — даже если имя то же ppp0), либо прошло 300с.
    if [ "$iface" != "$last_iface" ] || [ "$session" != "$last_session" ] || [ $((now - last_resolve)) -ge 300 ]; then
      del_routes
      add_routes "$iface"
      last_iface="$iface"
      last_session="$session"
      last_resolve=$now
      fail=0
    else
      assert_routes
      # Подхват доменов автодетекта (corp-learn.sh): при изменении
      # auto-конфига пересчитываем маршруты сразу, не дожидаясь 300с.
      new_auto=$(grep -vE '^[[:space:]]*(#|$)' "$AUTO_CONF" 2>/dev/null | tr '\n' ' ')
      if [ "$new_auto" != "$AUTO_SITE_DOMAINS" ]; then
        AUTO_SITE_DOMAINS=$new_auto
        del_routes
        add_routes "$iface"
      fi
    fi
  elif [ -n "$last_iface" ] || [ -f "$STATE" ]; then
    del_routes
    last_iface=""
    fail=0
  fi

  # Проверка живости: маршруты держим, только пока корп. трафик реально проходит.
  if [ -n "$last_iface" ] && [ $((now - last_probe)) -ge 10 ]; then
    last_probe=$now
    if tunnel_alive; then
      fail=0
    else
      fail=$((fail + 1))
      if [ "$fail" -ge 2 ]; then
        del_routes
        last_iface=""
        fail=0
        dead_until=$((now + 60))
      fi
    fi
  fi

  sleep 5
done
