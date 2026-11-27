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

## VPN on demand

Туннель L2TP поднимается по обращению к корп. зоне, а не постоянно:

- для каждой зоны из `DOMAIN_SUFFIX` (плюс `ONDEMAND_ZONES`) `install.sh`
  пишет `/etc/resolver/<зона>` → `127.0.0.1:5354` (зоны берёт из самого
  демона: `vpn-ondemand.py --zones` — один парсер с рантаймом);
- демон `vpn-ondemand.py` (`com.tradesoft.corp-vpn-ondemand`) принимает запрос,
  ставит маркер спроса `/tmp/corp-vpn-demand` и просит `vpn-watchdog.sh`
  поднять L2TP; после готовности корп. DNS пересылает запрос на
  `192.168.0.210`/`.220`. Не дождались за 10 с — быстрый `SERVFAIL`, клиент
  повторит запрос;
- имена самих VPN-серверов (`vpn1..4.tradesoft.ru` из профилей) и зоны из
  `ONDEMAND_BYPASS` резолвятся обычным DNS и туннель не поднимают: macOS
  резолвит адрес сервера в момент dial через тот же системный резолвер, а корп.
  DNS без туннеля недоступен (иначе `networksetup` висит в `Connecting`);
- если туннель поднять не удалось (cooldown после неудачи), публичные имена
  корп. зон (`www.tradesoft.ru` и т.п.) отдаются обычным DNS, а не `SERVFAIL`;
- останов по простою не шумит баннером: демон пишет маркер
  `/tmp/corp-vpn-idle-stop`, и `vpn.down` в Notification Center не приходит
  (ручной `stop` и обрыв — с баннером, как раньше);
- `vpn-watchdog.sh` без свежего маркера (300 с) туннель не поднимает;
- через `ONDEMAND_IDLE` (600 с) без корп. DNS-запросов, трафика на `ppp0` и
  установленных соединений в корп. подсети туннель гасится (`scutil --nc stop`);
- на корп. Wi-Fi и корп. LAN (кабель) туннель не поднимается: корп. DNS там
  отвечает напрямую (признаки — MAC en0 и ARP-MAC шлюза из
  `CORP_WIFI_EN0_MACS`/`CORP_WIFI_GATEWAY_MACS`);
- обращение по IP (RDP, MySQL) DNS-триггера не даёт — нужен ручной
  `./corp-vpn.sh start` (удержание 30 мин) или `./corp-vpn.sh demand N`;
- `CORP_ONDEMAND=0` в `corp-networks.conf` возвращает прежнее поведение
  (watchdog держит VPN постоянно).

Состояние — блок «VPN on demand» в `./corp-vpn.sh status` (слушает ли демон,
возраст маркера, остаток удержания). Лог — `/tmp/corp-vpn-ondemand.log`.

Ограничения: DoH в браузере идёт мимо системного резолвера (триггера нет);
сайты `SITE_DOMAINS` с публичным DNS тоже не дают триггера, пока их зоны не
добавлены в `ONDEMAND_ZONES`; публичные имена внутри корп. зон
(`www.tradesoft.ru`) при выключенном туннеле сначала пытаются поднять туннель
и только потом отдаются обычным DNS — если это мешает, добавь их в
`ONDEMAND_BYPASS`; без демона корп. имена не резолвятся вообще,
поэтому `install.sh` ставит резолверы только после проверки порта, а
`uninstall.sh` их убирает.

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
./clean-sites.py --fresh sites-fresh.txt              # отчёт: удалить / карантин
./clean-sites.py --fresh sites-fresh.txt --apply      # удалить с бэкапом .bak.*
./clean-sites.py --fresh sites-fresh.txt --grace 1    # старое поведение: удалять сразу
```

Скан обязан быть полным: частичный (`--hosts`, флап MySQL-маршрутов)
даст ложные срабатывания. Предохранитель отказывается удалять больше
**50%** списка без `--force` (`--threshold 0.50`).

Критерий — запись в `csSiteDomain`, а не доступность сайта: домен, у которого
сайт ещё открывается, но записи в БД больше нет (переехал, стал алиасом), тоже
уходит после карантина. Чтобы решение не было молчаливым, имена удалённых
доменов пишутся в лог (`clean --apply`) и в баннер `sites-sync.ok`; карантинные
— в лог и в баннер, когда удалять пока нечего.

Протухание с карантином: домен удаляется не после одного промаха, а после
**3 сканов подряд**, где его нет (`--grace` / `SITES_GRACE`, по умолчанию 3).
Состояние (`first_seen`/`last_seen`/`miss`) — в
`~/Library/Application Support/corp-vpn/sites-state.json` (не в git,
переопределяется `--state`/`CORP_SITES_STATE`). Отчёт печатает два списка:

```
протухшие: удалить 0, карантин 1, всего доменов 353 (grace=3, порог 50%)
  удалить: —
  карантин: kyariz.com (1/3)
