#!/bin/sh
# Автозакрытие системной модалки «Подключение VPN — Сервер L2TP-VPN не ответил»
# (даёт neagent/SystemSettings при неудачном дial'е L2TP-профиля; требует OK).
#
# Сценарий (23.10.2026): после пробуждения пользователь вручную подключает VPN
# в System Settings, сервер недоступен → macOS показывает модалку с кнопкой OK,
# и она висит, пока не нажмёшь. Этот свипер, запущенный из wake-хука
# (~/.wakeup), в течение WINDOW_SECS после пробуждения раз в PERIOD ищет
# такое окно среди всех процессов (чисто по заголовку «Подключение VPN») и
# жмёт ему OK. Работает ТОЛЬКО в окне после сна — не фоновый надзор.
#
# Использование: vpn-dialog-sweeper.sh [секунд_окна=600]. Запускать под
# пользователем (UI-автоматизация); вызывает osascript System Events —
# процессы перечисляются по всем окнам, совпадение клика — кнопка «OK».
# Лог: ~/Library/Logs/corp-vpn/dialog-sweeper.log

DUR=${1:-600}
PERIOD=${CORP_DIALOG_PERIOD:-3}
LOGDIR=${CORP_WAKE_LOGDIR:-$HOME/Library/Logs/corp-vpn}
LOG=$LOGDIR/dialog-sweeper.log
PIDFILE=/tmp/corp-vpn-dialog-sweeper.pid

# Одна копия на пробуждение: paralleльный запуск бессмыслен (оба кликают OK —
# безопасно, но шумно в логе).
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    exit 0
fi
echo $$ > "$PIDFILE"

mkdir -p "$LOGDIR" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

# Единый AppleScript-проход. Ваих форма модалки (.capture 26.10.2026, окно
# живо): процесс UserNotificationCenter, окно с ПУСТЫМ заголовком (по нему
# матчить нельзя!), description «предупреждение», внутриh статic-текст
# «Подключение VPN - Сервер L2TP-VPN не ответил…», кнопка «OK». Поэтому
# основной матч — по static-тексту внутри окна + кнопка OK. Фолбэк — старый
# проход по заголовку «Подключение VPN» у всех процессов.
# Ответ: "closed:<process>" | "".
SCAN='
on run
	tell application "System Events"
		-- Основной путь: окно UserNotificationCenter с текстом ошибки L2TP.
		if exists (application process "UserNotificationCenter") then
			repeat with w in (windows of application process "UserNotificationCenter")
				set wtxt to ""
				try
					set wtxt to (value of every static text of w) as string
				end try
				if wtxt contains "Подключение VPN" or wtxt contains "L2TP" then
					try
						click button "OK" of w
						return "closed:UserNotificationCenter"
					end try
				end if
			end repeat
		end if
		-- Фолбэк прежнего вида: по заголовку у любого процесса.
		repeat with pr in (application processes)
			try
				repeat with w in (windows of pr)
					set wn to (name of w) as string
					if wn contains "Подключение VPN" then
						try
							click button "OK" of w
							return "closed:" & (name of pr)
						end try
						try
							click button "OK" of sheet 1 of w
							return "closed-sheet:" & (name of pr)
						end try
					end if
				end repeat
			end try
		end repeat
	end tell
	return ""
end run
'

END=$(( $(date +%s) + DUR ))
log "свипер старт (окно ${DUR}с, период ${PERIOD}с)"
while [ "$(date +%s)" -lt "$END" ]; do
    res=$(/usr/bin/osascript -e "$SCAN" 2>/dev/null)
    case "$res" in
        closed:*) log "закрыл модалку VPN (${res#closed:})" ;;
        closed-sheet:*) log "закрыл sheet-модалку VPN (${res#closed-sheet:})" ;;
    esac
    sleep "$PERIOD"
done
log "свипер завершился (${DUR}с)"
rm -f "$PIDFILE"
