# Настройка корпоративного VPN + Karing на macOS (aleksei)

Документ фиксирует всю проделанную работу: проблему, архитектуру решения,
все файлы, конфигурации, команды проверки, операции и известные ограничения.
Дата: 10.08.2026. Дополнено 11.08.2026: маршрутный демон `corp-vpn-routes.sh`
и единый конфиг `corp-networks.conf` перенесены в этот репозиторий;
добавлена маршрутизация сайтов `SITE_DOMAINS` через корп. VPN;
документированы пароль из Keychain для `collect-sites.py` (п. 3.9),
root-вход через корп. egress (п. 6) и watchdog автоподключения VPN (п. 3.6).
Дополнено 14.08.2026: отдельный скрипт-дубль `fix-mysql-routes.sh` удалён —
хосты `btk66.ru`, `shop.eurotradeplus.pl` (SITE_DOMAINS) и
`eurotradeplus.tradesoft.ru` (MYSQL_HOSTS) включены в единый конфиг
`corp-networks.conf`, маршрутами управляет только демон `corp-vpn-routes.sh`.
Заодно упрощена архитектура (см. §2): слой SOCKS5-моста `socks-bridge.py`
(+ правило Karing «Корп L2TP») выведен из эксплуатации — корп. трафик идёт
напрямую по /32-маршрутам ppp0, которые демон поддерживает каждые 5 с.
Дополнено 15.08.2026: демон автодетекта `corp-learn.sh` — корп. сайты
добавляются автоматически: по PTR-записи исходящих соединений он определяет
сайты на корп. хостинге Tradesoft и **навсегда** дописывает их в строку
`SITE_DOMAINS` установленного конфига (`/usr/local/etc/corp-networks.conf`)
и его репозиторной копии (`~/corp-vpn/corp-networks.conf`). Для немедленного
применения (не дожидаясь 300-сек цикла основного демона) домен параллельно
попадает в `corp-networks-auto.conf` (AUTO_SITE_DOMAINS), который маршрутный
демон подхватывает в течение секунд. Git-коммит найденных доменов остаётся
за пользователем.
20.08.2026: добавлено автовосстановление VPN после сна через sleepwatcher (п. 3.6).

---

## 1. Проблема

Рабочий Mac (aleksei) подключён к интернету через **Karing** (TUN, узлы VLESS,
выход через 🇳🇱 Netherlands). Параллельно нужен доступ к **корпоративной сети
TradeSoft** через L2TP/IPSec VPN (`vpn1`/`vpn2-ts`/`vpn3-ts`/`vpn4`, сервер
`vpn3.tradesoft.ru`).

Возникали конфликты:
1. Подключение корпоративного VPN через System Settings **сбрасывало Karing** →
   пропадал интернет.
2. Подключение Karing могло ронять корпоративный туннель (`ppp0`).
3. Корпоративный DNS (`192.168.0.210`) и корпоративные адреса
   (10.x.x.x, 192.168.x.x, `*.tradesoft.corp`, `*.prj`, `*.tradesoft.ru`)
   не резолвились и не маршрутизировались корректно, когда Karing забирал
   default-маршрут.
4. Узел Karing по таймауту: узел Netherlands (189.74.114.x / 193.233.255.115)
   недоступен через en0/телефон в момент конфликта маршрутов.

---

## 2. Архитектура решения

```
Обычный интернет-трафик
   │
   ▼
Karing TUN (utun*, default → прокси-узел)
   │  DNS: hijack-dns → dns_proxy_out → DoH (1.1.1.1/8.8.8.8)
   ▼
Интернет работает через узел Karing

Корпоративный трафик (SITE_DOMAINS, MYSQL_HOSTS, NET_ROUTES)
   │  /32- и сетевые маршруты → ppp0 добавляет демон corp-vpn-routes.sh
   │  (проверка каждые 5с: чужой маршрут Karing удаляется и возвращается ppp)
   ▼
Корпоративный туннель ppp0 (split-режим, без OverridePrimary)
   ▼
Корпоративные ресурсы (админки сайтов, mysql, *.tradesoft.corp, 10/8, 192.168/16)
   ▼
Egress корп. туннеля: 92.255.230.89 — IP в allowlist админок (root-вход)

Локальная сеть / телефон (en0) — не трогается (LOCAL_ROUTES + автоопределение)
```