```

Вернувшийся в скан домен сбрасывает счётчик. `SITE_CRITICAL`, `DOMAINS`,
`MYSQL_HOSTS` и покрытые `DOMAIN_SUFFIX` не считаются протухшими; жив базовый
домен — жив и его `www.`-вариант. Осознанные алиасы, которых нет в
`csSiteDomain` (напр. `www.`-варианты, API-хосты), держать в `--keep`:

```bash
./clean-sites.py --fresh sites-fresh.txt --keep opt-ms.com,www.opt-ms.com --apply
```

После чистки: `karing-rules.sh -i` при закрытом Karing (убрать домены из
`ts-network`), демон маршрутов сам снимет `/32` в течение цикла.

### sites-sync.sh — автоматическая актуализация списков (3 раза в день)

Юзер-агент `com.tradesoft.corp-sites-sync` (08:00/14:00/20:00 + догон
пропущенного при сне/выключенном Mac). Порядок цикла: **сначала синк
Karing** (`karing-watch.sh --sync`, без VPN-гейта), затем проверка
`vpn=up`/корп. Wi-Fi, полный скан `collect-sites.py --from-app` с ретраями
до 6 попыток на хост (частичный скан = пропуск чистки), `clean-sites.py
--apply` (keep = `sites-keep.txt` + `corp-networks-auto.conf`). Если VPN
лежит или скан пустой — правила Karing всё равно уже приведены к
`corp-networks.conf`. Контекст пользователя обязателен (Fernet-ключ в его
Keychain), привилегии — через `~/bin/sudo` внутри скрипта.

```bash
./sites-sync.sh --dry-run    # проверка без изменений
./sites-sync.sh --force      # цикл безусловно
./sites-sync.sh --report     # протухшие/карантин по последнему скану (без сети)
./sites-sync.sh --rollback   # откат конфигов на последний .bak + kickstart
./sites-sync.sh --selftest   # проверки, 11
```

`--report` не ходит в сеть и ничего не меняет: берёт последний
`~/Library/Logs/corp-sites-sync/fresh-*.txt` и печатает списки «удалить» и
«карантин» (домен с числом промахов `n/grace`). Частичный скан (есть
неопрошенные хосты после ретраев) **полностью пропускает чистку** — иначе
домены недоступных серверов выглядели бы протухшими; счётчики карантина при
этом тоже не растут. Срок карантина — `SITES_GRACE` (по умолчанию 3 скана).

Уведомления о фактическом статусе — события `sites-sync.*`, только баннер
macOS (без B24+Telegram). Лог-кольцо
`~/Library/Logs/corp-sites-sync/`, артефакты старше 30 дней удаляются
(3 последних бэкапа каждого конфига хранятся).

### karing-watch.sh — вотчер и синк правил Karing (10 мин + WatchPaths)

Юзер-агент `com.tradesoft.corp-karing-watch` (каждые 10 мин + при логине):
`karing-rules.sh --check` без VPN-гейта, при дрейфе `quit → -i → open`
с перепроверкой. Кулдаун ресинка — 30 мин (`KWATCH_COOLDOWN`), guard
незакрывшегося Karing, общий лок `/tmp/corp-karing-resync.lock`.

Второй агент `com.tradesoft.corp-karing-sync-onchange` (`WatchPaths` на
`/usr/local/etc/corp-networks.conf` и `-auto`) вызывает этот же скрипт с
`--sync`: правка конфига применяется сразу, не дожидаясь 10 минут и не
зависит от VPN/сети.

Если Karing закрыт (VPN лежит, приложение не запущено) — `-i` применяется
**без запуска** приложения, чтобы не навязывать прокси; если был запущен —
перезапускается и возвращается. Закрывает зазор sites-sync на корп. Wi-Fi
без VPN и доставляет в `ts-network` находки `corp-learn` из
`corp-networks-auto.conf` (генератор их тоже учитывает — см.
`CORP_NETWORKS_AUTO`).

```bash
./karing-watch.sh --check      # только сверка, без изменений
./karing-watch.sh --sync       # синк по дрейфу сейчас, без кулдауна
./karing-watch.sh --force      # ресинк безусловно (отладка)
./karing-watch.sh --selftest   # проверки, 35
```
```

События `karing-watch.ok` / `karing-watch.fail` — только баннер macOS
(без B24+Telegram, как и остальные доменные события). Попутно вотчер
следит за чистотой репо: грязь старше 48 ч (`KWATCH_DIRTY_AFTER`) даёт
баннер `repo-dirty.remind` не чаще раза в сутки (`KWATCH_REMIND_EVERY`).
Лог-кольцо `~/Library/Logs/corp-karing-watch/`.

## Самопроверки

