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
  и его репозиторной копии (`~/Work/scripts/corp-vpn/corp-networks.conf`). Для немедленного
применения (не дожидаясь 300-сек цикла основного демона) домен параллельно
попадает в `corp-networks-auto.conf` (AUTO_SITE_DOMAINS), который маршрутный
демон подхватывает в течение секунд. Git-коммит найденных доменов остаётся
за пользователем.
20.08.2026: добавлено автовосстановление VPN после сна через sleepwatcher (п. 3.6).
27.08.2026: найден и устранён корень провала корп. VPN на корп. Wi-Fi — публичные
IP L2TP/IPSec серверов уходили в нод-туннель Karing (не было в direct-группе),
теперь `VPN_SERVERS` закрепляются в Karing-direct (`karing-rules.sh`, репо
`karing-rules.sh`) и `/32 → en0` (`corp-wifi-routes.sh`); корп. DNS
`DNS_HOSTS` закрепляется `/32 → ppp0` (см. §3.7). Watchdog `vpn-watchdog.sh`
переведён на рабочий метод `networksetup -connectpppoeservice` (scutil для L2TP
не подключает) и проверен end-to-end через LaunchDaemon.
07.09.2026: корп. домены (`*.tradesoft.corp`, `*.prj`, `*.tradesoft.ru`) добавлены в
правило Karing «На прямую» — доступ к корп. ресурсам через корп. WiFi без L2TP и
без файла `/etc/hosts` (см. §3.4, §6.10). Из `corp-wifi-routes.sh` убран hosts-пин
`b24.tradesoft.ru` в `/etc/hosts` (заменён Karing-direct, §3.8.1).
22.09.2026: MySQL-хосты `MYSQL_HOSTS` добавлены в `ip_cidr` Karing-группы
«На прямую» (`karing-rules.sh`, репо `corp-vpn`) — на корп. WiFi без
L2TP их трафик идёт в direct_out (иначе нод Karing, MySQL отвергает авторизацию
по external IP); см. §3.4.
23.09.2026: устранён сбой авторизации админки partpro.ru на корп. VPN:
`corp-vpn-routes.sh` (`sweep_corp_hijacks`) теперь снимает utun-/32 Karing не
только с адресов `NET_ROUTES` (10/8, 192.168/16), но и с любого публичного IP
из `STATE` (корп. домены вроде 95.143.188.62) — иначе Karing перебивал их на
utun6, выбор интерфейса флапал между ppp0/utun6 и ломалась авторизация; см. §3.8.
В `corp-wifi-routes.sh` добавлен аналогичный sweep utun-пинов с публичных IP
корп. доменов (`SITE_DOMAINS`/`SITE_CRITICAL`/`MYSQL_HOSTS`, кэш IP в
`/var/run/corp-wifi-corp-ip.state`, refresh 300 c, sweep каждый цикл 30 c) —
страховка на случай, если Karing перехватит корп. публичные IP после сна до
подхвата правила «На прямую» (на корп. WiFi основной контроль — сам Karing-direct).

---

## 1. Проблема

Рабочий Mac (aleksei) подключён к интернету через **Karing** (TUN, узлы VLESS,
выход через 🇳🇱 Netherlands). Параллельно нужен доступ к **корпоративной сети
TradeSoft** через L2TP/IPSec VPN (`vpn1-ts`/`vpn2-ts`/`vpn3-ts`/`vpn4-ts`, сервер
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
«Корп L2TP») **больше не используется** и удалён из launchd: правило убрано из
Karing, порт не слушается, демон `com.aleksei.corp-bridge` выгружен (§3.1).
Публичные корп. сайты
(btk66.ru, shop.eurotradeplus.pl, *.tradesoft.ru) идут напрямую по /32-маршрутам
ppp0, внутренние имена (*.tradesoft.corp, *.prj) резолвятся корп. DNS
192.168.0.210 через NET_ROUTES/спец-маршруты — мост не требуется.

Отдельный уровень — **public IP VPN-серверов** (§3.7.1): они закрепляются в
direct-группу Karing и `/32 → en0`, чтобы IPSec (UDP 500/4500, ESP) не уходил
в нод-туннель и корп VPN поднимался даже на изолированной корп. Wi-Fi.

---

## 3. Компоненты и файлы

### 3.1. Мост — `socks-bridge.py` *(устаревший компонент, не используется — см. §2)*
SOCKS5-сервер на `127.0.0.1:1082` (Python 3, только stdlib).

> Мост выведен из эксплуатации 14.08.2026 и полностью удалён из launchd
> 27.08.2026: правило «Корп L2TP» удалено из Karing, порт 1082 не слушается,
> демон `com.aleksei.corp-bridge` выгружен из обоих доменов (system и gui —
> job был в gui). Файл `com.aleksei.corp-bridge.plist` сохранён в репо
> (`~/Library/LaunchAgents/...` тоже есть) для отката.
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

### 3.3. Управление корп. VPN — `corp-vpn.sh`
Канонический репозиторий — `~/Work/scripts/corp-vpn` (на него указывают все
пути ниже). Симлинки `~/bin/corp-vpn.sh` и `~/bin/socks-bridge.py` ведут на
него. Рантайм-копии демонов — строго `/usr/local/sbin` (грузит `install.sh`).

Команды:
- `~/Work/scripts/corp-vpn/corp-vpn.sh status` — состояние: корп. туннель
  (по ppp0 + ping корп. шлюза `192.168.160.1`), мост (порт 1082 — устаревший
  компонент), Karing, маршруты 10/192.168.
- `~/Work/scripts/corp-vpn/corp-vpn.sh start [vpn]` — CLI-подключение
  (`scutil --nc start`). **Может не сработать**: keychain PSK; для L2TP
  работает `networksetup -connectpppoeservice` (см. §6 п. 2).
- `~/Work/scripts/corp-vpn/corp-vpn.sh stop [vpn]` — отключение.
- VPN по умолчанию: `vpn3-ts` (допустимы vpn1-ts, vpn2-ts, vpn4-ts).

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
- **route/rules** (важные, состояние на 07.09.2026):
  - Outbound `Корп L2TP` (socks5 `127.0.0.1:1082`) ещё остался в конфиге как
    мёртвый объект, но **правил, направляющих в него трафик, больше нет** —
    мост из архитектуры убран (§2).
  - `На прямую` (direct_out): `.yandex.ru`, `.master.systest.php7`,
    `opencode.ai`, процесс `opencode.exe`, ip_cidr `10.0.0.0/8` +
    `192.168.0.0/16` + public IP `VPN_SERVERS` + public IP `MYSQL_HOSTS`
    (добавляет `karing-rules.sh` §3.7) → `direct_out`. Сайты `SITE_DOMAINS`
    при желании добавляет генератор `karing-rules.sh` (см. §3.7), но для
    маршрутизации это не критично: демон §3.6 всё равно возвращает их трафик
    на ppp0 каждые 5 с.
