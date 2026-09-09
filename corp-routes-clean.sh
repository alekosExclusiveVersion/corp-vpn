#!/bin/sh

# Демон очистки «мёртвых» маршрутов (root, LaunchDaemon com.tradesoft.corp-routes-clean).
# Следит за маршрутной таблицей и удаляет опасные записи, которые ломают
# связь корп. ресурсов и интернет-доменов через Karing.
#
# Сценарии (выявлены 09.09.2026):
#   A) fake-IP пулы Karing (198.18.0.0/15, 198.20.0.0/15) через НЕ-туннельные
#      интерфейсы (en0/ppp0). Такие /32 «живут» только внутри utun4/utun10:
#      через физический интерфейс они ведут трафик в никуда (HTTP 000).
#      Удаляем СРАЗУ — безопасно: при активном Karing пакет всё равно уходит
#      в tunnel по default, Karing пересоздаст корректный /32 на utun.
#   B) корп. host-маршруты (10/8, 192.168/16) через физический интерфейс
#      (en*) ВНЕ его собственной on-link подсети. Пример: 192.168.128.123
#      (sup5) через en0, когда текущая сеть не 192.168.128.0/24 — шлюза нет,
#      sup5 недосягаем, пока не стоит маршрут через ppp0. Удаляем ПО 2 СНИМКАМ
#      (защита от раскачки при смене сетей/DHCP).
#
# Запуск:  sudo ./corp-routes-clean.sh          # демон (root)
# Проверка: ./corp-routes-clean.sh --dry-run    # только печатает находки

CONF=${CORP_ROUTES_CLEAN_CONF:-/usr/local/etc/corp-networks.conf}
LOG=${CORP_ROUTES_CLEAN_LOG:-/var/log/corp-routes-clean.log}
PREV=${CORP_ROUTES_CLEAN_PREV:-/var/run/corp-routes-clean.prev}
CUR=${CORP_ROUTES_CLEAN_CUR:-/var/run/corp-routes-clean.cur}
SIGNALS=${CORP_SIGNALS:-/var/run/corp-vpn-signals}

# Пулды fake-IP Karing (можно переопределить в corp-networks.conf: FAKEIP_ROUTES=...)
FAKEIP_ROUTES="198.18.0.0/15 198.20.0.0/15"
# Корп. диапазоны для сценария B (берём NET_ROUTES из конфига, если задан)
CORP_ROUTES="10.0.0.0/8 192.168.0.0/16"

if [ -f "$CONF" ]; then
  . "$CONF"
  [ -n "${FAKEIP_ROUTES:-}" ] && FAKEIP_ROUTES="$FAKEIP_ROUTES"
  [ -n "${NET_ROUTES:-}" ] && CORP_ROUTES="$NET_ROUTES"
fi

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
esac

if [ "$(id -u)" -ne 0 ] && [ "$DRY" -eq 0 ]; then
  echo "Требуются права root (или запусти с --dry-run для проверки)" >&2
  exit 1
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
  if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 1000 ]; then
    tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

# Сигнальная очередь для юзер-агента уведомлений (corp-notify.sh).
# Строка: ts|event|message. Ротация: при >200 строк оставляем последние 100.
signal() {
  line="$(date '+%Y-%m-%d %H:%M:%S')|$1|$2"
  echo "$line" >> "$SIGNALS"
  if [ -f "$SIGNALS" ] && [ "$(wc -l < "$SIGNALS")" -gt 200 ]; then
    tail -100 "$SIGNALS" > "$SIGNALS.tmp" && mv "$SIGNALS.tmp" "$SIGNALS"
  fi
}

ip2int() {
  IFS=. read -r a b c d <<EOF
$1
EOF
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# le: 1 если ip находится в подсети net/cidr, иначе 0
ip_in_cidr() {
  ip=$1
  net=$2
  cidr=$3
  bip=$(ip2int "$ip")
  bnet=$(ip2int "$net")
  mask=$(( 0xffffffff << (32 - cidr) ))
  if [ $(( bip & mask )) -eq $(( bnet & mask )) ]; then
    return 0
  fi
  return 1
}

# Действие: удалить host-маршрут (в dry-run только печатаем и логируем)
kill_route() {
  ip=$1
  why=$2
  if [ "$DRY" -eq 1 ]; then
    echo "DRY: delete -host $ip ($why)"
    log "DRY: delete -host $ip ($why)"
    return 0
  fi
  if route -n delete -host "$ip" >/dev/null 2>&1; then
    log "deleted $ip ($why)"
    signal "routes-dead.del" "deleted $ip ($why)"
  else
    log "FAILED delete $ip ($why)"
    signal "routes-dead.fail" "FAILED delete $ip ($why)"
  fi
}

# --- Проход сценария A: fake-IP через НЕ-utun -------------------------------
# netstat -rn -f inet:  dest  gateway  flags  iface
clean_fakeip() {
  netstat -rn -f inet 2>/dev/null |
    awk '{print $1, $NF}' |
    while read -r ip ifc; do
      case "$ifc" in utun*) continue ;; esac
      case "$ifc" in en*|ppp*|eth*|wi*|awdl*|lo0) : ;; *) continue ;; esac
      ok=0
      for r in $FAKEIP_ROUTES; do
        net=${r%/*}
        cidr=${r##*/}
        if ip_in_cidr "$ip" "$net" "$cidr"; then ok=1; break; fi
      done
      [ "$ok" -eq 1 ] || continue
      kill_route "$ip" "fakeip через $ifc (не utun)"
    done
}

# --- Проход сценария B: корп. host-маршрут через физический интерфейс -------
en0_ip() { ipconfig getifaddr en0 2>/dev/null; }

clean_corp_hosts() {
  en0ip=$(en0_ip)
  en0subnet=""
  [ -n "$en0ip" ] && en0subnet=$(printf '%s' "$en0ip" | cut -d. -f1-3).0

  : > "$CUR"
  netstat -rn -f inet 2>/dev/null |
    while read -r dest gw flags ifc rest; do
      # подходит host-маршрут (флаг H), через физический интерфейс (en*/wl*), вне корп.
      case "$ifc" in utun*) continue ;; esac
      case "$flags" in
        *H*) : ;;
        *) continue ;;
      esac
      case "$ifc" in
        en*|wl*|wi*) : ;;
        *) continue ;;
      esac
      case "$dest" in
        *.*.*.*) : ;;
        *) continue ;;
      esac
      # должен быть корп. диапазон
      ok=0
      for r in $CORP_ROUTES; do
        net=${r%/*}
        cidr=${r##*/}
        if ip_in_cidr "$dest" "$net" "$cidr"; then ok=1; break; fi
      done
      [ "$ok" -eq 1 ] || continue
      # легитимно, если IP лежит в собственной on-link подсети en0
      if [ -n "$en0subnet" ] && [ "${dest%.*}.0" = "$en0subnet" ]; then
        continue
      fi
      printf '%s\n' "$dest" >> "$CUR"
    done

  # Удаляем только то, что видели в ДВУХ снимках подряд (PREV и CUR)
  if [ -f "$PREV" ]; then
    while IFS= read -r ip; do
      [ -n "$ip" ] || continue
      grep -qx "$ip" "$CUR" && kill_route "$ip" "corp host через en* вне on-link"
    done < "$PREV"
  fi
  mv -f "$CUR" "$PREV"
}

log "Starting corp-routes-clean.sh (dry=${DRY})"
rm -f "$PREV" "$CUR"

while true; do
  clean_fakeip
  clean_corp_hosts
  sleep 15
done