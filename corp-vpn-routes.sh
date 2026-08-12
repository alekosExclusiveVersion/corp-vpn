#!/bin/sh

# Единый источник корпоративных сетей — /usr/local/etc/corp-networks.conf.
# При отсутствии файла используем встроенные значения по умолчанию.
CONF=/usr/local/etc/corp-networks.conf
CORP_SERVICES="vpn2-ts vpn3-ts vpn4"
NET_ROUTES="10.0.0.0/8 192.168.0.0/16"
MYSQL_HOSTS="p7ru1.tradesoft.ru p7ru2.tradesoft.ru p7ru3.tradesoft.ru p7ru4.tradesoft.ru p7ru5.tradesoft.ru p7ru8.tradesoft.ru p5g21.tradesoft.ru p5g25.tradesoft.ru p5g29.tradesoft.ru ext4.tradesoft.ru"
SITE_DOMAINS="www.amry.ru"
PROBE_HOSTS="sup5.tradesoft.corp:4000 projects.prj:80 servicedesk-report.office.tradesoft.ru:443"
if [ -f "$CONF" ]; then
  . "$CONF"
fi
STATE=/var/run/corp-vpn-routes.state

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
      esac
      [ -n "$line" ] || continue
      if route_via_ppp "$line"; then
        route -n delete -host "$line" >/dev/null 2>&1
      fi
    done < "$STATE"
  fi
  rm -f "$STATE"
  for r in $NET_ROUTES; do
    case "$r" in
      */*) probe="${r%/*}.1" ;;
      *)   probe="$r" ;;
    esac
    if route_via_ppp "$probe"; then
      route -n delete -net "$r" >/dev/null 2>&1
    fi
  done
}

add_routes() {
  iface="$1"
  for r in $NET_ROUTES; do
    route -n add -net "$r" -interface "$iface" >/dev/null 2>&1
  done
  : > "$STATE"
  for h in $MYSQL_HOSTS; do
    for ip in $(host_ip "$h"); do
      route -n add -host "$ip" -interface "$iface" >/dev/null 2>&1
      echo "$ip" >> "$STATE"
    done
  done
  for h in $SITE_DOMAINS; do
    for ip in $(host_ip "$h"); do
      route -n add -host "$ip" -interface "$iface" >/dev/null 2>&1
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
}

last_iface=""
last_resolve=0
fail=0
dead_until=0
last_probe=0
while true; do
  now=$(date +%s)
  iface=$(find_iface)

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

  if [ -n "$iface" ]; then
    if [ "$iface" != "$last_iface" ] || [ $((now - last_resolve)) -ge 300 ]; then
      del_routes
      add_routes "$iface"
      last_iface="$iface"
      last_resolve=$now
      fail=0
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
