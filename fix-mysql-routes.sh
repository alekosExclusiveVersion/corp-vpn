#!/bin/bash
set -u
GW="192.168.160.1"
HOSTS=(
  "95.143.188.109"   # p7ru1
  "95.143.188.62"    # p7ru2
  "95.143.188.173"   # p7ru3
  "5.35.3.83"        # p7ru4
  "212.41.11.239"    # p7ru5
  "5.188.159.52"     # p7ru8
  "195.201.108.82"   # p5g21
  "185.137.232.115"  # btk66.ru (+ mysql)
  "116.202.228.248"  # eurotradeplus.tradesoft.ru:3306 / shop.eurotradeplus.pl
)

if [ "$(id -u)" != "0" ]; then
  echo "Запустите с sudo: sudo bash $0"
  exit 1
fi

if ! ifconfig ppp0 >/dev/null 2>&1; then
  exit 0
fi

INTERACTIVE=false
[ -t 1 ] && INTERACTIVE=true

ERR=0
for ip in "${HOSTS[@]}"; do
  # удаляем все host-маршруты до этого IP (в т.ч. пин Karing через utun6),
  # иначе он перебьёт наш маршрут приоритетом 0
  route -n delete -host "$ip" 2>/dev/null
  route -n delete -host "$ip" 2>/dev/null
  if ! route -n add -host "$ip" "$GW" 2>/dev/null; then
    echo "ERROR: не удалось добавить маршрут $ip"
    ERR=1
  fi
done

if $INTERACTIVE; then
  echo "=== Проверка (интерфейс должен быть ppp0):"
  for ip in "${HOSTS[@]}"; do
    iface=$(route -n get "$ip" 2>/dev/null | awk '/interface:/{print $2}')
    echo "$ip -> ${iface:-?}"
  done
fi
exit $ERR