- **Добавлено 07.09.2026 (доступ через корп. WiFi без L2TP и /etc/hosts)**:
  в правило `На прямую[Самостоятельная настройка]` внесены корп. домены
  (правки в `karing_routing_group.json`, после перезапуска Karing):
  - `domain_suffix`: `.tradesoft.ru`, `.tradesoft.pro`, `.tradesoft.corp`, `.prj`;
  - `domain`: `sup5.tradesoft.corp`, `www.projects.prj`, `projects.prj`,
    `servicedesk-report.office.tradesoft.ru`, `b24.tradesoft.ru`.
Механика: Karing перехватывает DNS (hijack-dns) и возвращает для этих доменов
  fake-IP (зона `198.20.0.0/24`); при соединении sing-box восстанавливает домен
  из правила и отправляет трафик через `direct_out` (не в прокси-узел). DNS для
  direct-доменов резолвится `local`/`dhcp://auto` — берёт DNS из настроек Wi-Fi,
  где первым стоит корп. `192.168.0.210`. С поднятым L2TP-туннелем не
  конфликтует: демон §3.6 всё равно возвращает корп. маршруты на ppp0.

**ВАЖНО (проверено 09.09.2026):** живым источником правил является внутр. хранилище
  приложения — `karing_routing_group.json` и `service_core.json` перегенерируются
  Karing из него при каждом переподключении, ручные правки этих файлов на диске
  **затираются** (внесённый `domain_suffix` пропал после reconnect). Правильный
  путь — правка через UI Karing (то, что делается в группе «На прямую») либо
  генератор `karing-rules.sh -i` (пишет в `karing_routing_group.json`, см. §3.7);
  правки UI сохраняются и применяются при переподключении TUN.

**Уточнение 22.09.2026 (MySQL через корп. WiFi):** MySQL-соединения идут **по
  IP без SNI** (TCP/3306, не TLS), поэтому доменное правило (`domain`) их не
  матчит — sing-box видит только destination IP и без `ip_cidr` уводит трафик
  в прокси-узел, где MySQL-сервер видит external IP нода и отвергает
  авторизацию. На корп. WiFi (L2TP не поднимается, демон §3.6 не может
  вернуть /32 через ppp0) это ломает подключения `Parallels SQL Admins`.
  Решение: `karing-rules.sh` резолвит `MYSQL_HOSTS` в IPv4 (при каждом
  запуске) и добавляет их в `ip_cidr` группы «На прямую» → трафик уходит в
  `direct_out` с egress корп. сети. При поднятом L2TP ppp-маршруты демона
  специфичнее, правило не конфликтует.

**Уточнение 18.09.2026 (на полном рестарте Karing, не только reconnect):**
  переживают перезапись только правки **групп** в `karing_routing_group.json`
  (домены группы «🌏 GFW» сохранились) и `perapp.enable` в `karing_setting.json`.
  Затираются: `dns.static_ips`/`dns.hosts` в обоих json и весь список-диверсия
  `karing_subscribe_use.json` (кроме `select_default`). Полный рестарт =
  `pkill` Karing + `scutil --nc stop "Karing (system)"` + `open -a Karing`; рестарт
  только через `scutil --nc stop/start` конфиг не перечитывает. Ядро sing-box
  работает внутри системного расширения `com.nebula.karing.karingServiceSE` —
  перезапустить его отдельно нельзя. Подробности — §9.9.

### 3.5. Корпоративный VPN (система)
- Сервисы: `vpn1-ts`, `vpn2-ts`, `vpn3-ts`, `vpn4-ts`; активен `vpn3-ts`.
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
- `vpn-watchdog.sh` — скрипт проверки и переподключения (root)
- `com.tradesoft.corp-vpn-watchdog` — **LaunchDaemon** (каждые 30 с,
  `RunAtLoad: true`), файл `/Library/LaunchDaemons/com.tradesoft.corp-vpn-watchdog.plist`

**Как работает:**
1. Замок на `mkdir /tmp/corp-vpn-watchdog.lock` (протухший через 3 мин
   автоочищается) — защита от параллельных запусков.
2. **Корп. Wi-Fi guard (добавлено 04.09.2026):** если `en0` в `192.168.128.0/24`,
   гаснет любой числящийся `Connected` профиль и watchdog **не поднимает VPN**
   (лог `on corp Wi-Fi — VPN auto-connect skipped`). На корп. Wi-Fi сеть глушит
   L2TP-в-ESP, туннель там всё равно не завершается — см. §3.7.1, поэтому
   поднимать его бессмысленно (корп. ресурсы на этой сети доступны напрямую
   через правило Karing «На прямую», §3.4).
3. Проверяет статус профилей через `scutil --nc status` в порядке
   приоритета `vpn3-ts → vpn4-ts → vpn2-ts`. Если хоть один `Connected` — выходит.
4. Иначе поднимает по приоритету через **`networksetup -connectpppoeservice`**
   (рабочий метод для L2TP; `scutil --nc start` для L2TP не работает —
   keychain PSK, см. §6).
5. Ждёт до 20 с, проверяет результат, при неуспехе отменяет и пробует следующий.
6. Логирует в system log (`logger "corp-vpn: ..."`).

**Важно:** подключать корп. L2TP через `scutil --nc start` нельзя — метод
`networksetup -connectpppoeservice` (проверено 27.08.2026).

**Установка (выполнено 27.08.2026 через `install.sh`):**
```bash
sudo ./install.sh
```

**Проверка:**
```bash
sudo launchctl print system/com.tradesoft.corp-vpn-watchdog
log show --predicate 'eventMessage CONTAINS "corp-vpn"' --last 5m
```

### 3.6.2. Демон маршрутов — `corp-vpn-routes.sh` (split-tunnel)
- LaunchDaemon `com.tradesoft.corp-vpn-routes` (root, проверяет каждые 5 с).
- Файлы: `/Library/LaunchDaemons/com.tradesoft.corp-vpn-routes.plist`,
  `/usr/local/sbin/corp-vpn-routes.sh` (устанавливаются из репо через `install.sh`).
- При подключении `vpn2-ts`/`vpn3-ts` добавляет через ppp:
  - сети `10/8`, `192.168.0/16`;
  - `/32`-маршруты к MySQL-серверам из `MYSQL_HOSTS` (резолв по DNS каждые 5 мин);
  - `/32`-маршруты к сайтам `SITE_DOMAINS` (по всем A-записям);
  - `/32`-маршруты к сайтам автодетекта `AUTO_SITE_DOMAINS` (см. п. 3.7);
  - `/32`-маршруты к корп. DNS из `DNS_HOSTS` (`192.168.0.210 192.168.0.220`)
    — чтобы корп. резолвинг `*.tradesoft.corp` шёл через `ppp0`, а не
    перехватывался Karing/en0, когда туннель поднят (фикс 27.08.2026).
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
  `MYSQL_HOSTS`, `SITE_DOMAINS`, `PROBE_HOSTS`, `DNS_HOSTS`, `VPN_SERVERS`.
- `SITE_DOMAINS` — сайты на корп. серверах, идут через ppp (см. 3.6.2) и
  добавляются `karing-rules.sh` в direct-группу «На прямую». 09.09.2026 добавлены
  `parts-catalogs.com parts-index.com` (каталоги автозапчастей: реальный трафик
  идёт на `.parts-catalogs.com`, см. §9.8).