```bash
sh corp-vpn-routes.sh --selftest              # демон маршрутов, 65 проверок
sh karing-rules.sh --selftest                  # генератор и сверка дрейфа, 19
sh corp-routes-clean.sh --selftest              # очистка мёртвых маршрутов, 96
sh corp-wifi-routes.sh --selftest               # маршруты корп. Wi-Fi, 10
sh karing-restart.sh --selftest                 # рестартер/fallback Karing, 12
sh reconnect-vpn-wake.sh --selftest             # выбор лечения после сна + guard «Mac спит?» + спрос, 28
/usr/bin/python3 vpn-ondemand.py --selftest     # VPN on demand: зоны, MAC, idle, bypass, кэши, 68
../parallels-sql-admins/.venv/bin/python \
    collect-sites.py --selftest                # фильтр доменов, 33
./clean-sites.py --selftest                    # чистка SITE_DOMAINS, 13
./sites-sync.sh --selftest                     # цикл актуализации, 11
./karing-watch.sh --selftest                   # вотчер дрейфа Karing, 35
```

Все проверки работают без root, без сети и без MySQL. `install.sh` прогоняет их
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
| `clean-sites.py` | Чистка `SITE_DOMAINS` от доменов, пропавших из живых БД: отчёт «удалить/карантин» по умолчанию, удаление после 3 промахов подряд (`--grace`/`SITES_GRACE`, состояние в `sites-state.json`), `--apply` с бэкапом, предохранитель от частичного скана (порог 50%, `--force`), `--keep` для осознанных алиасов; MySQL не трогает; `--selftest` — 22 проверки |
| `sites-sync.sh` | Цикл актуализации доменов (LaunchAgent 08:00/14:00/20:00 + догон): синк Karing, VPN-гейт, скан с ретраями, чистка с grace-карантином (частичный скан — чистка пропускается), Karing `-i` с рестартом, чистка `.bak` (своих и Karing); события `sites-sync.*` — только баннер macOS; `--report` — протухшие/карантин без сети; `--rollback`; `--selftest` — 11 проверок |
| `karing-watch.sh` | Вотчер дрейфа Karing (LaunchAgent каждые 10 мин + при логине): `--check` без VPN-гейта, при дрейфе `-i` с рестартом Karing (кулдаун 30 мин); напоминание о грязном репо (`repo-dirty.remind`, грязь 48ч+, повтор раз в сутки); события `karing-watch.*` — только баннер macOS; `--selftest` — 35 проверок |
| `karing-restart.sh` | Рестартер и аварийное закрытие Karing (user-level, без root): `--force` — безусловно (wake-хук), `--if-dead` — только при провале внешней пробы, `--fallback` — выйти из Karing (зависший добивается TERM/KILL, оставшийся `Connected` снимается `scutil --nc stop`) → дождаться `default` вне utun → сбросить DNS-кэш fake-IP → проверить трафик; ждёт трафик, а не статус `Connected` (норма 1–5 с, предел 8 с); при успехе обновляет `last-resync`, при провале — `last-fail` (чтобы не усыплять вотчер); `--dry-run`, `--selftest` — 12 проверок |
| `corp-wifi-routes.sh` | Демон маршрутов при корп. Wi-Fi: пины `VPN_SERVERS` и `CORP_GATEWAY_HOSTS` через шлюз Wi-Fi, снятие utun-пинов Karing с публичных IP корп. доменов; по маркеру wake/разрыву тика обновляет кэш corp-IP и пины сразу; `--selftest` — 10 проверок |
| `reconnect-vpn-wake.sh` | Wake-хук (копируется в `~/.wakeup`, ставится `install.sh`): маркер пробуждения для root-демонов, синхронный рестарт Karing с ожиданием трафика, при провале — fallback «закрыть Karing» (2 с до прямого интернета), подъём L2TP с guard'ами корп. Wi-Fi/LAN, on-demand-гейт (без спроса после сна туннель не поднимается), повторный маркер и проверка сети 3/5/7с (15 с вместо 60) с выбором лечения `choose_fix` (мертва внешняя → fallback, мертва только корп. → L2TP) и диагнозом в баннере; `WAKE_DRY_RUN=1` — без побочных эффектов, `--selftest` — 28 проверок |
| `vpn-ondemand.py` | Демон VPN on demand (`com.tradesoft.corp-vpn-ondemand`, root): слушает `127.0.0.1:5354` (UDP+TCP, параллельно), на DNS-запрос к корп. зоне ставит маркер спроса и просит watchdog поднять L2TP, пересылает запрос на корп. DNS, при простое `ONDEMAND_IDLE` гасит туннель; на корп. Wi-Fi/LAN туннель не поднимает; имена VPN-серверов и `ONDEMAND_BYPASS` резолвит обычным DNS (иначе dial зависает), публичные имена корп. зон при недоступном туннеле отдаёт обычному DNS; `--once NAME` — разбор одного запроса, `--zones` — зоны-триггеры из конфига (использует `install.sh`), `--selftest` — 68 проверок |
| `sites-keep.example.txt` | Шаблон ручных исключений для чистки (осознанные алиасы вне `csSiteDomain`); `install.sh` копирует его в `/usr/local/etc/sites-keep.txt`, только если рабочего файла ещё нет (рабочий — локальный, в `.gitignore`) |
| `README.md` | Документация |
