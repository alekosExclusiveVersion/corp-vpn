#!/bin/bash
# Автовосстановление VPN после пробуждения (копируется в ~/.wakeup)
# Используется sleepwatcher (brew install sleepwatcher)
VPN_NAME="vpn3-ts"

# Wait for network to stabilize after wake
for i in $(seq 1 15); do
    EN0_IP=$(ipconfig getifaddr en0 2>/dev/null)
    if [ -n "$EN0_IP" ]; then break; fi
    sleep 2
done

sleep 5

# Если подключён к корп. сети по LAN-кабелю — VPN не нужен и не поднимаем.
# Ищем на не-Wi-Fi интерфейсах (en0 = Wi-Fi) IP из корп. подсети 192.168.128.0/24.
for iface in $(ifconfig -lu 2>/dev/null); do
    case "$iface" in
        en0|lo|utun*|gif*|stf*|anpi*|awdl*|llw*|ppp*|vnic*|ap*) continue ;;
    esac
    EN0_IP=""
    EN0_IP=$(ipconfig getifaddr "$iface" 2>/dev/null)
    if [ -n "$EN0_IP" ] && printf '%s' "$EN0_IP" | grep -qE '^192\.168\.128\.'; then
        logger "corp-vpn: on corp LAN after wake ($iface $EN0_IP) — VPN reconnect skipped"
        exit 0
    fi
done

STATUS=$(scutil --nc status "$VPN_NAME" 2>/dev/null | head -1)
if [ "$STATUS" = "Connected" ]; then
    exit 0
fi

# Try up to 3 times
for attempt in 1 2 3; do
    networksetup -connectpppoeservice "$VPN_NAME" 2>/dev/null
    
    for i in $(seq 1 10); do
        sleep 2
        STATUS=$(scutil --nc status "$VPN_NAME" 2>/dev/null | head -1)
        if [ "$STATUS" = "Connected" ]; then
            logger "corp-vpn: $VPN_NAME reconnected after wake (attempt $attempt)"
            exit 0
        fi
    done
    
    scutil --nc stop "$VPN_NAME" 2>/dev/null
    sleep 3
done

logger "corp-vpn: $VPN_NAME reconnect failed after 3 attempts"
