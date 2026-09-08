#!/bin/sh

# Маршрутизация корп. трафика при подключении к корп. Wi-Fi (192.168.128.0/24).
# Работает параллельно с corp-vpn-routes.sh (для L2TP VPN).
# Единственная задача: pin VPN_SERVERS (публичные IP корп. L2TP/IPSec) через
# шлюз Wi-Fi, чтобы VPN мог установиться в обход Karing (utun11).
#
# ИСТОРИЯ: раньше скрипт дополнительно привязывал корп. хосты (0.210, 0.33,
# 0.232 и резолвы DOMAINS/SITE_DOMAINS) к en0 через on-link/АРП-пины. Проверено
# 2026-09-08: на этой Wi-Fi такие пины НЕ доставляются для 0.33/0.232 (b24,
# servicedesk) — TCP к ним гаснет (Arp-proxy шлюза не форвардит). Исправление:
# корп. hosts-пины убраны, доступ к корп. ресурсам и DNS обеспечивает правило
# Karing «На прямую» (ip_cidr 192.168.0.0/16, direct_out через реальный шлюз).

CONF=/usr/local/etc/corp-networks.conf
STATE=/var/run/corp-wifi-routes.state
LOG=/var/log/corp-wifi-routes.log

# Корп. Wi-Fi подсеть
CORP_WIFI_SUBNET="192.168.128.0"
CORP_WIFI_MASK="255.255.255.0"

# Корп. DNS и ключевые серверы (справочно; больше не пинуются к en0 — см. шапку)
CORP_DNS="192.168.0.210"
CORP_DNS_SECONDARY="192.168.0.33"
CORP_PROBE="192.168.0.232"

# VPN-серверы корп. L2TP/IPSec (внешние публичные IP).
# Их трафик должен идти напрямую через en0, НЕ через Karing (utun11).
# Иначе IPSec/L2TP (UDP 500/4500, ESP) не может установиться — см. анализ
# «почему корп VPN не подключается при корп. Wi-Fi».
VPN_SERVERS="109.194.204.122 178.141.80.30 109.194.204.125"

# Если в corp-networks.conf задан свой VPN_SERVERS — используем его (централизованно)
if [ -f "$CONF" ]; then
  cfg_vpn=$(grep -E '^VPN_SERVERS=' "$CONF" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
  if [ -n "$cfg_vpn" ]; then
    VPN_SERVERS="$cfg_vpn"
  fi
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
  # Ограничиваем размер лога 1000 строк
  if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
    tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

# Предохранитель: удаляет осиротевшие /32-маршруты, оставшиеся от СТАРОЙ
# версии скрипта (которая добавляла SITE_DOMAINS/DOMAINS/DNS через
# `route add -host <ip> -interface en0`). Вне on-link (192.168.128.0/24) такие
# маршруты macOS превращает в `UHS <ip> 192.168.0.6 en0` через ARP-proxy шлюза
# (MAC b6:be:c:d5:9a:24) — они ведут трафик сайтов в никуда (HTTP 000).
# Удаляем любую UHS-запись, чей gateway 192.168.0.6 и интерфейс физический (en*),
# кроме самого host-маршрута до 192.168.0.6. Вызывается на каждом цикле, пока
# корп. VPN (ppp0) не активен.
clean_dead_gw_routes() {
  netstat -rn -f inet 2>/dev/null |
    awk '$2=="192.168.0.6" && $1!="192.168.0.6" && $NF ~ /^en/{print $1}' |
    while read -r ip; do
      [ -n "$ip" ] || continue
      route -n delete -host "$ip" >/dev/null 2>&1 && log "cleaned dead /32 $ip (gw 192.168.0.6)"
    done
}

# Проверяет, подключён ли к корп. Wi-Fi (en0 в подсети 192.168.128.0/24).
# Критерий по IP en0: корп. Wi-Fi единственный выдаёт подсеть 192.168.128.0/24.
# SSID/ассоциацию через networksetup получить НЕЛЬЗЯ (отдаёт "not associated"
# даже при рабочей сети без DHCP), поэтому IP-детект — единственный надёжный.
is_corp_wifi() {
  local ip
  ip=$(ipconfig getifaddr en0 2>/dev/null)
  [ -z "$ip" ] && return 1
  # Проверяем префикс 192.168.128.
  case "$ip" in
    192.168.128.*) return 0 ;;
  esac
  return 1
}

# Проверяет, есть ли уже маршрут через en0 для данного хоста
route_via_en0() {
  route -n get "$1" 2>/dev/null | grep -q 'interface: en0'
}

# Проверяет, является ли IP внутренним корп. адресом (10/8 или 192.168/16)
is_corp_ip() {
  case "$1" in
    10.*) return 0 ;;
    192.168.*) return 0 ;;
  esac
  return 1
}

