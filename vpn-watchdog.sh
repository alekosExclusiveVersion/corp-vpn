#!/bin/bash
# Watchdog: держит один активный корпоративный VPN (L2TP/IPSec).
# Профили — это L2TP-сервисы, подключаются через scutil --nc start.
# Если ни один не подключён — поднимает по приоритету. Активный не трогает.
# Запускается LaunchDaemon'ом com.tradesoft.corp-vpn-watchdog каждые 30с.

LOCK=/tmp/corp-vpn-watchdog.lock
if ! mkdir "$LOCK" 2>/dev/null; then
    [ -z "$(find "$LOCK" -mmin +3 2>/dev/null)" ] && exit 0
    rmdir "$LOCK" 2>/dev/null || exit 0
    mkdir "$LOCK" || exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

PROFILES="vpn3-ts vpn4 vpn2-ts"

# Если какой-то профиль уже подключён — ничего не делаем
for p in $PROFILES; do
    if [ "$(scutil --nc status "$p" 2>/dev/null | head -1)" = "Connected" ]; then
        exit 0
    fi
done

# Пытаемся поднять по приоритету (L2TP/IPSec через scutil --nc start)
for p in $PROFILES; do
    scutil --nc start "$p" 2>/dev/null
    for i in $(seq 1 10); do
        sleep 2
        if [ "$(scutil --nc status "$p" 2>/dev/null | head -1)" = "Connected" ]; then
            logger "corp-vpn: $p auto-connected by watchdog"
            exit 0
        fi
    done
    # отменяем на всякий случай, если начали подъём, но он не завершился
    scutil --nc stop "$p" 2>/dev/null
done

logger "corp-vpn: watchdog failed to connect any profile"