Ключевая идея: **корпоративные адреса НЕ перехватываются в sing-box/Karing** —
достаточно системных маршрутов до ppp0. Демон `corp-vpn-routes.sh` добавляет
их при подключении L2TP и каждые 5с возвращает на ppp то, что Karing успел
перебить своими TUN-пинами (`add_host_route`: удалить чужой маршрут → добавить
через ppp0).

Бывший слой SOCKS5-моста (`socks-bridge.py` 127.0.0.1:1082 + правило Karing
«Корп L2TP») **больше не используется**: правило удалено из Karing, порт не
слушается, агент `com.aleksei.corp-bridge` остановлен. Публичные корп. сайты
(btk66.ru, shop.eurotradeplus.pl, *.tradesoft.ru) идут напрямую по /32-маршрутам
ppp0, внутренние имена (*.tradesoft.corp, *.prj) резолвятся корп. DNS
192.168.0.210 через NET_ROUTES/спец-маршруты — мост не требуется.

---

## 3. Компоненты и файлы

### 3.1. Мост — `socks-bridge.py` *(устаревший компонент, не используется — см. §2)*
SOCKS5-сервер на `127.0.0.1:1082` (Python 3, только stdlib).

> Мост выведен из эксплуатации 14.08.2026: правило «Корп L2TP» удалено из
> Karing, агент `com.aleksei.corp-bridge` остановлен, порт 1082 не слушается.
> Корп. трафик идёт напрямую по /32-маршрутам ppp0 (демон §3.6). Описание
> оставлено для истории/отката.

Что делает:
- Принимает SOCKS5 (CONNECT, IPv4/домен/IPv6-адрес в атype).
- **Сам резолвит домены** через корпоративный DNS `192.168.0.210:53`
  (сырой DNS-запрос по UDP, см. `resolve_via_dns()`), чтобы не зависеть от
  цепочки DNS Karing. Таймаут 5 с.
- Проверяет живость корп. туннеля: `ifconfig ppp0` каждые 5 с
  (`corp_checker()`), условие `UP` + `inet `. Если туннель лежит — отвечает
  SOCKS-ошибкой `0x05` (rejected).
- Соединяется напрямую с корп. сервером (порт тот же, что запрошен).
- Релеит трафик в оба направления (2 потока на соединение).
- Таймаут установки соединения 30 с.
- Флаги: `--port 1082`, `--bind 127.0.0.1`, `--dns 192.168.0.210`,
  `--corp-if ppp0`.

Примечание: в `/tmp/socks-bridge.err` может лежать старый черновик с
`SyntaxError` — от предыдущей итерации, к текущему состоянию не относится.

### 3.2. Автозапуск моста *(устаревший компонент — агент остановлен, см. §3.1)* — `~/Library/LaunchAgents/com.aleksei.corp-bridge.plist`
- `Label`: `com.aleksei.corp-bridge`
- `ProgramArguments`: `/opt/homebrew/bin/python3 /Users/aleksei/bin/socks-bridge.py --port 1082 --dns 192.168.0.210`
  (`/Users/aleksei/bin/socks-bridge.py` — симлинк на файл репо)
- `RunAtLoad: true`, `KeepAlive: true` (перезапуск при падении)
- Логи: `/tmp/socks-bridge.log`, `/tmp/socks-bridge.err`
- Состояние: `launchctl list | grep corp-bridge` → PID процесса.

### 3.3. Управление корп. VPN — `corp-vpn.sh` (в репо; `~/bin/corp-vpn.sh` — симлинк)
Команды:
- `corp-vpn.sh status` — состояние: корп. туннель (по ppp0 + ping корп. шлюза
  `192.168.160.1`), мост (порт 1082), Karing, маршруты 10/192.168.
