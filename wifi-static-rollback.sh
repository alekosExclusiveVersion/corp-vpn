#!/usr/bin/env bash
set -u
# Откат Wi-Fi со статики на статику корп. (Manual) — для ручного восстановления
# Штатная конфигурация была сохранена 2026-09-09 08:20 перед переключением на DHCP.
# Запуск:  bash /Users/aleksei/Work/scripts/corp-vpn/wifi-static-rollback.sh

echo ">>> Возвращаю Wi-Fi на статику (Manual) 192.168.128.56/255.255.255.0 gw 192.168.128.1"
networksetup -setmanual "Wi-Fi" 192.168.128.56 255.255.255.0 192.168.128.1
echo ">>> DNS + поиск домены"
networksetup -setdnsservers "Wi-Fi" 192.168.0.210 1.1.1.1
networksetup -setsearchdomains "Wi-Fi" tradesoft.corp prj tradesoft.ru
echo ">>> Текущее состояние:"
networksetup -getinfo "Wi-Fi" | head -6
echo ">>> Если интернет/opencode не поднялись через 15 сек — подними Karing:"
echo "    scutil --nc start \"Karing (system)\""