#!/bin/sh

# Единый источник корпоративных сетей — /usr/local/etc/corp-networks.conf.
# При отсутствии файла используем встроенные значения по умолчанию.
# Автодетект corp-learn.sh дописывает домены в corp-networks-auto.conf
# (AUTO_SITE_DOMAINS, по одному домену на строку).
CONF=/usr/local/etc/corp-networks.conf
AUTO_CONF=/usr/local/etc/corp-networks-auto.conf
CORP_SERVICES="vpn2-ts vpn3-ts vpn4-ts"
NET_ROUTES="10.0.0.0/8 192.168.0.0/16"
LOCAL_ROUTES=""
MYSQL_HOSTS="p7ru1.tradesoft.ru p7ru2.tradesoft.ru p7ru3.tradesoft.ru p7ru4.tradesoft.ru p7ru5.tradesoft.ru p7ru8.tradesoft.ru p5g21.tradesoft.ru p5g25.tradesoft.ru p5g29.tradesoft.ru ext4.tradesoft.ru"
DNS_HOSTS="192.168.0.210 192.168.0.220"
SITE_DOMAINS="www.amry.ru"
SITE_CRITICAL=""
PROBE_HOSTS="sup5.tradesoft.corp:4000 projects.prj:80 servicedesk-report.office.tradesoft.ru:443"
# Критичные корп. хосты (RDP/1С/рабочие станции), указываются IP: держим
# /32-маршрут через корп. интерфейс всегда, не дожидаясь резолва доменов.
PROTECT_HOSTS=""
AUTO_SITE_DOMAINS=""
# Хосты, разрешённые через параллельный туннель Tunnelblick (см. коммент в
# corp-networks.conf). Заполняется там же; здесь пустая по умолчанию.
PARALLEL_TUNNEL_HOSTS=""
if [ -f "$CONF" ]; then
  . "$CONF"
fi
# Домены автодетекта (corp-learn.sh), по одному на строку в AUTO_CONF.
if [ -f "$AUTO_CONF" ]; then
  AUTO_SITE_DOMAINS=$(grep -vE '^[[:space:]]*(#|$)' "$AUTO_CONF" | tr '\n' ' ')
fi
STATE=/var/run/corp-vpn-routes.state
LOCAL_STATE=/var/run/corp-vpn-local.state
SIGNALS="${CORP_SIGNALS:-/var/run/corp-vpn-signals}"
SIGNALED_VPN_STATE="${CORP_SIGNALS_VPN_STATE:-/var/run/corp-vpn-signals.vpn}"