- `corp-vpn.sh start [vpn]` — CLI-подключение (`scutil --nc start`).
  **Может не сработать**: keychain PSK, туннель обычно поднимают через GUI.
- `corp-vpn.sh stop [vpn]` — отключение.
- VPN по умолчанию: `vpn3-ts` (допустимы vpn1, vpn2-ts, vpn4).

### 3.4. Конфигурация Karing
Путь: `~/Library/Group Containers/group.com.nebula.karing/`

- `service_core.json` — сгенерированный конфиг sing-box.
- `karing_setting.json`, `karing_routing_group.json`, `karing_subscribe_use.json` —
  настройки приложения (правила хранятся там и попадают в route/rules).
- Резервные копии с предыдущих итераций: `*.bak.20260809-*`.

Ключевые элементы `service_core.json`:
- **inbounds**: `tun_in` (TUN), `mixed_in_direct` (3065), `mixed_in_proxy` (3066),
  `mixed_in_rule` (3067).
- **final**: `🇳🇱 Netherlands` (все остальное — через узел).
- **DNS**: hijack-dns, серверы `udp://8.8.8.8`, `https://1.1.1.1/dns-query` и др.
- **outbounds**:
  - `Корп L2TP` = SOCKS5 `127.0.0.1:1082` (bridge)
  - `direct_out` = direct
- **route/rules** (важные, состояние на 14.08.2026):
  - Outbound `Корп L2TP` (socks5 `127.0.0.1:1082`) ещё остался в конфиге как
    мёртвый объект, но **правил, направляющих в него трафик, больше нет** —
    мост из архитектуры убран (§2).
  - `На прямую[Самостоятельная настройка]`: `.yandex.ru`, `.master.systest.php7`,
    `opencode.ai`, ip_cidr `10.0.0.0/8` + `192.168.0.0/16`, процесс `opencode.exe`
    → `direct_out`. Сайты `SITE_DOMAINS` при желании добавляет генератор
    `karing-rules.sh` (см. §3.7), но для маршрутизации это не критично: демон
    §3.6 всё равно возвращает их трафик на ppp0 каждые 5 с.

### 3.5. Корпоративный VPN (система)
- Сервисы: `vpn1`, `vpn2-ts`, `vpn3-ts`, `vpn4`; активен `vpn3-ts`.
- Сервер: `vpn3.tradesoft.ru` (109.194.204.125), авторизация `a.koshkin`,
  PSK в keychain (иногда «incorrect user shared secret found» при CLI).
- Туннель: `ppp0`, адрес Mac `192.168.160.160`, шлюз `192.168.160.1`.
- Корп. DNS: `192.168.0.210`.
- **Split-режим**: у `vpn2-ts` и `vpn3-ts` убран `IPv4.OverridePrimary`
  (применяется `install.sh` через `split_fix.swift`) — обычный интернет идёт
  мимо VPN, а корп. маршруты добавляет демон (см. 3.6).

### 3.6. Автовосстановление VPN после сна — `~/.wakeup` + sleepwatcher
L2TP VPN (`vpn3-ts`) отключается после выхода macOS из спящего режима.
Для автовосстановления используется `sleepwatcher` (homebrew).

**Компоненты:**
- `brew services start sleepwatcher` — демон, запускается при логине
- `~/.wakeup` — скрипт, вызываемый sleepwatcher при пробуждении

**Как работает `~/.wakeup`:**
1. Ждёт пока en0 получит IP (до 30 с, проверка каждые 2 с)
2. Дополнительные 5 с на стабилизацию сети
3. Если VPN уже подключён — выходит
4. Пытается подключить через `networksetup -connectpppoeservice` (до 3 попыток)
5. Между попытками: ожидание 20 с, проверка статуса, отключение перед повтором
6. Логирует результат в system log (`logger "corp-vpn: ..."`)