- `DNS_HOSTS` — корп. DNS-серверы (`192.168.0.210 192.168.0.220`). Закрепляются
  `/32`-маршрутами через `ppp0` демоном `corp-vpn-routes.sh` (см. 3.6.2), чтобы
  корп. резолвинг не перехватывал Karing/en0, когда туннель поднят.
- `VPN_SERVERS` — публичные IP L2TP/IPSec серверов
  (`109.194.204.122 178.141.80.30 109.194.204.125`). Демон `corp-wifi-routes.sh`
  добавляет `/32`-маршруты через `en0` на корп. Wi-Fi (см. 3.8.1), а
  `karing-rules.sh` добавляет их в direct-группу Karing «На прямую» (см. 3.7.1),
  чтобы IPSec-пакеты не уходили в нод-туннель.
- `MYSQL_HOSTS` — MySQL-серверы корп. инфраструктуры. Демон (см. 3.6.2)
  закрепляет их `/32`-маршрутами через `ppp0` при поднятом L2TP; `karing-rules.sh`
  резолвит их в IPv4 и добавляет в `ip_cidr` direct-группы «На прямую» — на
  корп. Wi-Fi (без L2TP) их трафик идёт в `direct_out` (см. §3.4), иначе MySQL
  уходит в нод Karing и сервер отвергает авторизацию по external IP.
- **Автодетект** — `corp-learn.sh` по PTR-записи исходящих соединений находит
  корп. сайты и **навсегда** дописывает их в строку `SITE_DOMAINS` конфига
  (и установленного, и репозиторной копии), а для немедленного применения —
  параллельно в `/usr/local/etc/corp-networks-auto.conf` (по одному домену на
  строку, строки `#`/пустые игнорируются). Маршрутный демон читает auto-конфиг
  вместе с основным и применяет новые домены сразу при изменении.
  Git-коммит найденных доменов — за пользователем.
- Источник данных для всех компонентов:
  - демон маршрутов (ppp-маршруты, п. 3.6.2);
  - демон корп. Wi-Fi `corp-wifi-routes.sh` (маршруты через en0, п. 3.8.1;
    читает `VPN_SERVERS`);
  - генератор правил Karing `karing-rules.sh` (репо `corp-vpn`);
    конфиг ищется в `/usr/local/etc`, затем `../corp-vpn/corp-networks.conf`.

### 3.7.1. Маршрутизация VPN-серверов (корп VPN на изолированной Wi-Fi)
**Симптом (исправлено 27.08.2026):** на корп. Wi-Fi (`192.168.128.0/24`)
корп. VPN не поднимался ни одним методом (`scutil --nc start` или
`networksetup -connectpppoeservice`) — «не удалось поднять ни один сервис».
Все последствия были списаны на нерабочий CLI, но настоящая причина — маршрут.

**Корень:** публичные IP L2TP/IPSec серверов (`109.194.204.122/.125`,
`178.141.80.30`) не входили в NET_ROUTES (`10/8`, `192.168/16`) и не были в
direct-группе Karing, поэтому Karing забирал их `/32 → utun11` (в нод-туннель).
IPSec-трафик (UDP 500/4500, ESP) через нод не проходит → handshake падает,
VPN не устанавливается. Метод подключения тут ни при чём.

**Решение (два уровня, оба определяются `VPN_SERVERS` в конфиге):**
1. **Karing direct** — `karing-rules.sh` (репо `corp-vpn`) добавляет
   `VPN_SERVERS` в `ip_cidr` группы «На прямую» (direct_out). После применения
   (`./karing-rules.sh -i`) и reload'а Karing его IPSec-пакеты выпускаются
   напрямую через `en0`, а не в нод. Это устраняет гонку маршрутов.
2. **OS-маршрут** — `corp-wifi-routes.sh` на корп. Wi-Fi при отсутствии `ppp0`
   держит `/32 → default-шлюз` для `VPN_SERVERS` (см. 3.8.1).

**Важно (исправлено 04.09.2026):** маршрут до VPN-серверов добавляется **через
шлюз**, а НЕ через `-interface en0`. Публичный IP не лежит на локальном линке
`192.168.128.0/24`, поэтому on-link (`-interface en0`) создавал мёртвый `/32` с
пустым ARP → пакеты IKE гасли на хосте (100% loss) и fail-сообщение
«L2TP: incorrect user shared secret found» при работающей сети. После перевода
на `-gateway 192.168.128.1` IKE/ESP-хендшейк проходит, но L2TP-в-ESP на корп.
Wi-Fi всё равно блокируется сетью (см. §3.6.1).

**Проверка после фикса:** при выключенном туннеле `route -n get 109.194.204.125`
даёт `gateway: 192.168.128.1 / interface: en0`, и `networksetup -connectpppoeservice "vpn3-ts"`
успешно поднимает IKE+IPsec (Phase 1/2 established), но PPP-over-L2TP на корп.
Wi-Fi не завершается (сеть глушит L2TP-в-ESP). На других сетях VPN поднимается
полностью.

### 3.8.1. Демон маршрутизации при корп. Wi-Fi — `corp-wifi-routes.sh`
- LaunchDaemon `com.tradesoft.corp-wifi-routes` (root, проверяет каждые 10–30 с).
- Файлы: `/Library/LaunchDaemons/com.tradesoft.corp-wifi-routes.plist`,
  `/usr/local/sbin/corp-wifi-routes.sh` (копируется из репо `install.sh`).
  Источник: `~/Work/scripts/corp-vpn/corp-wifi-routes.sh`.
- **Проблема**: при подключении к корп. Wi-Fi (`192.168.128.0/24`) Karing
  перехватывает DNS и возвращает fake-node IP (`198.20.x.x`) вместо реальных
  корп. IP, а виртуальные адреса корп. хостов, лежащих в той же `/24`, шлются
  on-link на ARP-proxy шлюза и гаснут. Результат (08.09.2026): HTTP 000 на
  `sup5:4000` и `www.projects.prj`.
- **Решение**: демон определяет корп. Wi-Fi по IP `en0` (`192.168.128.x`),
  проверяет, что VPN не активен (`ppp0` отсутствует), и держит маршруты:
  1. **VPN-серверы** (`VPN_SERVERS`) `/32 → default-шлюз` — иначе Karing забирает
     их в `utun11` и корп VPN не поднимается (подробнее §3.7.1). Маршрут через
     шлюз, а не on-link-интерфейс.
   2. **Корп. серверы в той же `/24`, что Wi-Fi** (`CORP_GATEWAY_HOSTS`),
      `sup5 = 192.168.128.123`) `/32 → шлюз` (`192.168.128.1`) — macOS шлёт их
      on-link напрямую на ARP-proxy (`b6:be:c:d5:9a:24`) и пакеты гаснут (000);
      реальный путь только через шлюз.
   3. **Sweep utun-пинов с публичных IP корп. доменов** (с 23.09.2026):
      Karing после сна/переинициализации может перехватить корп. публичные IP
      (`SITE_DOMAINS`/`SITE_CRITICAL`/`MYSQL_HOSTS`, например partpro.ru
      `95.143.188.62`) в utun-/32, пока правило «На прямую» ещё не подхватило.
      Демон резолвит эти домены через корп. DNS (`resolve_corp_dns`) в кэш
      `/var/run/corp-wifi-corp-ip.state` (refresh 300 с, только публичные IP,
      внутренние 10/8 и 192.168/16 исключены) и каждый цикл (30 с)
      `route -n delete -host` снимает utun-/32 для этих адресов — трафик сразу
      идёт по default `en0`. Внимание: на корп. Wi-Fi у macOS есть **две**
      default-записи (`via utun6` Karing и `via en0`), Karing-овая первая, поэтому
      без узла direct в Karing сам sweep не гарантирует direct — основной контроль
      доступности корп. сайтов по-прежнему Karing-direct (§3.4); sweep — страховка
      от флапания интерфейса и наследия старых пинов.
