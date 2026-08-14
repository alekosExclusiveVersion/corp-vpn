# Corp VPN route fix (macOS)

Каноническая папка всех артефактов. Маршруты до корпоративных хостов
заворачиваются через корп L2TP VPN (`vpn3-ts` / интерфейс `ppp0`),
чтобы серверы (btk66.ru админка, mysql, eurotradeplus) видели корп-IP `92.255.230.89`.

## Файлы

| Файл | Назначение |
|------|------------|
| `fix-mysql-routes.sh` | Основной скрипт: удаляет host-маршруты (в т.ч. пин Karing) и добавляет их через корп-gateway `192.168.160.1` |
| `fix-mysql-routes.plist` | LaunchDaemon-страховка: прогон скрипта раз в 300 сек |
| `ip-up` | Хук pppd: мгновенный прогон скрипта при подключении L2TP (интерфейс `ppp0`) |

## Как это работает

- Скрипт добавляет host-маршруты (`/32`) через gateway L2TP `192.160.160.1`.
- Хост-маршрут специфичнее дефолтного TUN Karing → трафик идёт через корп VPN, не попадая в прокси.
- Перед добавлением маршруты удаляются — иначе пин Karing (host-маршрут через `utun6`, приоритет 0) перебивает наш (приоритет 9).
- Маршруты живут, пока `ppp0` поднят. Переподключение L2TP их сбрасывает → восстанавливает `ip-up`, страхует демон.

## Установка (sudo)

```bash
sudo cp ~/corp-vpn/ip-up /etc/ppp/ip-up
sudo chmod 755 /etc/ppp/ip-up
sudo launchctl bootout system/com.tradesoft.fix-mysql-routes 2>/dev/null
sudo cp ~/corp-vpn/fix-mysql-routes.plist /Library/LaunchDaemons/com.tradesoft.fix-mysql-routes.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.tradesoft.fix-mysql-routes.plist
```

Проверка:
```bash
sudo bash ~/corp-vpn/fix-mysql-routes.sh
route -n get 185.137.232.115 | grep interface   # должно быть ppp0
```

## Обслуживание

- Добавить/убрать хост: отредактировать массив `HOSTS` в `fix-mysql-routes.sh`
  (переустановка не нужна — скрипт читается при каждом запуске).
- Лог: `/var/log/fix-mysql-routes.log`.
- Удаление демона: `sudo launchctl bootout system/com.tradesoft.fix-mysql-routes`.
- Удаление хука: `sudo rm /etc/ppp/ip-up`.

## Проверенные хосты

| IP | Зачем |
|----|-------|
| 95.143.188.109 | p7ru1 (mysql) |
| 95.143.188.62 | p7ru2 (mysql) |
| 95.143.188.173 | p7ru3 (mysql) |
| 5.35.3.83 | p7ru4 (mysql) |
| 212.41.11.239 | p7ru5 (mysql) |
| 5.188.159.52 | p7ru8 (mysql) |
| 195.201.108.82 | p5g21 (mysql) |
| 185.137.232.115 | btk66.ru (+ mysql :3306, админка) |
| 116.202.228.248 | eurotradeplus.tradesoft.ru:3306 / shop.eurotradeplus.pl |