**Важно:** `scutil --nc start` **не работает** для L2TP VPN — используйте
`networksetup -connectpppoeservice` (проверено 20.08.2026).

**Установка (выполнено 20.08.2026):**
```bash
brew install sleepwatcher
brew services start sleepwatcher
```

**Проверка:**
```bash
log show --predicate 'message CONTAINS "corp-vpn"' --last 30m
```

### 3.6.1. Watchdog автоподключения VPN — `vpn-watchdog.sh`
Если VPN отключился в любой момент (не только после сна), watchdog
переподключает его автоматически.

**Компоненты:**
- `vpn-watchdog.sh` — скрипт проверки и переподключения
- `com.aleksei.vpn-watchdog` — LaunchAgent (каждые 60 с, `RunAtLoad: true`)

**Как работает:**
1. Проверяет статус `vpn3-ts` через `scutil --nc status`
2. Если `Connected` — выходит
3. Подключает через `networksetup -connectpppoeservice`
4. Ждёт до 20 с, проверяет результат
5. Логирует в system log

**Установка (выполнено 20.08.2026):**
```bash
launchctl load ~/Library/LaunchAgents/com.aleksei.vpn-watchdog.plist
```

**Проверка:**
```bash
launchctl list | grep vpn-watchdog
log show --predicate 'message CONTAINS "vpn-watchdog"' --last 5m
```

### 3.6.2. Демон маршрутов — `corp-vpn-routes.sh` (split-tunnel)
- LaunchDaemon `com.tradesoft.corp-vpn-routes` (root, проверяет каждые 5 с).
- Файлы: `/Library/LaunchDaemons/com.tradesoft.corp-vpn-routes.plist`,
  `/usr/local/sbin/corp-vpn-routes.sh` (устанавливаются из репо через `install.sh`).
- При подключении `vpn2-ts`/`vpn3-ts` добавляет через ppp:
  - сети `10/8`, `192.168.0/16`;
  - `/32`-маршруты к MySQL-серверам из `MYSQL_HOSTS` (резолв по DNS каждые 5 мин);
  - `/32`-маршруты к сайтам `SITE_DOMAINS` (по всем A-записям);
  - `/32`-маршруты к сайтам автодетекта `AUTO_SITE_DOMAINS` (см. п. 3.7).
- При отключении VPN маршруты удаляются (по state-файлу `/var/run/corp-vpn-routes.state`).
- Перезапуск: `sudo launchctl kickstart -k system/com.tradesoft.corp-vpn-routes`.
- **Защита локальных сетей от захвата корп. туннелем**: широкие `NET_ROUTES`
  (`10/8`, `192.168/16`) перекрывают в т.ч. домашние подсети. Демон после
  добавления корп. маршрутов переустанавливает пути до локальных сетей через
  физический интерфейс (`en0` и т.п.):
  - явный список — `LOCAL_ROUTES` в `corp-networks.conf` (CIDR, напр.
    `192.168.31.0/24`);
  - автодетект — подсети всех физических интерфейсов (`ifconfig`, туннельные
    `ppp/utun/lo/...` исключены), поэтому смена Wi-Fi/подсети тоже покрыта.
  - Снапшот путей снимается ТОЛЬКО при выключенном туннеле (иначе `route -n get`
    вернул бы ppp) в `/var/run/corp-vpn-local.state`, обновляется раз в 30 с.
  - При добавлении: `route add -net <local> -netmask <mask> -interface en0`.
  - Добавленные маршруты сносятся при отключении туннеля вместе с корп.
    маршрутами.
- Перезапуск: `sudo launchctl kickstart -k system/com.tradesoft.corp-vpn-routes`.

### 3.7. Единый конфиг — `corp-networks.conf`
- Источник: `~/Work/scripts/corp-vpn/corp-networks.conf`, устанавливается
  `install.sh` в `/usr/local/etc/corp-networks.conf`.
