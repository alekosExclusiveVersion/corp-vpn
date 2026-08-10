# Настройка корпоративного VPN + Karing на macOS (aleksei)

Документ фиксирует всю проделанную работу: проблему, архитектуру решения,
все файлы, конфигурации, команды проверки, операции и известные ограничения.
Дата: 10.08.2026.

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

### 3.1. Мост — `~/bin/socks-bridge.py`
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
- `RunAtLoad: true`, `KeepAlive: true` (перезапуск при падении)
- Логи: `/tmp/socks-bridge.log`, `/tmp/socks-bridge.err`
- Состояние: `launchctl list | grep corp-bridge` → PID 20995.

### 3.3. Управление корп. VPN — `~/bin/corp-vpn.sh`
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
    `opencode.ai`, ip_cidr `10.0.0.0/8` + `192.168.0.0/16`, процесс `opencode.exe`
    → `direct_out`.

### 3.5. Корпоративный VPN (система)
- Сервисы: `vpn1`, `vpn2-ts`, `vpn3-ts`, `vpn4`; активен `vpn3-ts`.
- Сервер: `vpn3.tradesoft.ru` (109.194.204.125), авторизация `a.koshkin`,
  PSK в keychain (иногда «incorrect user shared secret found» при CLI).
- Туннель: `ppp0`, адрес Mac `192.168.160.160`, шлюз `192.168.160.1`.
- Корп. DNS: `192.168.0.210`.
- Файл конфига: `/Library/Preferences/SystemConfiguration/preferences.plist`,
  сервис `D3B98206-61DC-4340-B0AC-A970F8B9C582` (vpn3-ts):
  **`IPv4.OverridePrimary = 1`** — «глобальный» режим (претендует на
  default-маршрут). Это запасной источник конфликтов (см. п. 6).

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
| Статус | `~/bin/corp-vpn.sh status` | всё работает |
| Мост жив | `nc -z 127.0.0.1 1082` | ok |
| Корп. DNS резолвит | `dig @192.168.0.210 sup5.tradesoft.corp` | A-запись |

---

## 6. Известные ограничения / нюансы

1. **Корп. VPN в «глобальном» режиме** (`OverridePrimary=1` у vpn3-ts):
   лишний default через ppp0. Сейчас безвреден (utun4 выше приоритетом), но при
   странностях подключения стоит выключить «Отправлять весь трафик» для корп.
   VPN в System Settings → VPN → Details (сплит-режим: останутся только
   маршруты 10/8 и 192.168/16).
   Команда для смены (требует sudo):
   ```
   sudo /usr/libexec/PlistBuddy -c "Set :NetworkServices:D3B98206-61DC-4340-B0AC-A970F8B9C582:IPv4:OverridePrimary 0" /Library/Preferences/SystemConfiguration/preferences.plist
   sudo killall -HUP configd
   ```
2. **CLI-подключение корп. VPN** (`scutil --nc start`) может не сработать из-за
   keychain PSK → подключать через System Settings. Порядок подключения:
   сначала корп. VPN (GUI), затем Karing; либо Karing, затем корп. VPN — если
   Karing упал, переподключить его.
3. **Мост резолвит через корп. DNS** — если корп. туннель лежит, домены
   `*.tradesoft.corp` не резолвятся (мост отвечает rejected). Это
   предохранитель от утечки корп. трафика.
4. **Узел Karing и en0**: узел NL соединяется через en0 (auto_detect_interface).
   Если телефон/локальная сеть теряет интернет — Karing-узел недоступен.
5. Мост слушает только `127.0.0.1` (безопасно, извне недоступен).

---

## 7. Операции

- **Включить всё**: 1) корп. VPN через System Settings (или
  `~/bin/corp-vpn.sh start`), 2) включить Karing, 3) мост поднимется сам
  (launchd), проверить `launchctl list | grep corp-bridge`.
- **Статус**: `~/bin/corp-vpn.sh status`.
- **Перезапуск моста**:
  `launchctl unload ~/Library/LaunchAgents/com.aleksei.corp-bridge.plist &&
   launchctl load ~/Library/LaunchAgents/com.aleksei.corp-bridge.plist`
- **Логи**: мост — `/tmp/socks-bridge.log` (+ `.err`), Karing —
  `…/group.com.nebula.karing/service_core.log`, `app.log`.

---

## 8. Откат (если понадобится)

- Убрать автозапуск моста:
  `launchctl unload ~/Library/LaunchAgents/com.aleksei.corp-bridge.plist`,
  удалить plist и `~/bin/socks-bridge.py`.
- Вернуть правило Karing в исходное состояние: в приложении Karing
  (Настройки → Правила) удалить правила «Корп L2TP» и «На прямую», или
  восстановить `karing_routing_group.json.bak.20260809-*` и
  `karing_subscribe_use.json.bak.20260809-*`.
- Вернуть корп. VPN в глобальный режим (п. 6, `OverridePrimary 0→1`).
- Системные маршруты `10/8`, `192.168.0/16 → ppp0` ставятся самим VPN-сервером
  и исчезают при отключении туннеля.
