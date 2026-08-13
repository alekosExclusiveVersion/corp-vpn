# Настройка корпоративного VPN + Karing на macOS (aleksei)

Документ фиксирует всю проделанную работу: проблему, архитектуру решения,
все файлы, конфигурации, команды проверки, операции и известные ограничения.
Дата: 10.08.2026. Дополнено 11.08.2026: маршрутный демон `corp-vpn-routes.sh`
и единый конфиг `corp-networks.conf` перенесены в этот репозиторий;
добавлена маршрутизация сайтов `SITE_DOMAINS` через корп. VPN;
документированы пароль из Keychain для `collect-sites.py` (п. 3.9),
root-вход через корп. egress (п. 6) и watchdog автоподключения VPN (п. 3.6).

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

## 2. Архитектура решения (3 слоя)

```
Интернет-трафик (обычные сайты)
   │
   ▼
Karing TUN (utun4, default → узел 🇳🇱 Netherlands)
   │  DNS: hijack-dns → dns_proxy_out → DoH (1.1.1.1/8.8.8.8)
   ▼
Интернет работает через узел Karing

Корпоративный трафик (*.tradesoft.corp, *.prj, 10/8, 192.168/16)
   │
   ▼
Karing TUN → правило «Корп L2TP» → SOCKS5 127.0.0.1:1082
   │
   ▼
socks-bridge.py (автозапуск через launchd, процесс 20995)
   │  DNS-резолв через корп. DNS 192.168.0.210 (сырой UDP-запрос)
   │  проверка: ppp0 поднят + «UP» + есть inet
   ▼
Корпоративный туннель ppp0 (маршруты 10/8, 192.168.0/16 → ppp0)
   ▼
Корпоративные ресурсы (sup5.tradesoft.corp:4000, www.projects.prj, ...)

Локальная сеть / телефон (en0, 172.25.125.x) — не трогается
```

Ключевая идея: **не перехватывать корпоративные адреса в самом sing-box**.
Достаточно, чтобы корпоративные DNS-имена резолвились через корп. DNS
(`socks-bridge.py` делает это сам), а IP-пакеты попадали в корп. туннель за счёт
системных маршрутов `10/8` и `192.168.0/16 → ppp0`. Правило в Karing лишь
направляет корпоративный трафик в мост.

---

## 3. Компоненты и файлы

### 3.1. Мост — `socks-bridge.py` (в репо; `~/bin/socks-bridge.py` — симлинк)
SOCKS5-сервер на `127.0.0.1:1082` (Python 3, только stdlib).

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

Важно: старый черновик с `SyntaxError` в `/tmp/socks-bridge.err` — от
предыдущей итерации, текущий процесс (20995) рабочий.

### 3.2. Автозапуск моста — `~/Library/LaunchAgents/com.aleksei.corp-bridge.plist`
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
- **route/rules** (важные):
  - `Корп L2TP[Самостоятельная настройка]`: domain_suffix `.tradesoft.ru`,
    `.tradesoft.pro`, `.tradesoft.corp`, `.prj` + домены `sup5.tradesoft.corp`,
    `www.projects.prj`, `projects.prj`, `servicedesk-report.office.tradesoft.ru`
    → outbound `Корп L2TP` (мост).
  - `На прямую[Самостоятельная настройка]`: `.yandex.ru`, `.master.systest.php7`,
    `opencode.ai`, сайты `SITE_DOMAINS` (напр. `www.amry.ru`), ip_cidr
    `10.0.0.0/8` + `192.168.0.0/16`, процесс `opencode.exe` → `direct_out`.

### 3.5. Корпоративный VPN (система)
- Сервисы: `vpn1`, `vpn2-ts`, `vpn3-ts`, `vpn4`; активен `vpn3-ts`.
- Сервер: `vpn3.tradesoft.ru` (109.194.204.125), авторизация `a.koshkin`,
  PSK в keychain (иногда «incorrect user shared secret found» при CLI).