# Добавляет host-маршрут через en0, даже если уже есть маршрут через utun
# Добавляет ТОЛЬКО внутренние корп. IP (10/8, 192.168/16)
add_host_route_en0() {
  local ip="$1"
  # Пропускаем внешние IP (не корп. подсети)
  if ! is_corp_ip "$ip"; then
    return 0
  fi
  if route_via_en0 "$ip"; then
    return 0
  fi
  # Удаляем существующий маршрут через utun (если есть)
  if ! route_via_en0 "$ip"; then
    route -n delete -host "$ip" >/dev/null 2>&1
  fi
  if route -n add -host "$ip" -interface en0 >/dev/null 2>&1; then
    log "Added route $ip via en0"
    echo "$ip" >> "$STATE"
    return 0
  fi
  log "Failed to add route $ip via en0"
  return 1
}

# Добавляет host-маршрут до VPN-сервера через шлюз корп. Wi-Fi (внешний публичный IP,
# минуя is_corp_ip). Публичный IP не лежит на локальном линке, поэтому его НЕЛЬЗЯ
# привязывать через "-interface en0" (on-link -> ARP на чужой IP -> пакеты гаснут).
# Правильно: маршрут через шлюз (-gateway), который форвардит на реальный интернет.
# Нужно для установки L2TP/IPSec в обход Karing (utun11).
add_vpn_server_route_en0() {
  local ip="$1"
  local gw
  # Шлюз берём из default-маршрута через НЕ-туннельный интерфейс (en0/wlan).
  # На этой машине исходящий в интернет идёт через Wi-Fi (en0). При активной
  # system-extension Karing default-маршрут уходит в utun10 (без gateway:), но
  # параллельно сеть держит ещё один default через физический интерфейс с
  # реальным шлюзом. Исключаем utun*, чтобы гарантированно взять шлюз Wi-Fi,
  # а не пустой gateway туннеля. Это критично для не-корп. сети: без маршрута
  # -> en0 L2TP/IPSec не доходит до сервера ("No route to host").
  gw=$(netstat -rn -f inet | awk '$1=="default" && $NF!~/^utun/{print $2; exit}')
  if [ -z "$gw" ]; then
    gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
  fi
  [ -n "$gw" ] && [ "$gw" != "0.0.0.0" ] && [ "$gw" != "default" ] || return 1
  # Удаляем конфликтующий маршрут через utun/Karing или on-link, если есть
  route -n delete -host "$ip" >/dev/null 2>&1
  if route -n add -host "$ip" -gateway "$gw" >/dev/null 2>&1; then
    log "Added VPN server route $ip via gateway $gw"
    echo "$ip" >> "$STATE"
    return 0
  fi
  log "Failed to add VPN server route $ip via gateway $gw"
  return 1
}

# Добавляет маршруты до всех VPN-серверов напрямую через en0
add_vpn_server_routes() {
  for ip in $VPN_SERVERS; do
    add_vpn_server_route_en0 "$ip"
  done
}

# Удаляет все добавленные маршруты
del_routes() {
  if [ -f "$STATE" ]; then
    while IFS= read -r ip; do
      [ -z "$ip" ] && continue
      route -n delete -host "$ip" >/dev/null 2>&1
      log "Deleted route $ip"
    done < "$STATE"
    rm -f "$STATE"
  fi
}

# Резолвит домен через корп. DNS напрямую (в обход Karing DNS)
resolve_corp_dns() {
  dig @"$CORP_DNS" +short +time=2 +tries=1 "$1" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# Главный цикл
log "Starting corp-wifi-routes.sh"
: > "$STATE"

while true; do
  # Предохранитель от осиротевших /32 -> 192.168.0.6 (см. clean_dead_gw_routes).
  # Чистим на любой сети, пока корп. VPN не активен (при активном ppp маршруты
  # через ppp и их не трогаем).
  if ! ifconfig ppp0 >/dev/null 2>&1; then
    clean_dead_gw_routes
  fi

  # VPN активен — удаляем свои маршруты через en0 (ppp0 берёт управление)
  if ifconfig ppp0 >/dev/null 2>&1; then
    if [ -f "$STATE" ]; then
      del_routes
      log "VPN connected, cleaned wifi-routes"
    fi
    sleep 10
    continue
  fi

  if is_corp_wifi; then
    # Маршруты до VPN-серверов напрямую через шлюз Wi-Fi — чтобы L2TP/IPSec мог
    # установиться в обход Karing (utun11), который иначе перехватывает их.
    add_vpn_server_routes

    # Корп. хосты (192.168.0.x) к en0 НЕ привязываем: на этой Wi-Fi on-link/
    # АРП-пины для 0.33/0.232 не доставляются (TCP гаснет). Доступ и DNS даёт
    # Karing («На прямую»: ip_cidr 192.168.0.0/16, direct_out). См. шапку файла.

    sleep 30
  else
    # Не корп. Wi-Fi: держим только VPN_SERVERS (нужны для подъёма L2TP на
    # любой сети, пока VPN не активен), корп. DNS/site-маршруты не трогаем —
    # они тут не нужны. Если до этого держались корп. DNS-маршруты, сносим их.
    if [ -f "$STATE" ]; then
      del_routes
      log "Corp Wi-Fi disconnected, routes cleaned"
    fi
    # VPN-серверы возвращаем всегда (после del_routes они снесены)
    add_vpn_server_routes
    sleep 10
  fi
done