# Сигнальная очередь для юзер-агента уведомлений (corp-notify.sh).
# Строка: ts|event|message.
signal() { echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2" >> "$SIGNALS"; }

# Диагностический лог демона: причины решений (пересборки, кулдауны, DEAD),
# действия sweep'а, периодический STATUS. Кольцевой (хранит последние DIAG_MAX
# строк); из-за размера всегда доступен в /var/log/corp-vpn-routes.diag.log.
DIAG_LOG=/var/log/corp-vpn-routes-diag.log
DIAG_MAX=3000
LOG_TAG="corp-vpn-routes"

diag() {
  ev=$1; shift
  line="$(date '+%Y-%m-%d %H:%M:%S')|$ev|iface=${iface:-none}|session=${last_session:-none}|$*"
  if [ -f "$DIAG_LOG" ] || touch "$DIAG_LOG" 2>/dev/null; then
    echo "$line" >> "$DIAG_LOG"
    if [ "$(wc -l < "$DIAG_LOG" 2>/dev/null || echo 0)" -gt "$DIAG_MAX" ]; then
      tail -n "$DIAG_MAX" "$DIAG_LOG" > "$DIAG_LOG.tmp" 2>/dev/null && mv "$DIAG_LOG.tmp" "$DIAG_LOG" 2>/dev/null
    fi
  fi
  logger -t "$LOG_TAG" "$ev $*"
}

# Сигнал смены состояния корп. VPN: только при реальном переходе up<->down
# (не при переподключении в рамках сессии и не при ложном Connected).
signal_vpn_transition() {
  state=$1
  if [ "$(cat "$SIGNALED_VPN_STATE" 2>/dev/null)" != "$state" ]; then
    echo "$state" > "$SIGNALED_VPN_STATE"
    case "$state" in
      up)   signal "vpn.up"   "корп VPN активен ($iface)" ;;
      down) signal "vpn.down" "корп VPN отключился" ;;
    esac
  fi
}

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
  # Резолвим корп. домены, отбрасывая fake-IP пулы Karing (198.18.0.0/15,
  # 198.20.0.0/15 = 198.18-19.x, 198.20-21.x). Если DNS перехвачен Karing
  # (fake-IP), такие адреса попадали в STATE и протаскивались host-маршрутами
  # через ppp0 — мёртвые (не через utun). Проверено 09.09.2026.
  #
  # При активном туннеле (iface=ppp0) сначала опрашиваем корп. DNS напрямую с
  # источника ppp (dig -b): такой запрос уходит через ppp0 и НЕ перехватывается
  # Karing fake-IP, поэтому для доменов вида parts-opt.com получаем реальный IP
  # и вешаем правильный /32 через ppp. Системный dig — только резерв.
  pc_ips="$(corp_resolve "$1")"
  { [ -n "$pc_ips" ] && printf '%s\n' "$pc_ips"; dig +short +time=2 +tries=1 "$1" A 2>/dev/null; } |
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' |
    while read -r ip; do
      case "$ip" in
        198.1[89].*|198.2[01].*) continue ;;
      esac
      printf '%s\n' "$ip"
    done
}

# Резолв через корп. DNS (DNS_HOSTS), исходящий адрес = адрес корп. интерфейса.
# Работает только при поднятом туннеле и возвращает пустое значение иначе.
corp_resolve() {
  local src dns out
  [ -n "$iface" ] || return 1
  src=$(ifconfig "$iface" 2>/dev/null | awk '/^[[:space:]]*inet /{print $2; exit}')
  [ -n "$src" ] || return 1
  for dns in $DNS_HOSTS; do
    out=$(dig -b "$src" +short +time=2 +tries=1 "@$dns" "$1" A 2>/dev/null)
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
  done
  return 1
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

# Подсети адресов самих utun-туннелей. Нужны, чтобы не считать on-link адрес
# TUN чужим перехватом: Karing держит TUN в 10.20.0.1/30, а этот адрес попадает
# в NET_ROUTES 10/8 и без фильтра демон сносит его маршрут (см. sweep_corp_hijacks).
# ВАЖНО fail-open: наружу отдаём ТОЛЬКО валидные CIDR. Если разбор не удался —
# пустой список, in_any_subnet ничего не исключит и поведение останется прежним.
# При мусоре в списке in_any_subnet начал бы подтверждать всё подряд и фильтр
# отключил бы sweep целиком, поэтому валидация тут обязательна.
get_tunnel_subnets() {
  ifconfig 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      [A-Za-z0-9]*:* ) iface=${line%%:*} ;;
    esac
    case "$line" in
      *[[:space:]]inet[[:space:]]*) ;;
      *) continue ;;
    esac
    case "$iface" in
      utun*) ;;
      *) continue ;;
    esac
    # У POINTOPOINT-интерфейсов (utun/ppp) формат "inet A --> B netmask 0x..",
    # поэтому маску берём по имени, а не по позиции.
    ip=$(echo "$line" | awk '{print $2}')
    mask=$(echo "$line" | awk '{for (i = 1; i <= NF; i++) if ($i == "netmask") { print $(i + 1); exit }}')
    echo "$ip $mask"
  done | while read -r ip mask; do
    case "$ip" in
      *[!0-9.]*|'') continue ;;
    esac
    case "$mask" in
      0x*) ;;
      *) continue ;;
    esac
    echo "$(net_of "$ip" "$mask")/$(mask_to_cidr "$mask")"
  done | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {print}' | sort -u
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