- **Корп. DNS НЕ пинуется** (`192.168.0.210`, 08.09.2026): пин `/32 → en0`
  (on-link через ARP-proxy `b6:be:c:d5:9a:24`) не доставлялся (ping 100% loss,
  dig timeout) и ломал fake-IP DNS-резолв Karing → `aprice72 → HTTP 000`.
  Корп DNS ходит через Karing-direct (utun4, первый корп. DNS в настройках Wi-Fi).
- Добавляет ТОЛЬКО внутренние корп. IP (10.x.x.x, 192.168.x.x) — внешние IP
  (Karing nodes 198.20.x.x) пропускаются. Все добавленные IP пишутся в
  `/var/run/corp-wifi-routes.state` и чистятся из таблицы после удаления.
- **split-DNS для корп-ресурсов (актуально с 07.09.2026)**: hosts-пин
  `b24.tradesoft.ru → 192.168.0.33` в `/etc/hosts` **удалён из демона**. Доступ
  к корп. ресурсам на корп. Wi-Fi обеспечивает правило Karing «На прямую»
  (см. §3.4): DNS резолвится через `local`/`dhcp://auto` (корп. DNS
  `192.168.0.210` из настроек Wi-Fi первым), трафик уходит в `direct_out`.
  Демон пинует только VPN_SERVERS и CORP_GATEWAY_HOSTS (sup5) через шлюз —
  корп. DNS/серверы из `192.168.0.0/16` к `en0` НЕ привязываются (см. выше).
  Ранний вариант (04.09.2026) с
  маркер-блоком
  `# >>> corp-wifi hosts (auto) <<<` / `# <<< corp-wifi hosts (auto) >>>`
  и записью `192.168.0.33 b24.tradesoft.ru` в `/etc/hosts` **выведен** —
  он больше не нужен (см. §6.10).
- **Особенность**: корп. Wi-Fi (`192.168.128.0/24`) — изолированная сеть:
  не все `192.168.0.0/16` и `10.0.0.0/8` маршрутизируются её шлюзом, а
  L2TP/IPSec VPN на ней не поднимается (сеть глушит L2TP-в-ESP — §3.6.1).
  Доступ к конкретным корп. ресурсам (`sup5`, `b24`, `projects.prj`) даёт
  правило Karing «На прямую» (§3.4) — sing-box резолвит их через корп. DNS
  из настроек Wi-Fi и ходит в `direct_out`. Демон лишь перебивает `/32`-маршруты.
  Для других корп. IP (`10.x`, `192.168.0.x`) нужен L2TP — на другой сети.
- **При подключении VPN**: демон удаляет свои маршруты через `en0`,
  чтобы не конфликтовали с `ppp0` (corp-vpn-routes.sh берёт управление).
- Логи: `/var/log/corp-wifi-routes.log`, состояние: `/var/run/corp-wifi-routes.state`.
- Перезапуск: `sudo launchctl kickstart -k system/com.tradesoft.corp-wifi-routes`.

### 3.8.2. Маршрутизация opencode (анализ на 27.08.2026)
Текущая конфигурация подключений: `en0` (Wi-Fi, корп.), `ppp0` (корп. VPN,
`192.168.160.x`), `utun11` (Karing TUN, `10.20.0.1`).

Default routes (приоритет сверху вниз):
```
default → utun11 (Karing)   — главный (интернет-нод)
default → en0   (Wi-Fi)     — запасной
default → ppp0  (VPN)       — корп.
```

**opencode** (`opencode.exe`) подключается к `opencode.ai` (172.65.90.22):
- `route -n get 172.65.90.22` → `utun11` (Karing)
- Соединение: `10.20.0.1:xxxxx → 172.65.90.22:443` (ESTABLISHED)
- **Вывод: opencode идёт через Karing (прокси-нод), НЕ через корп. VPN и НЕ
  напрямую через en0.** Karing-правило для процесса `opencode.exe` не
  направляет в direct — уходит через default (нод).

Маршрутизация остальных приложений (для сравнения):
- Bitrix24 (`192.168.0.33`) → `ppp0` (корп.)
- Yandex (`*.yandex.ru`, `office.tradesoft.ru`) → `ppp0` (корп.) или `utun11`
- Telegram/M.TALKER → `utun11` (Karing)
- `sup5.tradesoft.corp:4000` → `ppp0` (корп.)

Нюанс: множество `/32`-маршрутов (например, все `172.65.90.x`, `74.125.x`,
`213.180.x`, `149.154.x` для Telegram/Yandex и т.п.) добавляет сам Karing —
это его per-app routing. Приоритет у Karing (`utun11`) выше, чем у en0/ppp0.

### 3.8. Установка / откат — `install.sh` / `uninstall.sh`
- `sudo ./install.sh` — копирует демоны (`corp-vpn-routes.sh`,
  `corp-learn.sh`, `corp-wifi-routes.sh`, `vpn-watchdog.sh`) и конфиги,
  загружает LaunchDaemon'ы (`com.tradesoft.corp-vpn-routes`,
  `com.tradesoft.corp-learn`, `com.tradesoft.corp-wifi-routes`,
  `com.tradesoft.corp-vpn-watchdog`), применяет split-режим
  (`split_fix.swift`), проверяет результат.
- `sudo ./uninstall.sh` — останавливает и удаляет демоны (в т.ч.
  vpn-watchdog), чистит маршруты, возвращает `OverridePrimary`
  (`split_restore.swift`).
- Перезапуск демона маршрутов: `sudo launchctl kickstart -k
  system/com.tradesoft.corp-vpn-routes`; демона автодетекта: `sudo launchctl
  kickstart -k system/com.tradesoft.corp-learn`; демона wifi-routes:
  `sudo launchctl kickstart -k system/com.tradesoft.corp-wifi-routes`.

### 3.9. Сбор сайтов — `collect-sites.py` и пароль из Keychain
`collect-sites.py` (репо `corp-vpn`) собирает домены сайтов из корп.
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

## 5. Проверки (зелёные на 27.08.2026; корп-часть перепроверена 04.09.2026; корп. Wi-Fi-часть 07.09.2026)

