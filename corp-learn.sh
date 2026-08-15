#!/bin/sh
#
# corp-learn.sh — автодетект корпоративных сайтов по PTR-записи.
#
# Каждые 10 секунд сканирует установленные исходящие TCP-соединения. Для новых
# внешних IP запрашивает PTR-запись (dig -x); если домен попадает в корпоративную
# зону Tradesoft (DOMAIN_SUFFIX из corp-networks.conf), домен дописывается в
# /usr/local/etc/corp-networks-auto.conf (по одному на строку, без дублей).
#
# Уже маршрутизированные через ppp IP не трогаем (их маршрут держит основной
# демон), а известные домены отсеивает строковая проверка known_domain.
# Основной демон corp-vpn-routes.sh читает auto-конфиг и в течение секунд
# добавляет /32-маршрут через ppp, возвращая его от Karing каждые 5 секунд.
#
# Устанавливается вместе с основным демоном через install.sh.

CONF=/usr/local/etc/corp-networks.conf
AUTO_CONF=/usr/local/etc/corp-networks-auto.conf

# Значения по умолчанию, если CONF не установлен
DOMAIN_SUFFIX=".tradesoft.ru .tradesoft.pro .tradesoft.corp"
SITE_DOMAINS=""

[ -f "$CONF" ] && . "$CONF"

CHECKED=""        # IP, уже проверенные на этой сессии
AUTO_KNOWN=""     # домены из auto-конфига (кэш)
last_auto=0

# Домен в корпоративной зоне?
in_zone() {
  for sfx in $DOMAIN_SUFFIX; do
    case "$1" in
      *"$sfx") return 0 ;;
    esac
  done
  return 1
}

# Приватные/служебные подсети — туда не ходим.
is_private() {
  case "$1" in
    10.*|100.*|127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*) return 0 ;;
  esac
  return 1
}

# Внешние IP установленных / устанавливаемых соединений (только IPv4).
scan_conns() {
  netstat -an -p tcp 2>/dev/null | awk '
    $1 ~ /^tcp/ && ($6 == "ESTABLISHED" || $6 == "SYN_SENT") {
      r = $5
      sub(/\.[0-9]+$/, "", r)
      if (r ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print r
    }' | sort -u
}

# Домен уже известен (в SITE_DOMAINS или в auto-конфиге)?
known_domain() {
  case " $SITE_DOMAINS $AUTO_KNOWN " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

add_auto() {
  d="$1"
  known_domain "$d" && return 0
  grep -qx "$d" "$AUTO_CONF" 2>/dev/null && return 0
  printf '%s\n' "$d" >> "$AUTO_CONF"
  echo "learn: $d -> $AUTO_CONF"
}

while true; do
  now=$(date +%s)

  # Кэш доменов auto-конфига (только чтение локального файла, быстро).
  if [ $((now - last_auto)) -ge 60 ]; then
    last_auto=$now
    AUTO_KNOWN=""
    [ -f "$AUTO_CONF" ] && AUTO_KNOWN=$(grep -vE '^[[:space:]]*(#|$)' "$AUTO_CONF" | tr '\n' ' ')
  fi

  for ip in $(scan_conns); do
    is_private "$ip" && continue
    case " $CHECKED " in *" $ip "*) continue ;; esac
    CHECKED="$CHECKED $ip"
    route -n get "$ip" 2>/dev/null | grep -q 'interface: ppp' && continue
    ptr=$(dig +short +time=1 +tries=1 -x "$ip" 2>/dev/null | head -1)
    [ -n "$ptr" ] || continue
    ptr=${ptr%.}
    if in_zone "$ptr" && ! known_domain "$ptr"; then
      add_auto "$ptr"
    fi
  done

  # Предохранитель от бесконечного роста CHECKED.
  if [ ${#CHECKED} -gt 100000 ]; then
    CHECKED=""
  fi

  sleep 10
done