- Переменные: `DOMAIN_SUFFIX`, `DOMAINS`, `NET_ROUTES`, `LOCAL_ROUTES`,
  `MYSQL_HOSTS`, `SITE_DOMAINS`, `PROBE_HOSTS`.
- **Автодетект** — `corp-learn.sh` по PTR-записи исходящих соединений находит
  корп. сайты и **навсегда** дописывает их в строку `SITE_DOMAINS` конфига
  (и установленного, и репозиторной копии), а для немедленного применения —
  параллельно в `/usr/local/etc/corp-networks-auto.conf` (по одному домену на
  строку, строки `#`/пустые игнорируются). Маршрутный демон читает auto-конфиг
  вместе с основным и применяет новые домены сразу при изменении.
  Git-коммит найденных доменов — за пользователем.
- Из него берут данные оба компонента:
  - демон маршрутов (ppp-маршруты, п. 3.6.2);
  - генератор правил Karing `karing-rules.sh` (репо `tradesoft-vpn-setup`);
    конфиг ищется в `/usr/local/etc`, затем `../corp-vpn/corp-networks.conf`.

### 3.8. Установка / откат — `install.sh` / `uninstall.sh`
- `sudo ./install.sh` — копирует демоны (`corp-vpn-routes.sh`,
  `corp-learn.sh`) и конфиги, загружает LaunchDaemon'ы, применяет split-режим
  (`split_fix.swift`), проверяет результат.
- `sudo ./uninstall.sh` — останавливает и удаляет демоны, чистит маршруты,
  возвращает `OverridePrimary` (`split_restore.swift`).
- Перезапуск демона маршрутов: `sudo launchctl kickstart -k
  system/com.tradesoft.corp-vpn-routes`; демона автодетекта: `sudo launchctl
  kickstart -k system/com.tradesoft.corp-learn`.

### 3.9. Сбор сайтов — `collect-sites.py` и пароль из Keychain
`collect-sites.py` (репо `tradesoft-vpn-setup`) собирает домены сайтов из корп.
MySQL-серверов (реестр `servers.json` приложения `parallels-sql-admins`;
запускать через его venv) и подставляет результат в `SITE_DOMAINS`
файла `corp-networks.conf`.

Пароль MySQL берётся по приоритету:
1. `--password '***'` — устаревший способ (пароль светится в истории команд);
2. `--password-keychain [SERVICE]` — из macOS Keychain (generic password).
   `SERVICE` по умолчанию `collect-sites`, учётка — `--user` (по умолчанию
   `koshkin`). Пароль читается через `security find-generic-password` и
   никогда не печатается/не логируется;
3. интерактивный `getpass` — если не задано ни то, ни другое.

Настройка Keychain (один раз, в своём терминале; пароль читается из stdin):
```bash
security add-generic-password -a koshkin -s collect-sites -w
```
Первый запуск `--password-keychain` может показать системный диалог
«разрешить доступ» — подтвердить. Если элемент отсутствует — выводится
подсказка с командой настройки.

Пример:
```bash
~/Work/scripts/parallels-sql-admins/.venv/bin/python collect-sites.py \
  --password-keychain --hosts p7ru4.tradesoft.ru --out sites-p7ru4.txt
```

Безопасность: ключом управляет macOS Keychain, отдельного файла с ключом на
диске нет (в отличие от Fernet-механизма `servers.key` приложения) — пароль
защищён ключницей, а не только правами на файл.

---

## 4. Итоговая таблица маршрутов

```
default            utun*              UCSg       utun6    ← Karing (интернет)
default            172.25.125.111     UGScIg     en0      ← телефон/локальная сеть
10                  ppp0               USc       ppp0     ← корпоративная сеть (демон)
192.168.0/16        ppp0               USc       ppp0     ← корпоративная сеть (демон)
185.137.232.115      ppp0               HSc       ppp0     ← btk66.ru (демон, /32)
116.202.228.248      ppp0               HSc       ppp0     ← eurotradeplus / mysql (демон, /32)
```
Интернет уходит через Karing TUN (высший приоритет); корп. подсети и /32-хосты
сайтов/MySQL — через ppp0, их держит демон §3.6. `default → ppp0` отсутствует
(split-режим). Номер utun плавающий (utun4/utun6/utun7) — не привязываться.