| Проверка | Команда | Результат |
|---|---|---|
| Интернет через TUN | `curl -s --max-time 12 https://api.ipify.org` | IP узла Karing |
| Маршруты на ppp | `route -n get 185.137.232.115 \| grep interface` | `ppp0` |
| Админка btk66 (root-вход) | `curl --interface 192.168.160.160 -L https://www.btk66.ru/admin/` | 200/302 |
| MySQL eurotradeplus | `nc -z -w 3 116.202.228.248 3306` | ok |
| Корп. egress | `curl --interface 192.168.160.160 https://ifconfig.me` | корп. IP `92.255.230.89` |
| Демон жив | `sudo launchctl print system/com.tradesoft.corp-vpn-routes \| grep 'state = '` | running |
| Корп. DNS резолвит | `dig @192.168.0.210 sup5.tradesoft.corp` | A-запись |
| Корп. DNS через ppp | `route -n get 192.168.0.210 \| grep interface` | `ppp0` |
| Корп. Bitrix | `curl -sk -o /dev/null -w '%{http_code}' https://192.168.0.33` | `200` |
| VPN-сервер (корп Wi-Fi) | `route -n get 109.194.204.125 \| grep interface` | `en0` |
| Корп. sup5 (корп Wi-FI, без L2TP/VPN) | `curl -s -o /dev/null -w '%{http_code}' http://sup5.tradesoft.corp:4000/queues.html` | `200` |
| Маршрут sup5 (корп Wi-Fi) | `route -n get 192.168.128.123 \| grep -E 'gateway|interface'` | gateway `192.168.128.1`, if `en0` |
| Корп. projects.prj (корп. Wi-Fi, без VPN) | `curl -s -o /dev/null -w '%{http_code}' http://www.projects.prj/schedule.html` | `401` (живой сервер) |
| Корп. b24 (корп. Wi-Fi, без VPN, без hosts) | `curl -s -o /dev/null -w '%{http_code}' http://b24.tradesoft.ru` | `301` (жив) |
| Автоподъём watchdog | `scutil --nc stop vpn3-ts` → через ≤60 с `scutil --nc status vpn3-ts` | `Connected` |
| parts-catalogs.com → direct (09.09.2026) | clash API (secret из `service.json`) → `GET /connections`, фильтр по host `parts-catalogs.com` | `chains=[direct_out]` |
| Ассистент подключён (18.09.2026) | clash API → `GET /connections`, фильтр host `id.xn--80akicokc0aablc…` | `chains=[🇬🇧 ⚡ Великобритания]` (нод) |
| Durable-правки (18.09.2026) | «🌏 GFW» в `karing_routing_group.json` содержит `.service.ast`/`.xn--80akicokc0aablc…` и `karing_setting.json` `perapp.enable=false` | оба на месте после полного рестарта |
| parts-catalogs.com /32 через ppp (при corp VPN) | `route -n get <IP parts-catalogs.com> \| grep interface` | `ppp0` |
| corp-routes-clean реальное событие (09.09.2026) | `grep deleted /var/log/corp-routes-clean.log` | `deleted 192.168.128.123 (corp host через en* вне on-link)` |

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
   secret found». **Рабочий метод**: `networksetup -connectpppoeservice "vpn3-ts"`
   (используется в `~/.wakeup`, `reconnect-vpn-wake.sh` и watchdog §3.6.1).
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
7. **Автоподъём VPN при обрыве — watchdog по таймеру (§3.6.1)**: проверяет
   VPN каждые 30 с и переподключает через `networksetup -connectpppoeservice`
   (рабочий метод; `scutil --nc start` для L2TP не подключает — см. п. 2).
   Ранний вариант «по IP-целям» (подъём по TCP-сокету к корп. IP) снят: он
   зависел от `scutil` и не работал. Порядок восстановления: сон →
   `sleepwatcher`/`~/.wakeup` (п. 3.6), обрыв в любой момент → watchdog.
8. **Автовосстановление VPN после сна**: `sleepwatcher` + `~/.wakeup` —
   автоматически переподключает `vpn3-ts` после пробуждения (п. 3.6).
   Watchdog `vpn-watchdog.sh` (п. 3.6.1) проверяет VPN каждые 30 с и
   переподключает при отключении. Используется
   `networksetup -connectpppoeservice` вместо `scutil --nc start`.
9. **Баг Karing автообновления (1.2.22 → 1.2.23)**: автообновитель скачивает
   DMG, но не может установить — `xattr -c` падает с `Operation not permitted`
   (macOS sandbox). Karing молча остаётся на старой версии. Обход: вручную
   `xattr -d com.apple.quarantine <dmg>`, смонтировать, скопировать в
   `/Applications`. Проверено 20.08.2026.
10. **Корпоративный Wi-Fi и VPN (27.08.2026, уточнено 07.09.2026)**: корп. Wi-Fi
    (`192.168.128.0/24`) — **изолированная гостевая сеть**. Доступ к корп.
    ресурсам обеспечивает правило Karing «На прямую» + маршруты демона
    (проверено 07–08.09.2026):
    - `sup5.tradesoft.corp:4000` → `200`, `www.projects.prj/schedule.html` → `401`
      (живой сервер), `b24.tradesoft.ru` → `301` — **без L2TP и без `/etc/hosts`**;
    - ключевое: в настройках Wi-Fi первым DNS-сервером стоит корп. `192.168.0.210`
      (`sudo networksetup -setdnsservers Wi-Fi 192.168.0.210 1.1.1.1`), а сам DNS
      мертвит `local`/`dhcp://auto`; корп. домены в правиле Karing «На прямую»
      (§3.4) — трафик через `direct_out`, не в прокси-узел;
    - **08.09.2026**: HTTP 000 на `sup5:4000` вызывал on-link
      маршрут до `192.168.128.123` (ARP-proxy шлюза не форвардит). Починено:
      `/32 → шлюз 192.168.128.1` (демон обязан, §3.8.1, и руками
      `sudo route -n add -host 192.168.128.123 192.168.128.1`). `projects.prj`
      ломал старый en0-/32, убран clean_dead_gw_routes (фикс 08.09.2026.).
    - **L2TP/IPSec VPN на этой Wi-Fi по-прежнему не поднимается** (сеть глушит
      L2TP-в-ESP — §3.6.1), поэтому watchdog там пропускает автоподъём (§3.6.1);
    - на других сетях корп. ресурсы доступны только по корп. VPN (маршруты →
      ppp0). `corp-wifi-routes.sh` (§3.8.1) при подключении VPN удаляет свои
      маршруты через `en0`, чтобы не конфликтовали с `ppp0`;
    - `VPN_SERVERS` (`109.194.204.122`, `.125`) могут периодически уходить в
      `utun10` (Karing) — демон wifi-routes не всегда успевает перебить их на
      шлюз; на доступ к корп. ресурсам не влияет, для L2TP на этой сети
      неактуально.

---

## 7. Операции

- **Включить всё**: 1) корп. VPN через System Settings (или
  `~/Work/scripts/corp-vpn/corp-vpn.sh start`), 2) включить Karing,
  3) маршруты до корп. ресурсов автоматически добавит демон (§3.6), проверить
  `route -n get 185.137.232.115 | grep interface` → `ppp0`.
