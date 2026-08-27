#!/bin/sh

# Маршрутизация корп. трафика при подключении к корп. Wi-Fi (192.168.128.0/24).
# Работает параллельно с corp-vpn-routes.sh (для L2TP VPN).
# Проблема: Karing добавляет /32-маршруты для корп. IP (192.168.0.x) через utun,
# из-за чего DNS-запросы к корп. DNS (192.168.0.210) проходят через Karing
# и возвращают node IPs (198.20.x.x) вместо реальных корп. IP.
# Решение: добавляем маршруты для корп. DNS и ключевых доменов через en0.

CONF=/usr/local/etc/corp-networks.conf
STATE=/var/run/corp-wifi-routes.state
LOG=/var/log/corp-wifi-routes.log

# Корп. Wi-Fi подсеть
CORP_WIFI_SUBNET="192.168.128.0"
CORP_WIFI_MASK="255.255.255.0"

# Корп. DNS и ключевые серверы (всегда маршрутизируем через en0 при корп. Wi-Fi)
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
  cfg_vpn=$(grep -E '^VPN_SERVERS=' "$CONF" 2>/dev/null | head -1 | cut -d= -f2-)
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

# Проверяет, подключён ли к корп. Wi-Fi (en0 имеет IP в 192.168.128.0/24)
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

# Добавляет host-маршрут до VPN-сервера через en0 (внешний IP, минуя is_corp_ip).
# Нужно для установки L2TP/IPSec в обход Karing (utun11).
add_vpn_server_route_en0() {
  local ip="$1"
  # Удаляем конфликтующий маршрут через utun/Karing, если есть
  if ! route_via_en0 "$ip"; then
    route -n delete -host "$ip" >/dev/null 2>&1
  fi
  if route -n add -host "$ip" -interface en0 >/dev/null 2>&1; then
    log "Added VPN server route $ip via en0"
    echo "$ip" >> "$STATE"
    return 0
  fi
  log "Failed to add VPN server route $ip via en0"
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
  if is_corp_wifi; then
    # Проверяем, не активен ли VPN (ppp0 интерфейс)
    if ifconfig ppp0 >/dev/null 2>&1; then
      # VPN активен — удаляем свои маршруты через en0, ppp0 берёт управление
      if [ -f "$STATE" ]; then
        del_routes
        log "VPN connected, cleaned wifi-routes"
      fi
      sleep 10
      continue
    fi

    # Маршруты до VPN-серверов напрямую через en0 — чтобы L2TP/IPSec мог
    # установиться в обход Karing (utun11), который иначе перехватывает их.
    add_vpn_server_routes

    # Добавляем маршруты для корп. DNS
    add_host_route_en0 "$CORP_DNS"
    add_host_route_en0 "$CORP_DNS_SECONDARY"
    add_host_route_en0 "$CORP_PROBE"

    # Резолвим и добавляем маршруты для корп. доменов
    for domain in $(grep -E '^DOMAINS=' "$CONF" 2>/dev/null | cut -d= -f2); do
      for ip in $(resolve_corp_dns "$domain"); do
        add_host_route_en0 "$ip"
      done
    done

    # Добавляем маршруты для SITE_DOMAINS (первые 20 для экономии)
    # Полный список обрабатывается только при VPN
    for domain in $(head -20 <<< "$(grep -E '^SITE_DOMAINS=' "$CONF" 2>/dev/null | cut -d= -f2)"); do
      for ip in $(resolve_corp_dns "$domain"); do
        add_host_route_en0 "$ip"
      done
    done

    sleep 30
  else
    # Не корп. Wi-Fi — очищаем маршруты
    if [ -f "$STATE" ]; then
      del_routes
      log "Corp Wi-Fi disconnected, routes cleaned"
    fi
    sleep 10
  fi
done