---

## 5. Проверки (зелёные на 14.08.2026)

| Проверка | Команда | Результат |
|---|---|---|
| Интернет через TUN | `curl -s --max-time 12 https://api.ipify.org` | IP узла Karing |
| Маршруты на ppp | `route -n get 185.137.232.115 \| grep interface` | `ppp0` |
| Админка btk66 (root-вход) | `curl --interface 192.168.160.160 -L https://www.btk66.ru/admin/` | 200/302 |
| MySQL eurotradeplus | `nc -z -w 3 116.202.228.248 3306` | ok |
| Корп. egress | `curl --interface 192.168.160.160 https://ifconfig.me` | корп. IP `92.255.230.89` |
| Демон жив | `sudo launchctl print system/com.tradesoft.corp-vpn-routes \| grep 'state = '` | running |
| Корп. DNS резолвит | `dig @192.168.0.210 sup5.tradesoft.corp` | A-запись |

---

## 6. Известные ограничения / нюансы

1. **Split-режим** корп. VPN: `OverridePrimary` у `vpn2-ts`/`vpn3-ts` убран
   (демон маршрутов добавляет только корп. сети, п. 3.6). Если галку
   «Отправлять весь трафик» случайно вернули в System Settings — повторно
   запустить `sudo ./install.sh`.
 2. **CLI-подключение корп. VPN** (`scutil --nc start`) не работает для L2TP —
    проверено 11.08.2026 и подтверждено 20.08.2026. Причина: keychain PSK после
    пересоздания элементов лежит в System.keychain, а NE-стек (pppd/racoon) при
    запуске через `scutil` не может его прочитать и отдаёт «incorrect user shared
    secret found». **Обходное решение**: `networksetup -connectpppoeservice "vpn3-ts"`
    работает (используется в `~/.wakeup` для автовосстановления после сна).
    Подключать VPN можно через System Settings или через `networksetup`. Порядок подключения: сначала корп. VPN (GUI), затем Karing; либо
    Karing, затем корп. VPN — если Karing упал, переподключить его.
3. ~~**Мост резолвит через корп. DNS**~~ — устарело (мост выведен, §3.1).
   Внутренние имена `*.tradesoft.corp` доступны только при поднятом туннеле
   (маршруты → ppp0, корп. DNS 192.168.0.210).
4. **Узел Karing и en0**: узел NL соединяется через en0 (auto_detect_interface).
   Если телефон/локальная сеть теряет интернет — Karing-узел недоступен.
5. ~~Мост слушает только `127.0.0.1`~~ — устарело (мост выведен, §3.1).
6. **Root-вход в админки сайтов (`systradesoft`) работает только при
   подключённом корп. VPN** — авторизация завязана на source-IP. Трафик к
   сайтам (`activauto.ru`, `amry.ru`, `btk66.ru`, `shop.eurotradeplus.pl` и др.)
   при включённом `vpn2-ts`/`vpn3-ts`
   идёт через `/32`-маршруты → `ppp0` → корп. egress `92.255.230.89`
   (ER-Telecom/DOM.RU), который в allowlist — вход проходит. Без VPN сайт видит
   домашний IP (напр. Tele2 `94.77.36.66`) — root-вход отклоняется, при этом
   страницы `/admin/login/` публично доступны. Split-horizon DNS нет: корп. DNS
   отдаёт те же публичные IP, что и публичный. Как проверить, какой IP видит
   сервер: `curl --interface <ppp-IP> https://ifconfig.me` (через туннель)
   против `curl https://ifconfig.me` (общий egress). Трафик сайтов не уходит
   в прокси-нод (что дало бы IP нода вместо корп. и сломало allowlist):
   маршруты до сайтов держит демон (§3.6) — он каждые 5 с возвращает на ppp0
   то, что Karing перебил TUN-пинами.
