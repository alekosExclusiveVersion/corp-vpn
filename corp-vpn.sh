#!/bin/bash
# corp-vpn.sh — управление корпоративным L2TP + статус моста и Karing.
# Корп. VPN обычно подключается через System Settings (GUI); этот скрипт —
# обёртка для диагностики и CLI-подключения.
set -u

VPN_NAME="${2:-vpn3-ts}"
CORP_IF="ppp0"
BRIDGE_PORT=1082
BRIDGE_DNS="192.168.0.210"
CORP_GW="192.168.160.1"

usage() {
    cat <<EOF
Использование: corp-vpn.sh {status|start|stop} [имя VPN]
VPN (по умолчанию vpn3-ts): vpn1, vpn2-ts, vpn3-ts, vpn4
EOF
}

corp_up() {
    ifconfig "$CORP_IF" 2>/dev/null | grep -q "inet " && \
        ping -c 1 -t 3 "$CORP_GW" >/dev/null 2>&1
}

bridge_up() {
    nc -z 127.0.0.1 "$BRIDGE_PORT" >/dev/null 2>&1
}

status() {
    echo "== Корп. туннель =="
    if corp_up; then
        echo "  СТАТУС: работает ($(ifconfig "$CORP_IF" 2>/dev/null | grep 'inet ' | awk '{print $2}'))"
        local vpn
        for vpn in vpn1 vpn2-ts vpn3-ts vpn4; do
            local st
            st=$(scutil --nc status "$vpn" 2>/dev/null | head -1)
            [ "$st" = "Connected" ] && echo "  активный: $vpn"
        done
    else
        echo "  СТАТУС: не подключён"
    fi
    echo "== Мост =="
    bridge_up && echo "  СТАТУС: работает (127.0.0.1:$BRIDGE_PORT, DNS $BRIDGE_DNS)" || \
        echo "  СТАТУС: НЕ работает"
    echo "== Karing =="
    if scutil --nc status "Karing (system)" 2>/dev/null | head -1 | grep -q Connected; then
        echo "  СТАТУС: подключён"
    else
        echo "  СТАТУС: выключен"
    fi
    echo "== Маршруты корп. подсетей =="
    netstat -rn -f inet 2>/dev/null | grep -E "^10 |^192.168.0/16" || echo "  нет"
}

start() {
    if corp_up; then
        echo "Корп. туннель уже поднят."
        return 0
    fi
    echo "Подключаю $VPN_NAME (CLI)..."
    scutil --nc start "$VPN_NAME" 2>/dev/null
    sleep 6
    if corp_up; then
        echo "OK: туннель поднят."
    else
        echo "Не удалось через CLI. Подключи корп. VPN в System Settings → VPN → $VPN_NAME."
        echo "Возможная причина: keychain (\"incorrect user shared secret found\")."
        return 1
    fi
}

stop() {
    echo "Отключаю $VPN_NAME..."
    scutil --nc stop "$VPN_NAME" 2>/dev/null
    sleep 3
    if corp_up; then
        echo "Туннель всё ещё жив. Попробуй: System Settings → VPN → выключить."
        return 1
    fi
    echo "OK: туннель отключён."
}

case "${1:-}" in
    status) status ;;
    start) start ;;
    stop) stop ;;
    *) usage ;;
esac