- **Статус**: `~/Work/scripts/corp-vpn/corp-vpn.sh status`.
- ~~**Перезапуск моста**~~ (устарело — мост выведен и удалён из launchd, §3.1).
- **Перезапуск sleepwatcher**:
  `brew services restart sleepwatcher`
- **Перезапуск watchdog VPN** (LaunchDaemon, system-домен):
  `sudo launchctl kickstart -k system/com.tradesoft.corp-vpn-watchdog`
- **Логи**: Karing — `…/group.com.nebula.karing/service_core.log`, `app.log`;
  демон маршрутов — `journal`/`launchctl print` (§3.6);
  VPN reconnect/watchdog — `log show --predicate 'message CONTAINS "corp-vpn"'`.
- **Доступ к корп. ресурсам через корп. Wi-Fi (без L2TP, 07.09.2026)**:
  1) в настройках Wi-Fi первым DNS-сервером поставить корп. `192.168.0.210`
     (`sudo networksetup -setdnsservers Wi-Fi 192.168.0.210 1.1.1.1` — при смене
     сети слетает, повторить);
  2) убедиться, что в Karing правило «На прямую» содержит корп. суффиксы/домены
     (см. §3.4);
  3) проверить: `curl http://sup5.tradesoft.corp:4000/queues.html` → 200,
     `curl http://www.projects.prj/schedule.html` → 401, `curl http://b24.tradesoft.ru` → 301;
  4) проверить маршруты демона: `netstat -rn -f inet | grep -E '192.168.128.123|109.194.204|178.141.80'`
     → `192.168.128.123 … 192.168.128.1 en0`, VPN_SERVERS … тот же шлюз
     (демон сам их держит; пин корп DNS 0.210 → en0 НЕ добавляется с 08.09.2026).

---

## 8. Откат (если понадобится)

- Мост выведен из эксплуатации и удалён из launchd (14.08.2026 выведен,
  27.08.2026 полностью выгружен из gui-домена): правило «Корп L2TP» из Karing
  удалено, порт 1082 не слушается. Откат (если понадобится): вернуть
  `socks-bridge.py` в репо и загрузить агент
  `launchctl load ~/Library/LaunchAgents/com.aleksei.corp-bridge.plist`
  (файл plist сохранён в репо и в `~/Library/LaunchAgents/`).
- Полный откат демона маршрутов: `sudo ./uninstall.sh` (удаляет LaunchDaemon,
  чистит маршруты, возвращает `OverridePrimary`).
- Вернуть правило Karing в исходное состояние: в приложении Karing
  (Настройки → Правила) удалить правила «Корп L2TP» и «На прямую», или
  восстановить `karing_routing_group.json.bak.20260809-*` и
  `karing_subscribe_use.json.bak.20260809-*`.
- Системные маршруты `10/8`, `192.168.0/16 → ppp0` ставятся самим VPN-сервером
  и исчезают при отключении туннеля.

---

## 9. Диагностика 09.09.2026: «нет интернета вне офиса» и «opencode исчезает»

### 9.1. Симптомы
- На хотспоте/не-корп сети интернета нет вообще: и с включённым Karing, и без
  него все пробы `000`;
- на корп-сети opencode (`api.opencode.ai`) через Karing периодически пропадал
  (таймаут), несмотря на то что google/1.1.1.1 работали.

### 9.2. Корневая причина №1 — статическая конфигурация Wi-Fi
`networksetup -getinfo Wi-Fi` показывал **Manual Configuration**:
`IP 192.168.128.56`, `Router 192.168.128.1`, DNS `192.168.0.210 1.1.1.1`,
домены `tradesoft.corp prj tradesoft.ru` (сервис
`3E5FD85A-3C8F-41E5-AB4D-6832197496DF`, `ConfigMethod=Manual`).

- На корп-сети (`192.168.128.0/24`) статика совпадала с реальной топологией →
  работало;
- на хотспоте/дома шлюз `192.168.128.1` не существует → default-маршрут не
  поднимался (`defs=[]` после `scutil --nc stop`), интернет мёртв **даже без
  Karing**. Этим объясняется «и с Karing, и без — нет интернета».
- **Проверено:** в `~/Work/scripts/corp-vpn` (и в `/usr/local/sbin/*.sh`) нигде
  нет установки статики (`rg "setmanual|Manual"` — пусто). Статика была
  выставлена вручную в System Settings и залипла в `preferences.plist`.

**Фикс: Wi-Fi переведён на DHCP** (`networksetup -setdhcp Wi-Fi` +
`-setdnsservers Wi-Fi Empty`). Корп-сеть реально раздаёт адреса
(`ipconfig getpacket` → `ACK`, `yiaddr=192.168.128.56`, DNS
`0.200 0.210 0.225`) — переход безобрывен. Откат к статике:
`./wifi-static-rollback.sh`.

### 9.3. Корневая причина №2 — битые fake-IP host-маршруты Karing
Симптом (воспроизводился даже на корп): `api.opencode.ai` через Karing = `000`,
при этом:
- `curl --resolve api.opencode.ai:443:104.18.28.234` (реальный IP) → `200`;
- `curl -x http://127.0.0.1:3067` (mixed-порт Karing) → `200`;
- DNS отдавал fake-IP из пула `198.20.0.0/15` (напр. `198.20.0.11`).

Причина: часть host-маршрутов fake-IP пула указывала **не** на `utun4`, а на
`en0`/шлюз `192.168.128.1` (остаток от момента старта Karing, когда default ещё
шёл через старый шлюз):
```
198.20.0.8   utun4           ← правильно
198.20.0.11  192.168.128.1 → en0   ← битый: пакеты уходят в корп-LAN → timeout
```
Пакет на такой fake-IP не доходит до туннеля → таймаут домена через Karing.

**Фикс**: `sudo route delete -host 198.20.0.11 …` — после удаления маршруты
fake-IP идут только через `utun4`, DNS снова реальный, всё `200`.

**Вариант с ppp0**: на момент диагностики 4 fake-IP (`198.20.0.17/58/59/60`)
успели попасть и в таблицу через `ppp0` — их протащил демон маршрутов
`corp-vpn-routes.sh`: он резолвит корп-домены через `dig`, а DNS в момент
резолва шёл через Karing и возвращал fake-IP (см. записи `probe:198.20.0.16:4000`
в `/var/run/corp-vpn-routes.state`). Это тоже «битые» fake-IP-маршруты — тот же
класс проблемы, чинится тем же `sudo route delete -host …`.

### 9.4. Важно: fake-IP Karing отключать НЕЛЬЗЯ
Это штатный механизм sing-box для перехвата доменов по пакетам; без него
ломается доменная маршрутизация Karing. Karing сам регенерирует
`service_core.json` при каждом подключении (попытки отредактировать файл
откатываются). Отключение fake-IP было отменено.

### 9.5. Автоматизация проверки (добавлена 09.09.2026)
- **`corp-routes-check.sh`** — детектор битых fake-IP маршрутов:
  находит `198.20.0.x`-маршруты, идущие НЕ через `utun*`
  (флаг `--sudo-cmd` печатает готовые `sudo route delete -host …`).
  Сейчас: `OK: все fake-IP маршруты идут через utun*`.