7. **Автоподключение VPN по корп. трафику (watchdog)** работает по IP-целям:
   любой TCP-сокет к корп. IP (в т.ч. публичные корп. сайты) поднимает туннель
   с задержкой ~10 с (цикл 5 с + коннект). Внутренние имена
   (`sup5.tradesoft.corp`, `projects.prj`) не могут быть триггером — DNS не
   резолвится без туннеля; они доступны уже после того, как туннель поднят по
   любому IP-триггеру. Если `scutil --nc start` под root падает с
   «incorrect user shared secret found» — автоподъём невозможен, VPN поднимается
   вручную через System Settings или `networksetup -connectpppoeservice`.
8. **Автовосстановление VPN после сна**: `sleepwatcher` + `~/.wakeup` —
   автоматически переподключает `vpn3-ts` после пробуждения (п. 3.6).
   Watchdog `vpn-watchdog.sh` (п. 3.6.1) проверяет VPN каждые 60 с и
   переподключает при отключении. Используется
   `networksetup -connectpppoeservice` вместо `scutil --nc start`.
9. **Баг Karing автообновления (1.2.22 → 1.2.23)**: автообновитель скачивает
   DMG, но не может установить — `xattr -c` падает с `Operation not permitted`
   (macOS sandbox). Karing молча остаётся на старой версии. Обход: вручную
   `xattr -d com.apple.quarantine <dmg>`, смонтировать, скопировать в
   `/Applications`. Проверено 20.08.2026.

---

## 7. Операции

- **Включить всё**: 1) корп. VPN через System Settings (или
  `~/Work/scripts/corp-vpn/corp-vpn.sh start`), 2) включить Karing,
  3) маршруты до корп. ресурсов автоматически добавит демон (§3.6), проверить
  `route -n get 185.137.232.115 | grep interface` → `ppp0`.
- **Статус**: `~/Work/scripts/corp-vpn/corp-vpn.sh status`.
- ~~**Перезапуск моста**~~ (устарело — мост выведен, §3.1):
  `launchctl unload ~/Library/LaunchAgents/com.aleksei.corp-bridge.plist &&
   launchctl load ~/Library/LaunchAgents/com.aleksei.corp-bridge.plist`
- **Перезапуск sleepwatcher**:
  `brew services restart sleepwatcher`
- **Перезапуск watchdog VPN**:
  `launchctl unload ~/Library/LaunchAgents/com.aleksei.vpn-watchdog.plist &&
   launchctl load ~/Library/LaunchAgents/com.aleksei.vpn-watchdog.plist`
- **Логи**: Karing — `…/group.com.nebula.karing/service_core.log`, `app.log`;
  демон маршрутов — `journal`/`launchctl print` (§3.6);
  VPN reconnect/watchdog — `log show --predicate 'message CONTAINS "corp-vpn"'`.

---

## 8. Откат (если понадобится)

- Мост уже выведен (14.08.2026): агент `com.aleksei.corp-bridge` остановлен,
  правило «Корп L2TP» из Karing удалено. Полный откат (если понадобится):
  `launchctl load ~/Library/LaunchAgents/com.aleksei.corp-bridge.plist` и
  вернуть `socks-bridge.py` в репо.
- Полный откат демона маршрутов: `sudo ./uninstall.sh` (удаляет LaunchDaemon,
  чистит маршруты, возвращает `OverridePrimary`).
- Вернуть правило Karing в исходное состояние: в приложении Karing
  (Настройки → Правила) удалить правила «Корп L2TP» и «На прямую», или
  восстановить `karing_routing_group.json.bak.20260809-*` и
  `karing_subscribe_use.json.bak.20260809-*`.
- Системные маршруты `10/8`, `192.168.0/16 → ppp0` ставятся самим VPN-сервером
  и исчезают при отключении туннеля.
