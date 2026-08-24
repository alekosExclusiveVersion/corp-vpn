#!/bin/bash
# Watchdog: держит один активный корпоративный VPN.
# Если ни один не подключён — поднимает по приоритету. Активный профиль не трогает.

LOCK=/tmp/corp-vpn-watchdog.lock
if ! mkdir "$LOCK" 2>/dev/null; then
    [ -z "$(find "$LOCK" -mmin +3 2>/dev/null)" ] && exit 0
    rmdir "$LOCK" 2>/dev/null || exit 0
    mkdir "$LOCK" || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

PROFILES="vpn3-ts vpn4 vpn1"

for p in $PROFILES; do
    if [ "$(scutil --nc status "$p" 2>/dev/null | head -1)" = "Connected" ]; then
        exit 0
    fi
done

for p in $PROFILES; do
    networksetup -connectpppoeservice "$p" 2>/dev/null
    for i in $(seq 1 10); do
        sleep 2
        if [ "$(scutil --nc status "$p" 2>/dev/null | head -1)" = "Connected" ]; then
            logger "corp-vpn: $p auto-connected by watchdog"
            exit 0
        fi
    done
done

logger "corp-vpn: watchdog failed to connect any profile"
