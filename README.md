# Tradesoft VPN: правила Karing из корпоративной сети

Генератор групп/правил для Karing (sing-box) из единого файла корпоративных
сетей. Инфраструктура маршрутизации (демон `corp-vpn-routes.sh`, установщик)
находится в репозитории **corp-vpn** (`~/Work/scripts/corp-vpn`) — смотрите там
`CORP-VPN-SETUP.md`.

## Что делает

Из `corp-networks.conf` строит группы Karing (профиль «Самостоятельная
настройка»):

| Группа | Outbound | Назначение |
|---|---|---|
| `ts-network` | `direct_out` | вся корп. зона: домены (`DOMAINS`, `SITE_DOMAINS`, `MYSQL_HOSTS`), суффиксы `DOMAIN_SUFFIX`, IP (`NET_ROUTES`, `VPN_SERVERS`, MySQL) |
| `На прямую` | `direct_out` | только личные правки пользователя (напр. `.yandex.ru`) |

На корп. Wi-Fi группы намеренно нужны: L2TP там не поднимается (§3.6.1 в
CORP-VPN-SETUP.md), поэтому корп. ресурсы идут в direct_out.

Маршрутизация сайтов `SITE_DOMAINS` (сайты на корп. серверах):

- **корп. VPN включён** — `/32`-маршрут через ppp добавляет демон
  `corp-vpn-routes.sh`, трафик остаётся внутри L2TP;
- **корп. VPN выключен** (в т.ч. корп. Wi-Fi) — сайт уходит в `direct_out`
  (открывается напрямую).

MySQL:

- соединения идут **по IP без SNI**, поэтому domain-правило их не матчит —
  нужен `ip_cidr`. Генератор резолвит `MYSQL_HOSTS` в IPv4 при каждом запуске
  и добавляет их в `ip_cidr` группы `ts-network`;
- при включённом корп. VPN ppp-маршруты демона специфичнее TUN, правило не
  применяется (трафик идёт внутри L2TP);
- на корп. Wi-Fi (без L2TP) MySQL выходит через `direct_out` с egress корп.
  сети — сервер видит корп. IP и пропускает авторизацию.

## Источник данных

Все сети описаны в `corp-networks.conf` (исходник — в репо `corp-vpn`,
устанавливается в `/usr/local/etc/corp-networks.conf`). Генератор ищет конфиг
в `/usr/local/etc`, затем в `../corp-vpn/corp-networks.conf`.

## Использование

```bash
./karing-rules.sh             # показать группы (JSON)
./karing-rules.sh --check     # сверить live-конфиг Karing с corp-networks.conf
./karing-rules.sh -i          # применить в конфиг Karing (с бэкапом)
./karing-rules.sh --singbox   # правила в формате sing-box
```

Проверка текущих правил Karing — `./karing-rules.sh --singbox`.

### `-i` и работающий Karing

Karing держит конфигурацию в памяти и перезаписывает ею
`karing_routing_group.json` при каждом сохранении, поэтому правки, сделанные
`-i` на живом приложении, пропадают без следа. Перед `-i` Karing нужно
закрыть, после — запустить обратно. `--check` ничего не меняет, только
докладывает о расхождениях (код возврата 0 — чисто, 1 — дрейф, 2 — конфиг
не прочитан) и предупреждает, если приложение запущено.

### collect-sites.py — сбор сайтов в `SITE_DOMAINS`

Проще всего брать хосты и пароли прямо из реестра Parallels SQL Admin —
секрет не появляется ни в `argv`, ни в истории:

```bash
./collect-sites.py --from-app --hosts p7ru1.tradesoft.ru --out sites-p7ru1.txt
```

`--from-app` читает `config.ini` и `servers.json` из каталога данных
приложения и расшифровывает пароли тем же Fernet-ключом из Keychain, что и
GUI. Репозиторный `servers.json` содержит только хосты с пустыми паролями,
поэтому для работы с БД нужен либо `--from-app`, либо внешний пароль.

Пароль MySQL можно также брать из macOS Keychain (не передавать в
`--password` — пароль светится в истории команд):

```bash
security add-generic-password -a koshkin -s collect-sites -w   # один раз; пароль из stdin
./collect-sites.py --password-keychain --hosts p7ru4.tradesoft.ru --out sites-p7ru4.txt
```

Порядок выбора пароля без `--from-app`: `--password` →
`--password-keychain [SERVICE]` (по умолчанию `collect-sites`) →
интерактивный ввод.

### clean-sites.py — чистка `SITE_DOMAINS` от протухших доменов

Сверяет конфиг со свежим полным сканом и показывает домены, которых
больше нет в живых БД. Работает только с текстом конфигов, MySQL не
трогает никак:

```bash
./collect-sites.py --from-app --out sites-fresh.txt   # сначала полный скан (не --hosts!)
./clean-sites.py --fresh sites-fresh.txt              # dry-run: показать протухшие
./clean-sites.py --fresh sites-fresh.txt --apply      # удалить с бэкапом .bak.*
```