# Живость корп. пути. Пробы по возрастанию надёжности:
#  1) ICMP из-под ppp0 (src = IP туннеля) до корп. DNS со /32, уже
#     пинованными через ppp — проходит даже если Karing перебил остальные
#     маршруты/резолв; раньше именно такие ложные DEAD роняли туннель;
#  2) TCP до IP из probe-записей STATE (пинованы через ppp);
#  3) TCP до IP PROBE_HOSTS, резолв через корп. DNS (fallback).
tunnel_alive() {
  if [ -n "$iface" ]; then
    srvip=$(ifconfig "$iface" 2>/dev/null | awk '/^[[:space:]]*inet /{print $2; exit}')
    if [ -n "$srvip" ]; then
      for h in $DNS_HOSTS; do
        if ping -c 1 -t 2 -S "$srvip" "$h" >/dev/null 2>&1; then
          return 0
        fi
      done
    fi
  fi
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
    h=${hp%:*}; p=${hp##*:}
    for ip in $(host_ip "$h" 2>/dev/null); do
      [ -n "$ip" ] || continue
      if nc -z -G 3 "$ip" "$p" >/dev/null 2>&1; then
        return 0
      fi
    done
  done
  return 1
}

# Троттлинг логов живости: пишем только при смене alive<->dead, чтобы не
# заливать лог каждые 10с.
report_alive() {
  if [ "$1" = yes ] && [ "$_prev_alive" != yes ]; then
    diag ALIVE "corp path restored (icmp/tcp probe ok)"
  elif [ "$1" = no ] && [ "$_prev_alive" != no ]; then
    diag DEAD "all corp probes failed"
  fi
  _prev_alive=$1
}

route_via_ppp() {
  route -n get "$1" 2>/dev/null | grep -q 'interface: ppp'
}

# Проверка IP внутри CIDR-подсети.
# Некорректный вход = "не подходит" (return 1), а не "подходит": иначе мусор в
# списке подсетей (например пустой cidr) дал бы mask=0 и in_subnet подтвердил
# бы ЛЮБОЙ адрес — фильтр исключил бы все маршруты и отключил sweep.
in_subnet() {
  ip=$1; cidr=$2
  case "$ip" in
    *[!0-9.]*|'') return 1 ;;
  esac
  case "$cidr" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*/*) ;;
    *) return 1 ;;
  esac
  case "${cidr#*/}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${cidr#*/}" -le 32 ] || return 1
  mask=$(cidr_mask "${cidr#*/}")
  net=$(cidr_net "$cidr")
  [ $(( $(ip2int "$ip") & $(ip2int "$mask") )) -eq $(( $(ip2int "$net") & $(ip2int "$mask") )) ]
}

in_any_subnet() {
  ip=$1; space=$2
  [ -n "$space" ] || return 1
  for c in $space; do
    in_subnet "$ip" "$c" && return 0
  done
  return 1
}