- **`corp-vpn-diagd.sh`** дополнен: в снимок сети добавляется метка
  `BADROUTES={198.20.0.x(en0) …}`, когда демон маршрутов подхватывает битый
  маршрут — сразу видно в `/var/log/corp-vpn-diag.log`.

### 9.6. Обнаруженное по пути: sup5.tradesoft.corp
На не-корп сети `sup5:4000` отдавал «Empty reply». Причина: висел `host-маршрут
`192.168.128.123 → en0 (192.168.128.1)` (остаток корп-сети), который перебивал
правильный `192.168.0.0/16 → ppp0`. Через корп VPN `curl --interface ppp0
http://192.168.128.123:4000/queues.html` работал полностью.
**Фикс**: `sudo route delete -host 192.168.128.123` (далее маршрут → `utun4`).
Осталось недоделанным (09.09.2026): после удаления en0-версии Karing перевесил
`/32` на `utun4`, и прямой HTTP до `sup5` через Karing по-прежнему даёт
«Empty reply». Проверка на корп-сети (on-link) → ожидаем 200.

### 9.6.1. Демон авто-очистки мёртвых маршрутов — `corp-routes-clean.sh` (добавлен 09.09.2026)
Отдельный root-демон (`com.tradesoft.corp-routes-clean`, LaunchDaemon, каждые 15 с),
который удаляет «мёртвые» маршруты — то, что раньше чинили руками sudo. Правила:
- **fake-IP пулы Karing (`198.18.0.0/15`, `198.20.0.0/15`) через НЕ-`utun*`**
  (en0/ppp0) — удаляет **сразу** (сценарий из §9.3). Безопасно: при активном
  Karing пакет к fake-IP всё равно уйдёт в туннель по default, Karing на
  следующем такте пересоздаст корректный `/32` на `utun4`. Если Karing выключен —
  эти адреса и так мусор.
- **корп. host-маршруты (`10/8`, `192.168/16`) через физический интерфейс
  (`en*`/`wl*`) ВНЕ собственной on-link подсети** — удаляет **по 2 снимкам
  подряд** (защита от раскачки при смене сетей/DHCP). Это автоматизирует
  ручной фикс sup5 из §9.6: маршрут `192.168.128.123 → en0`, когда текущая
  сеть не `192.168.128.0/24`, сносится сам.
- Не трогает: `utun*`, `lo0`, `utun*`-fake-IP (это норма), host-маршруты,
  лежащие в on-link подсети самого en0 (легитимно: на корп-сети sup5 on-link —
  ожидаем 200), DNS-маршруты корп. DNS (`192.168.0.210/220` — не host-lookup).
Лог: `/var/log/corp-routes-clean.log` (ротация 1000 строк).

**Проверено на реальном событии 09.09.2026 (корп Wi-Fi → дом):** при переходе
на дом. Wi-Fi (`192.168.31.0/24`) демон сам, без sudo, удалил мёртвый маршрут
`192.168.128.123 → en0` (остаток корп-сети):
`2026-09-09 17:01:51 deleted 192.168.128.123 (corp host через en* вне on-link)`.
После удаления маршрут ушёл на правильный `ppp0` (корп. VPN поднят, `10/8` +
`192.168/16 → ppp0`). Ручной фикс из §9.6 больше не нужен.

### 9.6.2. Профилактика «родника» — фильтр fake-IP в `corp-vpn-routes.sh` (добавлен 09.09.2026)
`host_ip()` теперь отбрасывает ответы из fake-IP пулов (`198.18.x/198.19.x`,
`198.20.x/198.21.x`). Раньше, когда DNS шел через Karing, `dig` возвращал
fake-IP (например `sup5 → 198.20.0.16`), они попадали в STATE и превращались
в host-маршруты через ppp0 — мёртвые (не через utun). Теперь такие адреса
пропускаются на корню, в STATE не попадают.

### 9.6.3. Уведомления (Notification Center) — `corp-notify.sh` (добавлен 09.09.2026)
Сигнальная очередь: root-демоны пишут события в `/var/run/corp-vpn-signals`
(строки `ts|event|message`, ротация при >200 строк), юзер-агент
`corp-notify.sh` (LaunchAgent `com.tradesoft.corp-notify`, каждые 10 с, от
aleksei) читает новые строки по байтовому указателю (`/tmp/corp-vpn-notify.pos`)
и показывает баннеры через `osascript display notification` with
`sound name "default"`. Дедупликация: одно событие `event|message` не чаще
раза в 30 с (`/tmp/corp-vpn-notify.seen`). События:
- `routes-dead.del` — мёртвый маршрут удалён (corp-routes-clean);
- `routes-dead.fail` — не удалось удалить (corp-routes-clean);
- `badroutes.on` / `badroutes.off` — появление/исчезновение битых fake-IP
  (corp-vpn-diagd, только на переходе состояния);
- `vpn.up` / `vpn.down` — корп VPN поднялся/отключился (corp-vpn-routes,
  только на смене `last_iface`; маркер `/var/run/corp-vpn-signals.vpn`).
- `db-clean.ok` / `db-clean.dryrun` / `db-clean.fail` — результаты автоочистки
  БД aisql (corp-db-clean, ежедневно 03:00; отдельный проект
  `~/Work/scripts/db-clean/` — см. его README.md).

События `db-clean.*`, помимо баннера, **дублируются в B24-чат и Telegram**:
`corp-notify.sh` (работает от пользователя, поэтому доступен Keychain) вызывает
`~/Work/scripts/monitoring/notify.py` (`db-clean.ok` → заголовок «aisql: БД
удалены» и т.д.). Секреты каналов — Keychain (`opencode.tg-alert-*`; вебхук
ts-b24), значения в скрипты не вшиты. Тот же `notify.py` использует сторож
веб-проценки (`monitoring/pricing_alert.py`) — единая точка отправки.

### 9.7. Проверено 09.09.2026 (зелёное)
- Корп-сеть: DHCP, `defs=[en0 utun4]`, Karing Connected, `api.opencode.ai=200`,
  `198.20.0.x` только через `utun4`.
- Хотспот/не-корп сеть (`10.182.174.97`): с Karing все пробы 200; после
  `scutil --nc stop` — `defs=[en0]`, `internet_without_karing=yes`, opencode
  200 без туннеля; Karing восстановлен, маршруты чисты.
- Корп VPN (`vpn2-ts`): пpp0 up, `10.0.0.0/8` и `192.168.0.0/16 → ppp0` есть
  (в netstat `10 → ppp0`), `projects.prj:80` 200, `192.168.0.210:53` 200.
- Демоны работают из `/usr/local/sbin/` (корни, 08.09 15:14), включая
  `corp-wifi-routes.sh`; канонический репозиторий — `~/Work/scripts/corp-vpn`,
  plist ссылается на `/usr/local/sbin`.