Скан обязан быть полным: частичный (`--hosts`, флап MySQL-маршрутов)
даст ложные срабатывания. Предохранитель отказывается удалять больше
30% списка без `--force`. `SITE_CRITICAL`, `DOMAINS`, `MYSQL_HOSTS` и
покрытые `DOMAIN_SUFFIX` не трогаются; осознанно добавленные алиасы,
которых нет в `csSiteDomain` (напр. `www.`-варианты), держать в `--keep`:

```bash
./clean-sites.py --fresh sites-fresh.txt --keep opt-ms.com,www.opt-ms.com --apply
```

После чистки: `karing-rules.sh -i` при закрытом Karing (убрать домены из
`ts-network`), демон маршрутов сам снимет `/32` в течение цикла.

## Самопроверки

```bash
sh corp-vpn-routes.sh --selftest              # демон маршрутов, 41 проверка
sh karing-rules.sh --selftest                  # генератор и сверка дрейфа, 16
sh corp-routes-clean.sh --selftest              # очистка мёртвых маршрутов, 88
../parallels-sql-admins/.venv/bin/python \
    collect-sites.py --selftest                # фильтр доменов, 33
./clean-sites.py --selftest                    # чистка SITE_DOMAINS, 13
```

Все пять работают без root, без сети и без MySQL. `install.sh` прогоняет их
гейтом до установки: провал `corp-vpn-routes.sh` или `corp-routes-clean.sh`
оставляет прежнюю версию соответствующего демона, провал остальных прерывает
установку с `exit 1`. Проверки `karing-rules.sh --selftest` подменяют `HOME` и
`CORP_NETWORKS_CONF`, поэтому живой конфиг Karing не читается и не меняется.
`corp-routes-clean.sh --selftest` подменяет `netstat`, `route`, `ipconfig`, а
логи и состояние уводит во временный каталог: живая таблица маршрутов не
читается на запись и не меняется.

Что они ловят: разбор POINTOPOINT-маски и фильтры подсетей в демоне
маршрутов, детект дрейфа и остатков корп. элементов в сверке Karing, ошибки
разбора домена и фильтрации мусора в сборщике (`smtp.*`, `*.tradesoft.pro`,
инстансы `.tNNN`), порог протухших и защиту `SITE_CRITICAL`/`--keep` в
чистке списка, а также неверную классификацию битых маршрутов в очистке
(фантомный шлюз из fake-IP, настоящий шлюз, `utun*`, `lo0`, `default`,
границы `/15`, двухснимковый гейт).

## Восстановление на новом Mac

```bash
git clone git@github.com:alekosExclusiveVersion/corp-vpn
cd corp-vpn
sudo ./install.sh             # демон маршрутов + corp-networks.conf (split-режим)
osascript -e 'quit app "Karing"'   # -i не закрепится, пока Karing запущен
./karing-rules.sh -i          # группы Karing (ts-network / На прямую)
open -a Karing                # вернуть приложение
```

Затем в приложении Karing: добавить подписку (ссылку брать у провайдера) и
выбрать сервер. Конфиги Karing (`~/Library/Group Containers/group.com.nebula.karing`)
в репозитории не хранятся намеренно — там URL подписок с токенами доступа.

## Структура папки

| Файл | Назначение |
|---|---|
| `karing-rules.sh` | Генератор правил Karing из corp-networks.conf: группы `ts-network` (direct_out, вся корп. зона) и «На прямую» (личные правки); `--check` — сверка live-конфига с дрейфом, `--selftest` — проверки на фикстурах, `-i` — применить с бэкапом (Karing должен быть закрыт) |
| `corp-routes-clean.sh` | Демон очистки мёртвых маршрутов (сценарии A/B удаляют, сценарий C — фантомный шлюз из fake-IP — по умолчанию только наблюдает); `--selftest` — 88 проверок на фикстурах, `--check` — один проход только на чтение, `--dry-run` — без root и без удалений |
| `corp-routes-check.sh` | Детектор битых маршрутов Karing, только чтение: fake-IP в назначении и фантомный шлюз из fake-IP; `--sudo-cmd` печатает готовые команды, не выполняя их |
| `collect-sites.py` | Сбор доменов сайтов из корп. MySQL в `SITE_DOMAINS`; учётки — из реестра Parallels SQL Admin (`--from-app`) либо из Keychain (`--password-keychain`); `--clean` чистит файл на месте |
| `clean-sites.py` | Чистка `SITE_DOMAINS` от доменов, пропавших из живых БД: dry-run по умолчанию, `--apply` с бэкапом, предохранитель от частичного скана (порог 30%, `--force`), `--keep` для осознанных алиасов; MySQL не трогает; `--selftest` — 13 проверок |
| `README.md` | Документация |