# Удаляет хост-маршруты (/32), которые сторонние туннели (Karing, utun)
# привязали к utun. Цель — корп. адреса: либо внутри NET_ROUTES, либо
# закреплённые за корп. интерфейсом IP из STATE (в т.ч. публичные адреса
# корп. доменов вроде partpro.ru — их Karing тоже перебивает). Удаляем чужой
# utun-/32 — далее assert_routes/add_routes вернут нужный /32 через ppp
# (или en0 при прямом подключении). IP из LOCAL_ROUTES и PARALLEL_TUNNEL_HOSTS
# не трогаем.
# TODO(perf, не срочно): фильтр подсетей в sweep — самая дорогая часть цикла.
# Измерено 28.09.2026 на 36 маршрутах utun: ~0.87 с форков на итерацию, цикл
# каждые 5 с, т.е. ~10 000 fork'ов в минуту на одни только сравнения. Причина —
# in_subnet на каждый CIDR делает cidr_mask, cidr_net и ip2int, а они все
# реализованы через $(...) / $(( $(...) )), то есть каждый форкает. Нулевая
# цена варианта: один раз за итерацию перевести $LOCAL_ROUTES/$tun_nets/$NET_ROUTES
# в целочисленные диапазоны (start,end) и сравнивать чистым арифметическим
# шеллом без подобрёвываний. Проверяется существующим selftest (кейсы sweep).
sweep_corp_hijacks() {
  rem=""
  # Плоские IP из STATE (corp-хосты, распиненные через корп. интерфейс).
  # При VPN up STATE содержит эти строки; см. add_routes.
  state_ips=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$STATE" 2>/dev/null | tr '\n' ' ')
  tun_nets=$(get_tunnel_subnets)
  for dest in $(netstat -rn -f inet 2>/dev/null |
                awk '$1!~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\// &&
                     $1~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ &&
                     $NF~/^utun/ {print $1}'); do
    in_any_subnet "$dest" "$LOCAL_ROUTES" && continue
    # On-link адреса самих utun-туннелей (у Karing TUN 10.20.0.1/30, он же
    # входит в NET_ROUTES 10/8) — это не корп. хосты, их сносить нельзя.
    in_any_subnet "$dest" "$tun_nets" && continue
    # Хосты, разрешённые через параллельный туннель Tunnelblick (см.
    # PARALLEL_TUNNEL_HOSTS в corp-networks.conf): их /32 через utun НЕ трогаем.
    case " $PARALLEL_TUNNEL_HOSTS " in
      *" $dest "*) continue ;;
    esac
    in_corp=0
    in_any_subnet "$dest" "$NET_ROUTES" && in_corp=1
    case " $state_ips " in
      *" $dest "*) in_corp=1 ;;
    esac
    [ "$in_corp" -eq 1 ] || continue
    if route -n delete -host "$dest" >/dev/null 2>&1; then
      rem="$rem $dest"
    fi
  done
  [ -n "$rem" ] && diag SWEEP "removed_utun32:$rem"
}

del_routes() {
  reason=${1:-manual}
  diag ROUTES_DEL "reason=$reason"
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
  # Маршрут уже стоит через корп. интерфейс? Тогда "чинить" нечего.
  # НЕЛЬЗЯ возвращать 0: демон посчитает это успешным ремонтом и заспамит
  # ASSERT "repaired" всем STATE каждые 5с (EEXIST -> ложный успех if).
  if route_via_ppp "$ip"; then
    return 1
  fi
  if route -n add -host "$ip" -interface "$iface" >/dev/null 2>&1; then
    return 0
  fi
  # Ни через ppp, ни напрямую нет — переустанавливаем: удаляем чужой /32
  # (утен-пин Karing/иных) и закрепляем свой.
  route -n delete -host "$ip" >/dev/null 2>&1
  route -n add -host "$ip" -interface "$iface" >/dev/null 2>&1
  return $?
}

# Каждые 5с перепроверяет маршруты из STATE и возвращает на корп. интерфейс
# всё, что Karing/иные туннели успели перебить. Плюс sweep: вычищает свежие
# чужые utun-пины корп. /32 (Karing их ставит каждые ~секунды).
#
# Эффективность: один снапшот таблицы (netstat) вместо route -n get на каждый
# из ~600 хостов STATE (в старом варианте цикл делал ~600 fork'ов каждые 5с).
assert_routes() {
  sweep_corp_hijacks
  fixed=""
  ppp_hosts=$(netstat -rn -f inet 2>/dev/null |
              awk '$NF=="ppp0" && $1~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1}' | sort -u)
  for r in $NET_ROUTES; do
    probe=$(cidr_net "$r")
    if ! route_via_ppp "$probe"; then
      route -n delete -net "$r" >/dev/null 2>&1
      if route -n add -net "$r" -interface "$iface" >/dev/null 2>&1; then
        fixed="$fixed net:$r"
      fi
    fi
  done
  [ -f "$STATE" ] || { [ -n "$fixed" ] && diag ASSERT "repaired:$fixed"; return 0; }
  while IFS= read -r ip; do
    case "$ip" in
      ""|\#*|*:* ) continue ;;
      *[!0-9.]* ) continue ;;
    esac
    case " $ppp_hosts " in
      *" $ip "*) continue ;;
    esac
    if add_host_route "$ip"; then
      fixed="$fixed $ip"
    fi
  done < "$STATE"
  [ -n "$fixed" ] && diag ASSERT "repaired:$fixed"
}