- Туннель: `ppp0`, адрес Mac `192.168.160.160`, шлюз `192.168.160.1`.
- Корп. DNS: `192.168.0.210`.
- **Split-режим**: у `vpn2-ts` и `vpn3-ts` убран `IPv4.OverridePrimary`
  (применяется `install.sh` через `split_fix.swift`) — обычный интернет идёт
  мимо VPN, а корп. маршруты добавляет демон (см. 3.6).

### 3.6. Демон маршрутов — `corp-vpn-routes.sh` (split-tunnel)
- LaunchDaemon `com.tradesoft.corp-vpn-routes` (root, проверяет каждые 5 с).
- Файлы: `/Library/LaunchDaemons/com.tradesoft.corp-vpn-routes.plist`,
  `/usr/local/sbin/corp-vpn-routes.sh` (устанавливаются из репо через `install.sh`).
- При подключении `vpn2-ts`/`vpn3-ts` добавляет через ppp:
  - сети `10/8`, `192.168.0/16`;
  - `/32`-маршруты к MySQL-серверам из `MYSQL_HOSTS` (резолв по DNS каждые 5 мин);
  - `/32`-маршруты к сайтам `SITE_DOMAINS` (по всем A-записям).
- При отключении VPN маршруты удаляются (по state-файлу `/var/run/corp-vpn-routes.state`).
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
- Из него берут данные оба компонента:
  - демон маршрутов (ppp-маршруты, п. 3.6);
  - генератор правил Karing `karing-rules.sh` (репо `tradesoft-vpn-setup`);
    конфиг ищется в `/usr/local/etc`, затем `../corp-vpn/corp-networks.conf`.

### 3.8. Установка / откат — `install.sh` / `uninstall.sh`
- `sudo ./install.sh` — копирует демон и конфиг, загружает LaunchDaemon,
  применяет split-режим (`split_fix.swift`), проверяет результат.
- `sudo ./uninstall.sh` — останавливает и удаляет демон, чистит маршруты,
  возвращает `OverridePrimary` (`split_restore.swift`).

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
default            link#23            UCSg       utun4    ← Karing (интернет)
default            172.25.125.111     UGScIg     en0      ← телефон/локальная сеть
default            link#22            UCSIg      ppp0     ← корп. VPN (глобальный режим)
10                  ppp0               USc       ppp0     ← корпоративная сеть
192.168.0/16        ppp0               USc       ppp0     ← корпоративная сеть
```
Интернет уходит через utun4 (высший приоритет), корп. подсети — через ppp0.

---

## 5. Проверки (все зелёные на 10.08.2026, ~14:00)

| Проверка | Команда | Результат |
|---|---|---|
| Интернет через TUN | `curl -s --max-time 12 https://api.ipify.org` | IP узла Karing |
| Корп. через мост | `curl --socks5-hostname 127.0.0.1:1082 http://sup5.tradesoft.corp:4000/` | 200 |
| Полный стек TUN→мост | `curl http://sup5.tradesoft.corp:4000/` | 200 |
| Проекты | `curl http://www.projects.prj/` | 200 |
| Статус | `~/Work/scripts/corp-vpn/corp-vpn.sh status` | всё работает |
| Мост жив | `nc -z 127.0.0.1 1082` | ok |
| Корп. DNS резолвит | `dig @192.168.0.210 sup5.tradesoft.corp` | A-запись |
| Egress сайтов (через туннель) | `curl --interface 192.168.160.160 https://ifconfig.me` | корп. IP `92.255.230.89` |

---

## 6. Известные ограничения / нюансы

1. **Split-режим** корп. VPN: `OverridePrimary` у `vpn2-ts`/`vpn3-ts` убран
   (демон маршрутов добавляет только корп. сети, п. 3.6). Если галку
   «Отправлять весь трафик» случайно вернули в System Settings — повторно
   запустить `sudo ./install.sh`.
 2. **CLI-подключение корп. VPN** (`scutil --nc start`) не работает — проверено
    11.08.2026. Причина: keychain PSK после пересоздания элементов лежит в
    System.keychain, а NE-стек (pppd/racoon) при запуске через `scutil` не может
    его прочитать и отдаёт «incorrect user shared secret found». Ввод секрета
    заново через System Settings (пересоздание элементов в правильном домене)
    восстанавливает только GUI-путь. Подключать VPN можно только через System
    Settings. Порядок подключения: сначала корп. VPN (GUI), затем Karing; либо
    Karing, затем корп. VPN — если Karing упал, переподключить его.
