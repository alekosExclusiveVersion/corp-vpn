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
DEMAND_FILE=/tmp/corp-vpn-demand
HOLD_FILE=/tmp/corp-vpn-hold
ONDEMAND_PORT=5354
DEMAND_TTL=300

usage() {
    cat <<EOF
Использование: corp-vpn.sh {status|start|stop|demand} [имя VPN | минуты]
  start   — поднять туннель и удерживать 30 мин (дальше — по простою)
  demand  — отметить спрос на корп. сеть и поднять туннель (минуты, по умолчанию 30)
  stop    — отключить туннель и снять удержание
VPN (по умолчанию vpn3-ts): vpn1-ts, vpn2-ts, vpn3-ts, vpn4-ts
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
        for vpn in vpn1-ts vpn2-ts vpn3-ts vpn4-ts; do
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
    echo "== VPN on demand =="
    if nc -z 127.0.0.1 "$ONDEMAND_PORT" >/dev/null 2>&1; then
        echo "  СТАТУС: слушает 127.0.0.1:$ONDEMAND_PORT"
    else
        echo "  СТАТУС: НЕ слушает — корп. имена туннель не поднимут"
    fi
    if [ -f "$DEMAND_FILE" ]; then
        local ts age
        ts=$(stat -f %m "$DEMAND_FILE" 2>/dev/null || echo 0)
        age=$(( $(date +%s) - ts ))
        echo "  спрос: ${age}с назад (действует ${DEMAND_TTL}с)"
    else
        echo "  спрос: нет"
    fi
    if [ -f "$HOLD_FILE" ]; then
        local left
        left=$(( $(cat "$HOLD_FILE" 2>/dev/null || echo 0) - $(date +%s) ))
        if [ "$left" -gt 0 ]; then
            echo "  удержание: ещё $(( left / 60 )) мин"
        fi
    fi
}

# Отметить спрос на корп. сеть: маркер для watchdog (туннель нужен сейчас)
# и удержание для демона on-demand (не гасить по простою N минут).
mark_demand() {
    local minutes="${1:-30}" until
    case "$minutes" in
        ''|*[!0-9]*) echo "Минуты — целое число"; return 2 ;;
    esac
    until=$(( $(date +%s) + minutes * 60 ))
    printf '%s\n' "$until" > "$HOLD_FILE" 2>/dev/null || return 1
    date '+%Y-%m-%d %H:%M:%S' > "$DEMAND_FILE" 2>/dev/null || return 1
    chmod 666 "$DEMAND_FILE" "$HOLD_FILE" 2>/dev/null
    return 0
}

start() {
    mark_demand "${HOLD_MIN:-30}" >/dev/null 2>&1
    if corp_up; then
        echo "Корп. туннель уже поднят."
        return 0
    fi
    # Проводное подключение к корп. сети: VPN не нужен, ресурсы доступны напрямую.
    for iface in $(ifconfig -lu 2>/dev/null); do
        case "$iface" in
            en0|lo|utun*|gif*|stf*|anpi*|awdl*|llw*|ppp*|vnic*|ap*) continue ;;
        esac
        ip=$(ipconfig getifaddr "$iface" 2>/dev/null)
        if [ -n "$ip" ] && printf '%s' "$ip" | grep -qE '^192\.168\.128\.'; then
            echo "Обнаружено проводное подключение к корп. сети ($iface: $ip)."
            echo "VPN не требуется — корп. ресурсы доступны напрямую."
            return 0
        fi
    done
    echo "Подключаю $VPN_NAME (networksetup)..."
    networksetup -connectpppoeservice "$VPN_NAME" 2>/dev/null
    sleep 6
    if corp_up; then
        echo "OK: туннель поднят."
    else
        echo "Не удалось через CLI. Подключи корп. VPN в System Settings → VPN → $VPN_NAME."
        echo "Возможная причина: keychain (\"incorrect user shared secret found\")."
        return 1
    fi
}

# Ручной спрос: пригодится, если обращаешься по IP (RDP, MySQL) — DNS-триггера
# там нет. Туннель поднимется и не будет погашен по простою заданные минуты.
demand() {
    local minutes="${1:-30}"
    mark_demand "$minutes" || { echo "Не удалось записать маркер спроса."; return 1; }
    echo "OK: спрос отмечен, удержание $minutes мин."
    HOLD_MIN="$minutes" start
}

# Какие PPP-профили реально подключены (может быть не тот, что в VPN_NAME:
# рабочий профиль выбирается по факту, а не по умолчанию).
ppp_connected() {
    scutil --nc list 2>/dev/null | grep -E '\(Connected\).*PPP' | \
        sed -n 's/.*"\([^"]*\)".*/\1/p'
}

stop() {
    local names n
    names=$(ppp_connected)
    [ -n "$names" ] || names="$VPN_NAME"
    rm -f "$DEMAND_FILE" "$HOLD_FILE" 2>/dev/null
    for n in $names; do
        echo "Отключаю $n..."
        scutil --nc stop "$n" 2>/dev/null
    done
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
    demand) demand "${2:-30}" ;;
    stop) stop ;;
    *) usage ;;
esac