add_routes() {
  iface="$1"
  diag ROUTES_ADD "iface=$iface"
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
  # Корп. DNS-серверы строго через ppp ПЕРВЫМИ: закрепляем их раньше, чем
  # начнём резолвить домены (MYSQL_SITE). Иначе при первом цикле после подъёма
  # туннеля host_ip()/corp_resolve() не имеет маршрута через ppp до DNS и запрос
  # уходит через Karing (fake-IP), а не в корп. DNS.
  for ip in $DNS_HOSTS; do
    add_host_route "$ip"
    echo "$ip" >> "$STATE"
  done
  # Критичные корп. хосты (RDP/1С/рабочие станции) — /32 сразу через ppp,
  # не зависят от резолва и прокидываются до длинной пересборки доменов.
  for ip in $PROTECT_HOSTS; do
    add_host_route "$ip"
    echo "$ip" >> "$STATE"
  done
  # Критичные бизнес-домены (в т.ч. админка parts-opt.com) — сразу после DNS.
  # Их /32 должен быть пинован с первой секунды пересборки: иначе длинный
  # последовательный резолв SITE_DOMAINS (~288 доменов, 40+с) держит админку
  # без маршрута через ppp и трафик уходит на Karing.
  for h in $SITE_CRITICAL; do
    for ip in $(host_ip "$h"); do
      add_host_route "$ip"
      echo "$ip" >> "$STATE"
    done
  done
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
    ip=$(host_ip "$h" 2>/dev/null | head -1)
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
last_diag=0
_prev_alive=""

# --- selftest: регрессия чистых функций (без root, без сети, без правок) -------
# Заглушки затеняют одноимённые команды (вызовы в скрипте без абсолютных путей),
# поэтому исполняется настоящий код на подставленных данных, а не копия логики.
selftest() {
  local self_path=$1
  local st_pass=0 st_fail=0 st_tmp st_out st_i st_n st_s st_e
  st_tmp=$(mktemp -d 2>/dev/null) || st_tmp="/tmp/corp-vpn-selftest.$$"
  mkdir -p "$st_tmp" 2>/dev/null

  t() { # t <описание> <0=ok/иное=fail>
    if [ "$2" = "0" ]; then
      printf '[PASS] %s\n' "$1"; st_pass=$((st_pass + 1))
    else
      printf '[FAIL] %s\n' "$1"; st_fail=$((st_fail + 1))
    fi
  }
  teq() { # teq <описание> <ожидаемое> <фактическое>
    if [ "$2" = "$3" ]; then t "$1" 0
    else t "$1 — ожидалось [$2], получено [$3]" 1; fi
  }

  logger() { return 0; }
  route()  { return 0; } # снос считаем успешным; реальную таблицу не трогаем
  ifconfig() {
    if [ -n "$1" ]; then
      printf '%s\n' "$ST_IF_ALL" | awk -v want="$1" '
        /^[A-Za-z0-9]+:/ { cur=$1; sub(/:$/,"",cur); next }
        cur==want { print }'
    else
      printf '%s\n' "$ST_IF_ALL"
    fi
  }
  netstat() { printf '%s\n' "$ST_NETSTAT"; }

  ST_IF_ALL=""
  ST_NETSTAT=""

  # --- фикстуры ---
  # POINTOPOINT-интерфейсы: маска берётся по имени ("netmask 0x.."), а не по
  # позиции. Именно этот формат ломал get_tunnel_subnets при разборе маски как $4.
  ST_IF_FULL="utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
	inet 10.20.0.1 --> 10.20.0.2 netmask 0xfffffffc
	inet6 fe80::1%utun7 prefixlen 64 secured scopeid 0x7
utun8: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
	inet 10.30.5.9 netmask 0xffffff00
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	ether 3e:e9:15:74:f3:be
	inet 10.34.174.97 netmask 0xffffff00 broadcast 10.34.174.255
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000"
  # Тот же набор без единого utun — для проверки fail-open.
  ST_IF_NOTUN="en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	ether 3e:e9:15:74:f3:be
	inet 10.34.174.97 netmask 0xffffff00 broadcast 10.34.174.255
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000"
  ST_NETSTAT="10.20.0.1          10.20.0.2         UH          utun7
10.20.0.2          link#7            UH          utun7
192.168.128.5      192.168.128.1     UHS         utun7
192.168.0.77       192.168.128.55    UHS         utun7
8.8.8.8            link#7            UHS         utun7
192.168.0.33       192.168.128.55    UHS         utun7
192.168.0.232      192.168.128.55    UHS         utun7
203.0.113.9        192.168.128.55    UHS         utun7"
  LOCAL_ROUTES="192.168.128.0/24 10.34.0.0/16"
  NET_ROUTES="10.0.0.0/8 192.168.0.0/16"
  PARALLEL_TUNNEL_HOSTS="192.168.0.77"

  # 1. синтаксис
  sh -n "$self_path" 2>/dev/null; t "syntax: sh -n" "$?"

  # 2. арифметика адресов
  teq "ip2int/int2ip round-trip" "10.20.0.1" "$(int2ip "$(ip2int 10.20.0.1)")"
  teq "ip2int 192.168.0.33" "$(((192 << 24) + (168 << 16) + 33))" "$(ip2int 192.168.0.33)"
  teq "cidr_mask 30" "255.255.255.252" "$(cidr_mask 30)"
  teq "cidr_mask 24" "255.255.255.0" "$(cidr_mask 24)"
  teq "cidr_mask 16" "255.255.0.0" "$(cidr_mask 16)"
  teq "cidr_net 10.20.0.1/30" "10.20.0.0" "$(cidr_net 10.20.0.1/30)"
  teq "cidr_net 192.168.0.33/16" "192.168.0.0" "$(cidr_net 192.168.0.33/16)"
  teq "net_of 10.34.174.97 0xffffff00" "10.34.174.0" "$(net_of 10.34.174.97 0xffffff00)"
  teq "mask_to_cidr 0xfffffffc" "30" "$(mask_to_cidr 0xfffffffc)"
  teq "mask_to_cidr 0xffffff00" "24" "$(mask_to_cidr 0xffffff00)"

  # 3. in_subnet: мусор обязан отвергаться. Инвариант fail-open — при
  #    подтверждении мусора фильтр исключил бы ВСЕ адреса и отключил sweep,
  #    т.е. корп. трафик ушёл бы в Karing мимо туннеля.
  for st_out in '/' '[/]' 'abc' '0/0' '10.20.0.0/' '/xx' '10.20.0.0/33' \
               '10.20.0.0/1x' '10.20.0.0/32/8' '' 'x/30'; do
    in_subnet 192.168.0.33 "$st_out"
    [ $? -ne 0 ]; t "in_subnet отвергает [$st_out]" "$?"
  done
  in_subnet 192.168.0.33 192.168.0.0/16; t "in_subnet: 192.168.0.33 ⊂ 192.168.0.0/16" "$?"
  in_subnet 10.20.0.1 10.20.0.0/30;       t "in_subnet: 10.20.0.1 ⊂ 10.20.0.0/30" "$?"
  in_subnet 10.20.0.4 10.20.0.0/30; [ $? -ne 0 ]; t "in_subnet: 10.20.0.4 вне /30" "$?"
  in_any_subnet 192.168.0.33 ""; [ $? -ne 0 ]; t "in_any_subnet с пустым списком = не подходит" "$?"
  in_any_subnet 10.20.0.1 "10.30.0.0/16 10.20.0.0/30"; t "in_any_subnet: 2-я запись списка" "$?"

  # 4. get_tunnel_subnets
  ST_IF_ALL="$ST_IF_FULL"
  teq "get_tunnel_subnets: POINTOPOINT utun7" "10.20.0.0/30" \
    "$(get_tunnel_subnets | grep '^10\.20\.0\.')"
  teq "get_tunnel_subnets: utun без peer-адреса" "10.30.5.0/24" \
    "$(get_tunnel_subnets | grep '^10\.30\.')"
  teq "get_tunnel_subnets: физический en0 не попадает" "" \
    "$(get_tunnel_subnets | grep '10\.34\.' | tr -d '\n')"
  ST_IF_ALL="$ST_IF_NOTUN"
  teq "get_tunnel_subnets: без utun — пусто (fail-open)" "" "$(get_tunnel_subnets | tr -d '\n')"
  ST_IF_ALL="$ST_IF_FULL"

  # 5. get_local_subnets: loopback и туннели отсекаются, en0 попадает.
  #    Порядок не сравниваем: LOCAL_ROUTES выводятся как объявлены, а
  #    интерфейсные — уже отсортированы внутри функции; важен состав.
  teq "get_local_subnets: без туннелей и loopback" \
    "10.34.0.0/16 10.34.174.0/24 192.168.128.0/24" \
    "$(get_local_subnets | sort | tr '\n' ' ' | sed 's/ *$//')"

  # 6. is_tunnel_iface / is_physical_iface
  is_tunnel_iface utun7; t "is_tunnel_iface utun7" "$?"
  is_tunnel_iface ppp0;  t "is_tunnel_iface ppp0" "$?"
  is_tunnel_iface lo0;   t "is_tunnel_iface lo0" "$?"
  is_tunnel_iface en0;   [ $? -ne 0 ]; t "is_tunnel_iface en0 = нет" "$?"
  is_physical_iface en0; t "is_physical_iface en0" "$?"
  is_physical_iface utun7; [ $? -ne 0 ]; t "is_physical_iface utun7 = нет" "$?"

  # 7. sweep целиком на фикстуре: снимает корп. /32, бережёт on-link адрес TUN,
  #    локальную сеть, параллельный туннель и не-корп. адреса.
  sweep_removed() { # <содержимое STATE>
    printf '%s\n' "$1" > "$st_tmp/state"
    STATE="$st_tmp/state"; DIAG_LOG="$st_tmp/diag"; : > "$st_tmp/diag"
    sweep_corp_hijacks 2>/dev/null
    grep 'SWEEP' "$st_tmp/diag" 2>/dev/null | sed -n 's/.*removed_utun32://p' |
      tr -s ' \t' ' ' | sed 's/^ *//; s/ *$//'
  }
  teq "sweep: снимает только корп. /32 (on-link адрес TUN сохранён)" \
    "192.168.0.33 192.168.0.232" "$(sweep_removed '')"
  teq "sweep: хост из STATE тоже снимается" \
    "192.168.0.33 192.168.0.232 203.0.113.9" "$(sweep_removed '203.0.113.9')"

  # 8. fail-open: без списка подсетей TUN фильтр снят и on-link адреса TUN
  #    попадают под снос — цена отказа get_tunnel_subnets, фиксируем явно.
  ST_IF_ALL="$ST_IF_NOTUN"
  teq "sweep без tun_nets: on-link адреса TUN сносятся (документированный риск)" \
    "10.20.0.1 10.20.0.2 192.168.0.33 192.168.0.232" "$(sweep_removed '')"
  ST_IF_ALL="$ST_IF_FULL"

  # информационно (не проверка): стоимость in_any_subnet на реальном списке.
  st_n=$(printf '%s\n' $LOCAL_ROUTES 10.20.0.0/30 10.30.5.0/24 | wc -l | tr -d ' ')
  st_s=$(date +%s); st_i=0
  while [ "$st_i" -lt 300 ]; do
    in_any_subnet 192.168.0.33 "$LOCAL_ROUTES 10.20.0.0/30 10.30.5.0/24" >/dev/null 2>&1
    st_i=$((st_i + 1))
  done
  st_e=$(date +%s)
  printf '[INFO] 300 вызовов in_any_subnet на %s подсетях: %s с (%.3f с/вызов)\n' \
    "$st_n" "$((st_e - st_s))" \
    "$(awk -v d="$((st_e - st_s))" 'BEGIN { printf "%.3f", d / 300 }')"

  rm -rf "$st_tmp"
  printf 'selftest: %s passed, %s failed (rc=%s)\n' "$st_pass" "$st_fail" \
    "$([ "$st_fail" -gt 0 ] && echo 1 || echo 0)"
  [ "$st_fail" -gt 0 ] && return 1
  return 0
}

case "${1:-}" in
  --selftest|--self-test)
    selftest "$0"
    exit $?
    ;;
