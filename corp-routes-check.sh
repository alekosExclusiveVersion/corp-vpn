#!/bin/bash
# Проверка битых fakeip-маршрутов Karing (пул 198.20.0.0/15).
#
# Симптом: пакеты на fakeip-адрес узла (напр. api.opencode.ai -> 198.20.0.x)
# уходят через физический интерфейс (en0/<шлюз>), вместо utun4 -> timeout 000.
# Кривые host-маршруты Karing создаёт при старте туннеля, когда default ещё
# указывает на en0; после перехода default на utun4 они остаются.
#
# Использование:
#   corp-routes-check.sh             показать что найдено (exit=1 если есть битые)
#   corp-routes-check.sh --sudo-cmd  вывести готовые sudo-команды (без запуска)
#
# Скрипт НИЧЕГО не изменяет (только читает таблицу маршрутов).

# Битый маршрут: адрес из пула fakeip, у которого интерфейс - не utun*.
# Пример строки netstat:
#   198.20.0.11   192.168.128.1   UGHS   en0
#   198.20.0.8    link#23         UHWIig utun4
bad() {
  netstat -rn -f inet 2>/dev/null | awk '
    $1 ~ /^198\.20\./ && $4 !~ /^utun/ { print $1, "ifc=" $4, "gw=" $2 }
  '
}

list=$(bad)
if [ -z "$list" ]; then
  echo "OK: все fakeip-маршруты идут через utun*"
  exit 0
fi

echo "НАЙДЕНЫ битые fakeip-маршруты (не через utun*):"
echo "$list"
if [ "$1" = "--sudo-cmd" ]; then
  echo
  echo "Выполнить вручную (sudo потребует пароль):"
  echo "$list" | awk '{ print "  sudo route delete -host", $1 }'
fi
exit 1