3. **Мост резолвит через корп. DNS** — если корп. туннель лежит, домены
   `*.tradesoft.corp` не резолвятся (мост отвечает rejected). Это
   предохранитель от утечки корп. трафика.
4. **Узел Karing и en0**: узел NL соединяется через en0 (auto_detect_interface).
   Если телефон/локальная сеть теряет интернет — Karing-узел недоступен.
5. Мост слушает только `127.0.0.1` (безопасно, извне недоступен).
6. **Root-вход в админки сайтов (`systradesoft`) работает только при
   подключённом корп. VPN** — авторизация завязана на source-IP. Трафик к
   сайтам (`activauto.ru`, `amry.ru` и др.) при включённом `vpn2-ts`/`vpn3-ts`
   идёт через `/32`-маршруты → `ppp0` → корп. egress `92.255.230.89`
   (ER-Telecom/DOM.RU), который в allowlist — вход проходит. Без VPN сайт видит
   домашний IP (напр. Tele2 `94.77.36.66`) — root-вход отклоняется, при этом
   страницы `/admin/login/` публично доступны. Split-horizon DNS нет: корп. DNS
   отдаёт те же публичные IP, что и публичный. Как проверить, какой IP видит
   сервер: `curl --interface <ppp-IP> https://ifconfig.me` (через туннель)
   против `curl https://ifconfig.me` (общий egress). Правило Karing «На прямую»
   (direct_out) гарантирует, что трафик сайтов НЕ уходит через прокси-нод —
   иначе сервер увидел бы IP нода, и allowlist не сработал бы даже при
   включённом VPN.
7. **Автоподключение VPN по корп. трафику (watchdog)** работает по IP-целям:
   любой TCP-сокет к корп. IP (в т.ч. публичные корп. сайты) поднимает туннель
   с задержкой ~10 с (цикл 5 с + коннект). Внутренние имена
   (`sup5.tradesoft.corp`, `projects.prj`) не могут быть триггером — DNS не
   резолвится без туннеля; они доступны уже после того, как туннель поднят по
   любому IP-триггеру. Если `scutil --nc start` под root падает с
   «incorrect user shared secret found» — автоподъём невозможен, VPN поднимается
   вручную через System Settings.

---

## 7. Операции

- **Включить всё**: 1) корп. VPN через System Settings (или
  `~/Work/scripts/corp-vpn/corp-vpn.sh start`), 2) включить Karing, 3) мост
  поднимется сам (launchd), проверить `launchctl list | grep corp-bridge`.
- **Статус**: `~/Work/scripts/corp-vpn/corp-vpn.sh status`.
- **Перезапуск моста**:
  `launchctl unload ~/Library/LaunchAgents/com.aleksei.corp-bridge.plist &&
   launchctl load ~/Library/LaunchAgents/com.aleksei.corp-bridge.plist`
- **Логи**: мост — `/tmp/socks-bridge.log` (+ `.err`), Karing —
  `…/group.com.nebula.karing/service_core.log`, `app.log`.

---

## 8. Откат (если понадобится)

- Убрать автозапуск моста:
  `launchctl unload ~/Library/LaunchAgents/com.aleksei.corp-bridge.plist`,
  удалить plist и `socks-bridge.py` из репо.
- Полный откат демона маршрутов: `sudo ./uninstall.sh` (удаляет LaunchDaemon,
  чистит маршруты, возвращает `OverridePrimary`).
- Вернуть правило Karing в исходное состояние: в приложении Karing
  (Настройки → Правила) удалить правила «Корп L2TP» и «На прямую», или
  восстановить `karing_routing_group.json.bak.20260809-*` и
  `karing_subscribe_use.json.bak.20260809-*`.
- Системные маршруты `10/8`, `192.168.0/16 → ppp0` ставятся самим VPN-сервером
  и исчезают при отключении туннеля.