esac

# Инициализируем маркер состояния VPN фактическим статусом при старте,
# чтобы не слать лишний сигнал up/down в момент перезапуска демона.
if find_iface >/dev/null 2>&1; then
  echo "up" > "$SIGNALED_VPN_STATE"
else
  echo "down" > "$SIGNALED_VPN_STATE"
fi
while true; do
  now=$(date +%s)
  iface=$(find_iface)
  session=$(vpn_session_id)

  if [ $((now - last_diag)) -ge 60 ]; then
    last_diag=$now
    # При выключенном VPN маршрутов ppp0 не бывает by design, а хайджеки utun
    # остаются от Karing direct_out — печатать их как признак аварии вводит
    # в заблуждение (выглядит как «туннель поднят, маршрутов 0»).
    if [ -z "$iface" ]; then
      diag STATUS "vpn=down"
    else
      defs=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $NF}' | tr '\n' ',')
      corps=$(netstat -rn -f inet 2>/dev/null | awk '$NF=="ppp0" && ($1 ~ /^192\.168\.0(\/16)?$/ || $1 ~ /^10(\/8)?$/) {n++} END{print n+0}')
      tun_nets=$(get_tunnel_subnets)
      hij=0
      # Счётчик намеренно ограничен корп. диапазонами 192.168.*/10.*: на utun
      # висит ~81 адрес, из них в счётчик попадают только единицы, иначе
      # vpn=up всегда читался бы как авария из-за обычных адресов Karing.
      for d in $(netstat -rn -f inet 2>/dev/null |
                awk '$1~/^(192\.168|10)\./ && $1!~/\// && $NF~/^utun/ {print $1}'); do
        in_any_subnet "$d" "$tun_nets" && continue
        hij=$((hij + 1))
      done
      diag STATUS "vpn=up defaults=[$defs] net_routes_ppp=$corps utun_hijacks=$hij"
    fi
  fi

  # Кулдаун после ложного Connected: не доверяем configd,
  # возвращаем маршруты только когда туннель снова отвечает на пробы.
  if [ "$now" -lt "$dead_until" ]; then
    if [ $((now - last_probe)) -ge 10 ]; then
      last_probe=$now
      if tunnel_alive; then
        report_alive yes
        dead_until=0
        fail=0
      else
        report_alive no
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
      del_routes "reassembly"
      add_routes "$iface"
      last_iface="$iface"
      last_session="$session"
      last_resolve=$now
      fail=0
      signal_vpn_transition "up"
    else
      assert_routes
      # Подхват доменов автодетекта (corp-learn.sh): при изменении
      # auto-конфига пересчитываем маршруты сразу, не дожидаясь 300с.
      new_auto=$(grep -vE '^[[:space:]]*(#|$)' "$AUTO_CONF" 2>/dev/null | tr '\n' ' ')
      if [ "$new_auto" != "$AUTO_SITE_DOMAINS" ]; then
        AUTO_SITE_DOMAINS=$new_auto
        del_routes "auto-config-changed"
        add_routes "$iface"
      fi
    fi
  elif [ -n "$last_iface" ] || [ -f "$STATE" ]; then
    del_routes "vpn-down"
    last_iface=""
    last_session=""
    fail=0
    signal_vpn_transition "down"
  fi

  # Проверка живости: маршруты держим, только пока корп. трафик реально проходит.
  if [ -n "$last_iface" ] && [ $((now - last_probe)) -ge 10 ]; then
    last_probe=$now
    if tunnel_alive; then
      report_alive yes
      fail=0
    else
      report_alive no
      fail=$((fail + 1))
      if [ "$fail" -ge 2 ]; then
        del_routes "probe-dead"
        last_iface=""
        last_session=""
        fail=0
        dead_until=$((now + 60))
        signal_vpn_transition "down"
      fi
    fi
  fi

  sleep 5
done
