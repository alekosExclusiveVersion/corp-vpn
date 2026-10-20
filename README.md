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
| `ts-network` | `direct_out` | вся корп. зона: домены (`DOMAINS`, `SITE_DOMAINS`, `MYSQL_HOSTS`, находки learn из `corp-networks-auto.conf`), суффиксы `DOMAIN_SUFFIX`, IP (`NET_ROUTES`, `VPN_SERVERS`, MySQL) |
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

### sites-sync.sh — автоматическая актуализация списков (3 раза в день)

Юзер-агент `com.tradesoft.corp-sites-sync` (08:00/14:00/20:00 + догон
пропущенного при сне/выключенном Mac): проверка `vpn=up`, полный скан
`collect-sites.py --from-app` с ретраями до 6 попыток на хост (частичный
скан = пропуск чистки), `clean-sites.py --apply` (keep = `sites-keep.txt`
+ `corp-networks-auto.conf`), `karing-rules.sh -i` с авто-рестартом Karing
при дрейфе. Контекст пользователя обязателен (Fernet-ключ в его Keychain),
привилегии — через `~/bin/sudo` внутри скрипта.

```bash
./sites-sync.sh --dry-run    # проверка без изменений
./sites-sync.sh --force      # цикл безусловно
./sites-sync.sh --rollback   # откат конфигов на последний .bak + kickstart
./sites-sync.sh --selftest   # проверки, 11
```

Уведомления о фактическом статусе — события `sites-sync.*`, только баннер
macOS (без B24+Telegram). Лог-кольцо
`~/Library/Logs/corp-sites-sync/`, артефакты старше 30 дней удаляются
(3 последних бэкапа каждого конфига хранятся).

### karing-watch.sh — вотчер дрейфа Karing (каждые 10 мин)

Юзер-агент `com.tradesoft.corp-karing-watch` (каждые 10 мин + при логине):
`karing-rules.sh --check` без VPN-гейта, при дрейфе `quit → -i → open`
с перепроверкой. Кулдаун ресинка — 30 мин (`KWATCH_COOLDOWN`), guard
незакрывшегося Karing. Закрывает зазор sites-sync на корп. Wi-Fi без VPN
(там sites-sync не работает — нужен MySQL-скан) и доставляет в `ts-network`
находки `corp-learn` из `corp-networks-auto.conf` (генератор их тоже
учитывает — см. `CORP_NETWORKS_AUTO`).

```bash
./karing-watch.sh --check      # только сверка, без изменений
./karing-watch.sh --force      # ресинк безусловно (отладка)
./karing-watch.sh --selftest   # проверки, 31
```

События `karing-watch.ok` / `karing-watch.fail` — только баннер macOS
(без B24+Telegram, как и остальные доменные события). Попутно вотчер
следит за чистотой репо: грязь старше 48 ч (`KWATCH_DIRTY_AFTER`) даёт
баннер `repo-dirty.remind` не чаще раза в сутки (`KWATCH_REMIND_EVERY`).
Лог-кольцо `~/Library/Logs/corp-karing-watch/`.

## Самопроверки

```bash
sh corp-vpn-routes.sh --selftest              # демон маршрутов, 53 проверки
sh karing-rules.sh --selftest                  # генератор и сверка дрейфа, 19
sh corp-routes-clean.sh --selftest              # очистка мёртвых маршрутов, 96
sh corp-wifi-routes.sh --selftest               # маршруты корп. Wi-Fi, 10
sh karing-restart.sh --selftest                 # решения рестартера Karing, 8
../parallels-sql-admins/.venv/bin/python \
    collect-sites.py --selftest                # фильтр доменов, 33
./clean-sites.py --selftest                    # чистка SITE_DOMAINS, 13
./sites-sync.sh --selftest                     # цикл актуализации, 11
./karing-watch.sh --selftest                   # вотчер дрейфа Karing, 31
```

Все восемь работают без root, без сети и без MySQL. `install.sh` прогоняет их
гейтом до установки: провал `corp-vpn-routes.sh` или `corp-routes-clean.sh`
оставляет прежнюю версию соответствующего демона, провал остальных прерывает
установку с `exit 1`. Проверки `karing-rules.sh --selftest` подменяют `HOME`,
`CORP_NETWORKS_CONF` и `CORP_NETWORKS_AUTO`, поэтому живой конфиг Karing не читается и не меняется.
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
| `sites-sync.sh` | Цикл актуализации доменов (LaunchAgent 08:00/14:00/20:00 + догон): VPN-гейт, скан с ретраями, чистка, Karing `-i` с рестартом, чистка `.bak` (своих и Karing); события `sites-sync.*` — только баннер macOS; `--rollback`; `--selftest` — 11 проверок |
| `karing-watch.sh` | Вотчер дрейфа Karing (LaunchAgent каждые 10 мин + при логине): `--check` без VPN-гейта, при дрейфе `-i` с рестартом Karing (кулдаун 30 мин); напоминание о грязном репо (`repo-dirty.remind`, грязь 48ч+, повтор раз в сутки); события `karing-watch.*` — только баннер macOS; `--selftest` — 31 проверка |
| `karing-restart.sh` | Рестартер Karing (user-level, без root): `--force` — безусловно (wake-хук), `--if-dead` — только при провале внешней пробы; обновляет метку `corp-karing-watch/last-resync`, чтобы вотчер не перезапускал Karing второй раз; `--selftest` — 8 проверок |
| `corp-wifi-routes.sh` | Демон маршрутов при корп. Wi-Fi: пины `VPN_SERVERS` и `CORP_GATEWAY_HOSTS` через шлюз Wi-Fi, снятие utun-пинов Karing с публичных IP корп. доменов; по маркеру wake/разрыву тика обновляет кэш corp-IP и пины сразу; `--selftest` — 10 проверок |
| `reconnect-vpn-wake.sh` | Wake-хук (копируется в `~/.wakeup`, ставится `install.sh`): маркер пробуждения для root-демонов, фоновый рестарт Karing, подъём L2TP с guard'ами корп. Wi-Fi/LAN, повторный маркер и проверка сети 5/15/30/60с + баннер при провале; `WAKE_DRY_RUN=1` — без побочных эффектов |
| `sites-keep.txt` | Ручные исключения для чистки (осознанные алиасы вне `csSiteDomain`); устанавливается в `/usr/local/etc/sites-keep.txt` один раз, дальше не перезаписывается |
| `README.md` | Документация |