- После фикса parts-catalogs (§9.8): `api.parts-catalogs.com` через Karing →
  `chains=[direct_out]` (clash API), доступ к сервису восстановлен.
- Реальное срабатывание `corp-routes-clean` (§9.6.1): корп Wi-Fi → дом,
  мёртвый `192.168.128.123 → en0` удалён демоном автоматически (17:01:51),
  маршрут затем через `ppp0`.

### 9.8. Диагностика 09.09.2026: «api.parts-catalogs.com определяется не-офисным IP»
**Симптом:** внешний сервис автокаталогов при работе через Karing «видит» не
офисный IP (US-прокси), несмотря на то что в direct-группу Karing уже были
добавлены суффиксы `.parts-catalogs.ru` и `.parts-index.com`.

**Корень:** реальный трафик сервиса идёт на домен **`.parts-catalogs.com`** (без
`ru`), которого в direct-группе не было. Домен не совпал ни с одним эксплицитным
правилом → пошёл в `route.final = urltest_out` (нод-туннель, VPS Казань) → IP узла,
а не офиса. Суффиксы `.parts-catalogs.ru`/`.parts-index.com` на реальный домен не
влияли. Подтверждено живыми соединениями Karing (clash API, `GET /connections`):
`www.parts-catalogs.com`/`api.parts-catalogs.com` → `chains=[urltest_out]`.

**Ключевой вывод (механика правок Karing):** правила Karing живут во внутреннем
хранилище приложения и правятся только через UI (группа «На прямую» →
`domain_suffix`). Файлы `karing_routing_group.json`/`service_core.json` — суть
**генераты**: при переподключении Karing перезаписывает их из своего состояния,
поэтому ручные правки файлов на диске затираются. Диагностика этого:
1. внести суффикс в файлы руками → reconnect Karing → суффикс исчез;
2. внести тот же суффикс через UI → reconnect → суффикс сохранён.

**Фикс:**
1. В UI Karing в группу «На прямую» добавлен суффикс `.parts-catalogs.com`
   (реальный домен трафика), после reconnect доступ восстановлен, IP офисный;
2. в `SITE_DOMAINS` конфига добавлены `parts-catalogs.com parts-index.com`
   (коммит `618794f`) — закрепляют `/32`-маршруты через `ppp0` при поднятом
   корп. L2TP (§3.6.2).

**Проверка после фикса:** clash API `GET /connections`, фильтр host
`parts-catalogs.com` → `chains=[direct_out]` (единственное активное соединение
в момент диагностики).

---

## 10. Диагностика 18.09.2026: Ассистент «нет соединения» (ID-сервер `.service.ast` / fake-IP)

**На чём воспроизводится:** Assistant.app (`ru.safib.assistant`, процессы
`assistant`/`asts`/`astrct`) и Mango (`com.mangotele.mtalker.desktop`, процесс
`M.TALKER`) теряют связь с серверами, когда включён Karing.

### 10.1. Механика (что выяснено по логам приложения)

- Ассистент ходит на ID-сервер двумя именами, в зависимости от кэшированного
  состояния сеанса:
  - `https://id.xn--80akicokc0aablc.xn--p1ai:443` — **публичный** домен,
    A-запись `95.129.232.196` (запасной из кэша приложения `87.229.197.10`);
  - `id-proxy.service.ast` — **непубличное** имя (публично NXDOMAIN), которое
    в hijack-dns Karing получает fake-IP `198.20.0.x`.
- Приложение коннектится с собственным кэшем `PriorIp=fake-IP` (`curl_slist =
  id.xn–…:198.20.0.11`). fake-IP невозможно диа-лить напрямую: sing-box
  восстанавливает домен, а для `id-proxy.service.ast` локальный резолв даёт
  NXDOMAIN → «нет соединения» (лог `service_core.log`, 11:35: lookup failed for
  id-proxy.service.ast: NXDOMAIN; dial через `direct_out`).
- Когда трафик приложения идёт **через нод** (правило R11 «🌏 GFW»): sing-box
  восстанавливает домен и передаёт его в нод; нод резолвит публичный punycode и
  TLS проходит → регистрация успешна (`Registered in IdSrv=…:443`). Т.е.
  «резолвит service.ast» не происходит — рабочий хост приложения —
  публичный punycode-домен; `service.ast` через нод тоже отвечает TCP, но TLS по
  нему отваливается по SNI.
- **Главная причина прямого прохода в `direct_out`** — включённый **`perapp`**
  (приложение было в списке `list_macos` при `is_include=false` → весь трафик
  Ассистента/Mango уводился в direct). Как только `perapp.enable=false`,
  трафик пошёл по правилам → R11 → нод → работает.

### 10.2. Изменения (применены и пережили полный рестарт 14:05)

- `karing_routing_group.json`, группа **«🌏 GFW»**: в `domain_suffix` добавлены
  `.service.ast` и `.xn--80akicokc0aablc.xn--p1ai` → в сгенерированном
  `service_core.json` правило R11 (`🌏 GFW[Самостоятельная настройка]`) уводит
  их в выбранный нод (на 18.09.2026 — `🇬🇧 ⚡ Великобритания`).
- `karing_setting.json`: `perapp.enable=false` (снято принудительное заворачивание
  apps в direct).
- Бэкапы: `karing_routing_group.json.bak.pre-idsrv.20260918-112904`,
  `karing_setting.json.bak.pre-idsrv.20260918-112904`,
  `service_core.json.bak.pre-staticips.*`.

### 10.3. Что НЕ сработало (важно для будущих попыток)

- `dns.static_ips`/`dns.hosts` — затираются Karing при каждом рестарте из
  внутреннего хранилища (`cache.db`, бинарный; GUI пишет настройки сам);
  инъекции в `service_core.json` ядро не перечитывает (конфиг приходит в
  системное расширение через GUI, файл — только зеркало). Статические IP
  ставятся **только через UI**: Настройки → DNS → «Прямой поток» → «Static IP»
  (домен → IP). В текущем решении они **не нужны**.
- Правки `karing_subscribe_use.json` (список-диверсия) — регенерируются и
  затираются (переживает только `select_default`).

### 10.4. Как проверить (регресс после любого рестарта Karing)

```
# 1) durable-правки на месте:
grep -c 'service.ast' "~/Library/Group Containers/group.com.nebula.karing/karing_routing_group.json"   # >0
python3 -c "import json;d=json.load(open('~/Library/Group Containers/group.com.nebula.karing/karing_setting.json',encoding='utf-8'));print(d['perapp']['enable'])"  # False
# 2) живое соединение Ассистента идёт в нод, а не direct (пока Assistant открыт):
#    clash API (secret в service_core.json → experimental.clash_api.secret),
#    GET /connections, фильтр host id.xn--80akicokc0aablc… → chains=[🇬🇧 ⚡ Великобритания]
```

**Ограничение:** группа «🌏 GFW» уводит ID-трафик в выбранный нод. Если нод не
резолвит/не достаёт ID-сервер — Ассистент снова «без соединения»; решение —
выбрать в Karing нод, который достаёт сервер (Великобритания подтверждён), либо
добавить домен → `95.129.232.196` через UI-статик IP (§3.4).
