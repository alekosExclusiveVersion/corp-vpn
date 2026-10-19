#!/bin/bash
# Автовосстановление VPN после пробуждения (копируется в ~/.wakeup)
# Используется sleepwatcher (brew install sleepwatcher)
VPN_NAME="vpn3-ts"
CONF=/usr/local/etc/corp-networks.conf
CORP_WIFI_EN0_MACS_DEFAULT="b6:be:0c:d5:9a:24"

# Эталон приватного MAC en0 корп. Wi-Fi — из corp-networks.conf, если задан.
CORP_WIFI_EN0_MACS="$CORP_WIFI_EN0_MACS_DEFAULT"
if [ -f "$CONF" ] && grep -qE '^CORP_WIFI_EN0_MACS=' "$CONF"; then
    CORP_WIFI_EN0_MACS="$(grep -E '^CORP_WIFI_EN0_MACS=' "$CONF" | head -1 | cut -d= -f2- | tr -d '"' | tr -d '\n')"
    [ -n "$CORP_WIFI_EN0_MACS" ] || CORP_WIFI_EN0_MACS="$CORP_WIFI_EN0_MACS_DEFAULT"
fi

# Wait for network to stabilize after wake
for i in $(seq 1 15); do
    EN0_IP=$(ipconfig getifaddr en0 2>/dev/null)
    if [ -n "$EN0_IP" ]; then break; fi
    sleep 2
done

# Корп. Wi-Fi: L2TP/IPSec там не поднимается (сеть глушит L2TP-в-ESP), поэтому
# не пытаемся даже один раз — иначе после сна уходит ~80 с впустую на 3 попытки.
# Признак — per-network приватный MAC en0: он присваивается при ассоциации и
# доступен сразу, ещё до выдачи IP по DHCP (поэтому проверяем и при пустом IP).
EN0_MAC=$(ifconfig en0 2>/dev/null | awk '/ether/{print $2; exit}')
if [ -n "$EN0_MAC" ]; then
    case " $CORP_WIFI_EN0_MACS " in
        *" $EN0_MAC "*)
            logger "corp-vpn: on corp Wi-Fi after wake (mac_en0=$EN0_MAC) — VPN reconnect skipped"
            exit 0
            ;;
    esac
fi

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
