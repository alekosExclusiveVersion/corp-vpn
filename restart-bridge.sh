#!/bin/bash
# restart-bridge.sh — перезапуск SOCKS-моста с обновлённым кодом
set -e

echo "==> Остановка моста..."
launchctl unload /Library/LaunchDaemons/com.aleksei.corp-bridge.plist 2>/dev/null || true

echo "==> Очистка старых логов..."
sudo truncate -s 0 /tmp/socks-bridge.err /tmp/socks-bridge.log 2>/dev/null || true

echo "==> Ожидание завершения процессов..."
sleep 2

echo "==> Запуск моста..."
launchctl load -w /Library/LaunchDaemons/com.aleksei.corp-bridge.plist

echo "==> Проверка статуса..."
sleep 3

if nc -z 127.0.0.1 1082 2>/dev/null; then
    echo "  [OK] Мост запущен и слушает на 127.0.0.1:1082"
    echo "  Логи:"
    tail -5 /tmp/socks-bridge.log 2>/dev/null || echo "  (нет логов)"
else
    echo "  [FAIL] Мост не запустился"
    echo "  Ошибки:"
    tail -20 /tmp/socks-bridge.err 2>/dev/null || echo "  (нет ошибок)"
    exit 1
fi