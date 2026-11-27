# RDP из macOS в корп. сеть — диагностика 17.09.2026

Контекст: корп. VPN `vpn3-ts` (L2TP/IPsec, интерфейс `ppp0`), хост
`testing26.tradesoft.corp` (192.168.128.160, Windows 11 build 10.0.26200,
домен TRADESOFT). Клиент — «Windows App» (MS RDC, `com.microsoft.rdc.macos`
11.4.1.3092).

## Симптом
С Mac по VPN RDP не поднимался: NLA проходит (сервер пишет успешный вход —
Security 4624 Type 3, `NtLmSsp`/NTLM V2), но клиент зависает после
согласования MCS-каналов, не отправляет **Client Info**, сервер не присылает
**Demand Active**. На сервере нет LSM-событий, `quser` пуст. Через ~60 с
клиент рвёт транспорт:

```
RDP_WAN(ERR): TcpTrans::TcpTransportOnClosed - last exception:
  The operation couldn’t be completed. Operation now in progress
  (TsTcpDctTransport.cpp:1213)
```

## Что исключено (и как проверено)

| Версия | Проверка | Итог |
|---|---|---|
| Сломан серверный RDP | `sdl-freerdp` 3.31.1 с того же Mac по тому же туннелю | открывает **полную** сессию (LogonId 3, rdpgfx) → сервер исправен |
| Параметры RDP-Tcp нетипичны | SecurityLayer=2, UserAuthentication=1, MinEncryptionLevel=2, SelectTransport=2, SelectNetworkDetect=1, fSingleSessionPerUser=1 | штатно; временная установка `SelectNetworkDetect=0` — **без эффекта** (возвращено в 1) |
| Маршрутизация/туннель | `route get 192.168.128.160` → `ppp0` | корректно |
| Karing-туннель перехватывает корп. трафик | tcpdump на `ppp0` и на Karing-интерфейсе (`utun5`, 10.20.0.1) | корп. трафика на Karing нет (только L2TP/IPsec outer UDP `109.194.204.125:4500` и Telegram) |
| UDP/мультитранспорт | разбор захватов | только TCP 3389, UDP нет |
| Вторая параллельная сессия | `lsof` по процессу клиента | ровно один сокет `192.168.160.192:* -> 192.168.128.160:3389` |
| Клиентский автодетект | `.rdp` с `networkautodetect:i:0`/`bandwidthautodetect:i:0` | без эффекта |
| TLS/протокол | разбор захватов | TLS 1.3, обмен корректный |
| Состояние сервера после ребута (16.09) | LSM / TerminalServices-события, chkdsk | порядок |

## Корневая причина

Клиент **«Windows App»**, а не сервер и не VPN: залип сам **процесс** клиента.
Экземпляр жил ~22 ч (пережил перезагрузку сервера 16.09), и у него заклинило
RDP-стек — каждая попытка вставала в одном и том же месте (после MCS
Channel-Join), Client Info не отправлялся, ровно через 60 с транспорт
закрывался (см. Симптом). В логе также ошибка конечного автомата транспорта:

```
BASIX_DCT(ERR): Stateful object 0x... was destructed while in state Opened(19)
```

**Ложные следы** (присутствуют и в успешном сеансе, к делу не относятся):
`"-legacy-"(ERR): No data of type 0xc09` (`ParseUserData`) и
`PopulateCacCodecCaps failed!`.

Характерная картина — 15 попыток в одном процессе с одинаковым таймаутом
ровно 60 с.

## Фикс

Полный выход из приложения (**Cmd-Q**) и повторный запуск. Тот же клиент сразу
подключился: `state=Connected`, автодетект отработал, канал разогнался до
~26 Мбит/с. Если повторится — достаточно перезапустить приложение.

## Как быстро подтвердить снова (verbose-лог)

```
defaults write com.microsoft.rdc.macos ClientSettings.CoreLogLevel -int 4
defaults write com.microsoft.rdc.macos ClientSettings.UILogLevel  -int 4
# перезапустить «Windows App», воспроизвести проблему
# логи: ~/Library/Containers/com.microsoft.rdc.macos/Data/Library/Logs/Windows App/
```

Признак залипания: `No data of type 0xc09` → через 60 с
`TcpTransportOnClosed ... Operation now in progress`. Вернуть уровень по
умолчанию:

```
defaults delete com.microsoft.rdc.macos ClientSettings.CoreLogLevel
defaults delete com.microsoft.rdc.macos ClientSettings.UILogLevel
```

## Обходной путь на время — `~/bin/rdp` (FreeRDP)

`~/bin/rdp` — обёртка над `/opt/homebrew/bin/sdl-freerdp` 3.31.1 (SDL/metal,
без X11; `xfreerdp` для полной сессии без XQuartz не годится). Пароль — из
login Keychain (service `opencode.rdp`) через `~/bin/keychain-get` и подаётся
клиенту через stdin (`/from-stdin:force`) — в argv, `ps` и историю не попадает.

```
~/bin/rdp --store        # сохранить пароль (нативный промпт, без argv)
~/bin/rdp                # подключиться (testing26.tradesoft.corp, a.koshkin)
~/bin/rdp --fit          # вписать в окно (/smart-sizing +dynamic-resolution)
~/bin/rdp -z 140         # масштаб (/scale, для Retina 140/180)
~/bin/rdp -s 1920x1080   # фиксированный размер (/size)
~/bin/rdp -- -f          # fullscreen
```

## Проверка

- Сервер: LSM Event 25 «Успешное (пере)подключение сеанса», `quser` —
  активная сессия `a.koshkin` (rdp-tcp#0, ID 3), источник 192.168.160.192.
- Клиент: `state=Connected`, `current bandwidth` до ~26 Мбит/с, RTT ~24 мс.

## 27.11.2026: реконнекты при работающем подключении

Другой симптом: сессия идёт, но TCP-транспорт внезапно закрывается
(`TcpTransportOnClosed ... Operation now in progress`), через ~50 с
(`total-missed=5`) клиент объявляет `CMSTATE_DROPPED` и затем reconnect.
Причины — не пароль и не NLA:

- Karing сам перезапускает туннель (~раз в 60–90 мин; 7 раз за день),
  `utun4` пересоздаётся; в логе Windows App в момент обрыва:
  `[NetworkMonitor] ... VPN is inactive, interface: utun4 ... unsatisfied`.
- DNS Karing (`10.20.0.2`) отдаёт для `*.tradesoft.corp` **fake-IP**
  `198.20.0.x`, маршрут идёт через `utun4`; сокет RDP оказывается
  завязан на туннель и рвётся вместе с ним. При резолве в реальный IP
  (`192.168.128.160`) трафик идёт через `en0` и не зависит от Karing.

**Fix:** RDP-хосты прописаны в `RDP_STATIC_IPS` (`corp-networks.conf`);
`karing-rules.sh -i` записывает их в `dns.static_ips` настроек Karing
(файл `karing_setting.json`, вместе с `enable_static_ip=true`). Настройка
переживает рестарт приложения. Править `service_core.json` бесполезно —
Karing перезаписывает его из своей памяти при старте (проверено 27.11).
Дрейф ловится `karing-rules.sh --check`, вотчер чинит его сам.

Проверка: `dscacheutil -q host -a name sup25.tradesoft.corp` →
`192.168.128.160`; `lsof -nP -iTCP:3389 -sTCP:ESTABLISHED` →
`192.168.128.79 -> 192.168.128.160:3389` (интерфейс `en0`, не `utun4`).
`dig @10.20.0.2` может по-прежнему показывать fake-IP — это прямой запрос
к DNS-серверу Karing, системный резолвер использует static_ips.
