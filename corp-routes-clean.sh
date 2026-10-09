#!/bin/sh

# Демон очистки «мёртвых» маршрутов (root, LaunchDaemon com.tradesoft.corp-routes-clean).
# Следит за маршрутной таблицей и удаляет опасные записи, которые ломают
# связь корп. ресурсов и интернет-доменов через Karing.
#
# Сценарии (A, B выявлены 09.09.2026; C — 30.09.2026):
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
#   C) host-маршрут с ФАНТОМНЫМ шлюзом из пула fake-IP Karing на НЕ-туннельном
#      интерфейсе. Инцидент 30.09.2026 (p7ru5, битый маршрут висел ~22 ч):
#        212.41.11.239   198.20.0.35   UHS   en0      <- dst реален, gw фантомный
#      ARP-записи для 198.20.0.35 не существует, поэтому пакет через физический
#      интерфейс fake-IP доставлен быть не может; соседний 212.41.10.102 из
#      того же /16 в это время работал через utun (3306 открыт), то есть дело
#      было не в сервере, а в маршруте. Назначение, которое само лежит в
#      fake-IP, — это сценарий A; здесь оно пропускается, чтобы не удалять дважды.
#      Учитываем ТОЛЬКО по 2 снимкам подряд, как сценарий B.
#
# Режимы:
#   sudo ./corp-routes-clean.sh                 # демон (root), сценарий C = аналитика
#   ./corp-routes-clean.sh --check              # один проход, ТОЛЬКО ЧТЕНИЕ, без записи
#   ./corp-routes-clean.sh --dry-run [--once]   # без root, ничего не удаляет, своё состояние
#   sh ./corp-routes-clean.sh --selftest        # фикстуры: без root, без сети, без правок
#
# ВАЖНО: сценарий C по умолчанию НЕ удаляет маршруты (PHANTOM_DELETE=0).
# Автор битой записи не установлен (corp-wifi-routes.sh внутренние IP не ставит,
# corp-vpn-routes.sh резолвит через Karing-фильтр), поэтому автоудаление по
# неисследованному классу маршрутов опаснее, чем само нарушение. По умолчанию
# сценарий только пишет в лог PHANTOM new / confirmed / gone на переходах —
# это дешёвый пассивный детектор. Включение удаления — осознанно и вручную:
#   sudo ./corp-routes-clean.sh --once --enable-phantom-delete

CONF=${CORP_ROUTES_CLEAN_CONF:-/usr/local/etc/corp-networks.conf}
LOG=${CORP_ROUTES_CLEAN_LOG:-/var/log/corp-routes-clean.log}
PREV=${CORP_ROUTES_CLEAN_PREV:-/var/run/corp-routes-clean.prev}
CUR=${CORP_ROUTES_CLEAN_CUR:-/var/run/corp-routes-clean.cur}
PG_PREV=${CORP_ROUTES_CLEAN_PGPREV:-/var/run/corp-routes-clean.phantom.prev}
PG_CUR=${CORP_ROUTES_CLEAN_PGCUR:-/var/run/corp-routes-clean.phantom.cur}
SIGNALS=${CORP_SIGNALS:-/var/run/corp-vpn-signals}
# Состояние и лог ручных прогонов: демон и человек не должны мешать друг другу
# записями в общие PREV/CUR (это ломает двухснимковый гейт).
DRY_STATE=${CORP_ROUTES_CLEAN_DRY_STATE:-/tmp/corp-routes-clean.dry}
DRY_LOG=${CORP_ROUTES_CLEAN_DRY_LOG:-/tmp/corp-routes-clean.dry.log}
# Сценарий C: удалять (1) или только наблюдать (0, по умолчанию).
PHANTOM_DELETE=${CORP_ROUTES_CLEAN_DELETE_PHANTOM:-0}

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
CHECK=0
ONCE=0
SELFTEST=0
ST_TMP=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)                DRY=1 ;;
    --check)                  CHECK=1; ONCE=1 ;;
    --once)                   ONCE=1 ;;
    --enable-phantom-delete)  PHANTOM_DELETE=1 ;;
    --selftest|--self-test)   SELFTEST=1 ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Неизвестный аргумент: $arg (--help)" >&2
      exit 2 ;;
  esac
done

# В режиме --check ничего не пишем и ничего не удаляем: он читает таблицу один
# раз, держит состояние во временном каталоге, а kill_route переводит в DRY.
if [ "$CHECK" -eq 1 ]; then
  DRY=1
  ST_TMP=$(mktemp -d 2>/dev/null || echo "/tmp/corp-routes-clean-check.$$")
  mkdir -p "$ST_TMP" 2>/dev/null
  LOG="$ST_TMP/unused.log"
  PREV="$ST_TMP/prev"
  CUR="$ST_TMP/cur"
  PG_PREV="$ST_TMP/phantom.prev"
  PG_CUR="$ST_TMP/phantom.cur"
  SIGNALS="$ST_TMP/signals"
# Ручной --dry-run: своё состояние в /tmp, свой лог (лог демона — root'овый).
elif [ "$DRY" -eq 1 ]; then
  mkdir -p "$DRY_STATE" 2>/dev/null
  LOG="$DRY_LOG"
  PREV="$DRY_STATE/prev"
  CUR="$DRY_STATE/cur"
  PG_PREV="$DRY_STATE/phantom.prev"
  PG_CUR="$DRY_STATE/phantom.cur"
  SIGNALS="$DRY_STATE/signals"
fi

if [ "$(id -u)" -ne 0 ] && [ "$DRY" -eq 0 ] && [ "$SELFTEST" -eq 0 ]; then
  echo "Требуются права root (или запусти с --dry-run/--check для проверки)" >&2
  exit 1
fi

log() {
  if [ "$CHECK" -eq 1 ]; then
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    return 0
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
  if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 1000 ]; then
    tail -500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

# Сигнальная очередь для юзер-агента уведомлений (corp-notify.sh).
# Строка: ts|event|message. Ротация: при >200 строк оставляем последние 100.
signal() {
  line="$(date '+%Y-%m-%d %H:%M:%S')|$1|$2"
  echo "$line" >> "$SIGNALS" 2>/dev/null
  if [ -f "$SIGNALS" ] && [ "$(wc -l < "$SIGNALS" 2>/dev/null)" -gt 200 ]; then
    tail -100 "$SIGNALS" > "$SIGNALS.tmp" 2>/dev/null && mv "$SIGNALS.tmp" "$SIGNALS"
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

# Строгий разбор IPv4: четыре числовых октета 0..255, без мусора из netstat.
# Нужен, чтобы классификаторы получали только адреса: иначе ip2int молча
# считает мусор нулём, и границы подсетей проверяются не тем, чем кажутся.
is_ipv4() {
  case "$1" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  st_old_ifs=$IFS
  IFS=.
  set -- $1
  IFS=$st_old_ifs
  [ $# -eq 4 ] || return 1
  for st_oct in "$@"; do
    [ -n "$st_oct" ] || return 1
    [ "$st_oct" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

# Адрес принадлежит одному из пулов fake-IP Karing.
in_fakeip() {
  is_ipv4 "$1" || return 1
  for r in $FAKEIP_ROUTES; do
    net=${r%/*}
    cidr=${r##*/}
    if ip_in_cidr "$1" "$net" "$cidr"; then return 0; fi
  done
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
      in_fakeip "$ip" || continue
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

# --- Сценарий C: host-маршрут с фантомным шлюзом из пула fake-IP ------------
# Предикат чистый (без побочных эффектов), его гоняет selftest на фикстурах.
is_phantom_gw() { # <dest> <gw> <flags> <ifc>
  pg_d=$1
  pg_g=$2
  pg_f=$3
  pg_i=$4
  is_ipv4 "$pg_d" || return 1
  # link#N, пусто и т.п. — это не IP-шлюз, а такое в fake-IP не попадает
  is_ipv4 "$pg_g" || return 1
  # только host-маршрут: сетевой (без H) и default удалять нельзя
  case "$pg_f" in *H*) : ;; *) return 1 ;; esac
  case "$pg_i" in
    utun*|lo0) return 1 ;;
    en*|ppp*|eth*|wi*|awdl*|bridge*) : ;;
    *) return 1 ;;
  esac
  # назначение в fake-IP — это сценарий A, здесь пропускаем (нет двойного удаления)
  in_fakeip "$pg_d" && return 1
  in_fakeip "$pg_g" || return 1
  return 0
}

# Кандидаты сценария C в текущем снимке, по строке на маршрут:
# "dest gw flags ifc" — строки сравниваются целиком, поэтому смена флагов
# или интерфейса сама по себе не подтверждает кандидата.
collect_phantom_gw() {
  : > "$PG_CUR"
  netstat -rn -f inet 2>/dev/null |
    while read -r pg_dest pg_gw pg_flags pg_ifc pg_rest; do
      [ -n "${pg_dest:-}" ] || continue
      is_phantom_gw "$pg_dest" "$pg_gw" "$pg_flags" "$pg_ifc" || continue
      printf '%s %s %s %s\n' "$pg_dest" "$pg_gw" "$pg_flags" "$pg_ifc" >> "$PG_CUR"
    done
}

clean_phantom_gw() {
  collect_phantom_gw
  if [ -f "$PG_PREV" ]; then
    # События только на переходе, иначе каждые 15 с получим 2 строки шума.
    while IFS= read -r pg_row; do
      [ -n "$pg_row" ] || continue
      grep -qxF "$pg_row" "$PG_CUR" 2>/dev/null && continue
      log "PHANTOM gone: $pg_row"
    done < "$PG_PREV"
    while IFS= read -r pg_row; do
      [ -n "$pg_row" ] || continue
      grep -qxF "$pg_row" "$PG_PREV" 2>/dev/null && continue
      log "PHANTOM new: $pg_row (1/2)"
    done < "$PG_CUR"
    # Действие только по ДВУМ снимкам подряд: переходный маршрут не трогаем.
    while IFS= read -r pg_row; do
      [ -n "$pg_row" ] || continue
      grep -qxF "$pg_row" "$PG_CUR" 2>/dev/null || continue
      if [ "$PHANTOM_DELETE" -eq 1 ]; then
        kill_route "${pg_row%% *}" "phantom gw $pg_row"
      else
        log "PHANTOM confirmed 2/2: $pg_row (delete DISABLED, аналитика)"
      fi
    done < "$PG_PREV"
  else
    while IFS= read -r pg_row; do
      [ -n "$pg_row" ] || continue
      log "PHANTOM new: $pg_row (1/2)"
    done < "$PG_CUR"
  fi
  mv -f "$PG_CUR" "$PG_PREV"
}

scan_once() {
  clean_fakeip
  clean_corp_hosts
  clean_phantom_gw
}

# --- selftest: регрессия на фикстурах (без root, без сети, без правок) ------
# --- selftest: регрессия на фикстурах (без root, без сети, без правок) ------
# Заглушки затеняют одноимённые команды (в скрипте они зовутся без абсолютных
# путей), поэтому исполняется настоящий код на подставных данных, а не копия
# логики. route() не удаляет ничего, а пишет вызов в файл: если забытый путь
# дойдёт до route delete, это видно по содержимому файла и по счётчику.
selftest() {
  self_path=$1
  st_pass=0
  st_fail=0
  st_tmp=$(mktemp -d 2>/dev/null) || st_tmp="/tmp/corp-routes-clean-selftest.$$"
  mkdir -p "$st_tmp" 2>/dev/null

  t() { # t <описание> <0=ok/иное=fail>
    if [ "$2" = "0" ]; then
      printf '[PASS] %s\n' "$1"; st_pass=$((st_pass + 1))
    else
      printf '[FAIL] %s\n' "$1"; st_fail=$((st_fail + 1))
    fi
  }
  teq() { # teq <описание> <ожидаемое> <фактическое>
    if [ "$2" = "$3" ]; then t "$1" 0
    else t "$1 — ожидалось [$2], получено [$3]" 1; fi
  }

  netstat()  { printf '%s\n' "$ST_NETSTAT"; }
  route()    { printf 'route %s\n' "$*" >> "$st_tmp/route.calls"; return 0; }
  ipconfig() { printf '%s\n' "$ST_EN0_IP"; }
  logger()   { return 0; }
  sleep()    { :; }

  # Изолируемся от живой системы: конфиг не читаем, все файлы — во временный каталог.
  CONF=$st_tmp/no-such.conf
  FAKEIP_ROUTES="198.18.0.0/15 198.20.0.0/15"
  CORP_ROUTES="10.0.0.0/8 192.168.0.0/16"
  LOG=$st_tmp/log
  PREV=$st_tmp/prev
  CUR=$st_tmp/cur
  PG_PREV=$st_tmp/phantom.prev
  PG_CUR=$st_tmp/phantom.cur
  SIGNALS=$st_tmp/signals
  DRY=0
  CHECK=0
  PHANTOM_DELETE=0
  ST_NETSTAT=""
  ST_EN0_IP="192.168.31.5"

  # Каждый блок начинается с чистого состояния: иначе таблица одной фикстуры
  # протекает в следующую и тест проверяет не то.
  st_reset() {
    rm -f "$LOG" "$PREV" "$CUR" "$PG_PREV" "$PG_CUR" "$SIGNALS" "$st_tmp/route.calls"
    : > "$st_tmp/route.calls"
    ST_EN0_IP="192.168.31.5"
    DRY=0
    CHECK=0
    PHANTOM_DELETE=0
  }
  st_calls() { [ -f "$st_tmp/route.calls" ] && wc -l < "$st_tmp/route.calls" | tr -d ' '; }
  st_cnt()   { if [ -f "$1" ]; then grep -c "$2" "$1" 2>/dev/null | tr -d ' '; else printf 0; fi; }
  st_has()   { grep -qxF "$2" "$1" 2>/dev/null && printf yes || printf no; }

  # --- фикстуры ---
  # F_INCIDENT: таблица, повторяющая инцидент p7ru5 (30.09.2026) плюс штатные
  # записи. Кандидаты сценария C: p7ru5 (en0, шлюз 198.20.0.35) и 10.20.0.9
  # (ppp0, шлюз из второго пула 198.18.0.0/15).
  st_fixture_incident() {
    ST_NETSTAT="Routing tables

Destination        Gateway            Flags        Netif Expire
default            10.34.174.1        UGScg           en0
default            10.20.0.1          UGScg           utun7
127                127.0.0.1          UCS             lo0
127.0.0.1          127.0.0.1          UH              lo0
10.20.0.1          10.34.174.97       UHS             utun7
192.168.0.0/16     10.20.0.1          UG              utun7
192.168.0.210      10.20.0.1          UG              utun7
198.20.0.8         link#14            UHS             utun7
198.20.0.40        10.20.0.1          UHS             utun7
212.41.10.102      198.20.0.34        UHS             utun7
212.41.11.239      198.20.0.35        UHS             en0
212.41.10.103      192.168.31.1       UHS             en0
198.20.0.11        192.168.31.1       UHS             en0
198.20.0.36        link#9             UHS             en0
10.20.0.9          198.18.7.9         UHS             ppp0
192.168.128.123    192.168.31.1       UHS             en0"
  }
  # F_CLEAN: обычная таблица без кандидатов C (всё, что было с p7ru5, ушло в utun).
  st_fixture_clean() {
    ST_NETSTAT="Routing tables

Destination        Gateway            Flags        Netif Expire
default            10.34.174.1        UGScg           en0
default            10.20.0.1          UGScg           utun7
127.0.0.1          127.0.0.1          UH              lo0
10.20.0.1          10.34.174.97       UHS             utun7
192.168.0.0/16     10.20.0.1          UG              utun7
198.20.0.8         link#14            UHS             utun7
212.41.10.102      198.20.0.34        UHS             utun7
212.41.11.239      198.20.0.34        UHS             utun7
212.41.10.103      192.168.31.1       UHS             en0
198.20.0.11        192.168.31.1       UHS             en0
198.20.0.36        link#9             UHS             en0
192.168.128.123    192.168.31.1       UHS             en0"
  }

  # 1. синтаксис
  sh -n "$self_path" 2>/dev/null; t "syntax: sh -n" "$?"

  # 2. is_ipv4: мусор из netstat обязан отвергаться, иначе ip2int считает его нулём
  is_ipv4 198.20.0.35;  t "is_ipv4 198.20.0.35" "$?"
  is_ipv4 0.0.0.0;     t "is_ipv4 0.0.0.0" "$?"
  is_ipv4 255.255.255.255; t "is_ipv4 255.255.255.255" "$?"
  for st_bad in '' '198.20.0' '198.20.0.35.1' '198.20.0.256' '198.20..35' \
                'a.b.c.d' '198.20.0.x' 'default' 'link#14' '198.20.0.-1'; do
    is_ipv4 "$st_bad"; [ $? -ne 0 ]; t "is_ipv4 отвергает [$st_bad]" "$?"
  done

  # 3. in_fakeip: оба пула и границы /15
  in_fakeip 198.20.0.35;    t "in_fakeip 198.20.0.35 (пул 198.20.0.0/15)" "$?"
  in_fakeip 198.18.7.9;     t "in_fakeip 198.18.7.9 (пул 198.18.0.0/15)" "$?"
  in_fakeip 198.21.255.255; t "in_fakeip 198.21.255.255 (верхняя граница /15)" "$?"
  in_fakeip 198.19.0.0;     t "in_fakeip 198.19.0.0 (середина 198.18/15)" "$?"
  in_fakeip 198.22.0.0;     [ $? -ne 0 ]; t "in_fakeip 198.22.0.0 вне пулов" "$?"
  in_fakeip 198.17.255.255; [ $? -ne 0 ]; t "in_fakeip 198.17.255.255 вне пулов" "$?"
  in_fakeip 212.41.11.239;  [ $? -ne 0 ]; t "in_fakeip реальный IP" "$?"
  in_fakeip 'link#14';     [ $? -ne 0 ]; t "in_fakeip отвергает link#14" "$?"

  # 4. Предикат C: инцидент обязан быть кандидатом
  is_phantom_gw 212.41.11.239 198.20.0.35 UHS en0;    t "C: инцидент p7ru5 = кандидат" "$?"
  is_phantom_gw 10.20.0.9 198.18.7.9 UHS ppp0;         t "C: второй пул fake-IP через ppp0" "$?"
  is_phantom_gw 212.41.11.239 198.21.255.255 UHS en0; t "C: верхняя граница 198.21/15" "$?"

  # 5. Предикат C: то, что трогать нельзя
  is_phantom_gw 212.41.11.239 192.168.31.1 UHS en0;    [ $? -ne 0 ]; t "C: настоящий шлюз не кандидат" "$?"
  is_phantom_gw 212.41.11.239 'link#9' UHS en0;        [ $? -ne 0 ]; t "C: link#9 вместо шлюза" "$?"
  is_phantom_gw 212.41.11.239 '' UHS en0;              [ $? -ne 0 ]; t "C: пустой шлюз" "$?"
  is_phantom_gw 212.41.11.239 198.20.0.35 UHS utun7;   [ $? -ne 0 ]; t "C: маршрут через utun" "$?"
  is_phantom_gw 212.41.11.239 198.20.0.35 UHS lo0;    [ $? -ne 0 ]; t "C: маршрут через lo0" "$?"
  is_phantom_gw default 198.20.0.35 UGScg en0;        [ $? -ne 0 ]; t "C: default без флага H" "$?"
  is_phantom_gw 212.41.11.0 198.20.0.35 UG en0;        [ $? -ne 0 ]; t "C: сетевой маршрут без H" "$?"
  is_phantom_gw 198.20.0.11 198.20.0.35 UHS en0;      [ $? -ne 0 ]; t "C: dst в fake-IP — это сценарий A" "$?"
  is_phantom_gw 198.20.0.35 198.20.0.35 UHS en0;      [ $? -ne 0 ]; t "C: dst == gw в fake-IP — сценарий A" "$?"
  is_phantom_gw 212.41.11.239 198.22.0.0 UHS en0;     [ $? -ne 0 ]; t "C: шлюз вне пулов (198.22)" "$?"
  is_phantom_gw 212.41.11.239 198.17.255.255 UHS en0; [ $? -ne 0 ]; t "C: шлюз вне пулов (198.17)" "$?"
  is_phantom_gw 'default' 198.20.0.35 UHS en0;        [ $? -ne 0 ]; t "C: назначение не IPv4" "$?"
  is_phantom_gw 212.41.11.239 198.20.0.35 UHS utun;   [ $? -ne 0 ]; t "C: неизвестный интерфейс отвергнут" "$?"

  # 6. Сценарий C на инцидентной фикстуре: 1-й снимок только наблюдает
  st_reset
  st_fixture_incident
  clean_phantom_gw
  teq "C: 1-й снимок — route не вызывается" "0" "$(st_calls)"
  teq "C: 1-й снимок — p7ru5 в состоянии" "yes" \
    "$(st_has "$PG_PREV" '212.41.11.239 198.20.0.35 UHS en0')"
  teq "C: 1-й снимок — ppp0-строка в состоянии" "yes" \
    "$(st_has "$PG_PREV" '10.20.0.9 198.18.7.9 UHS ppp0')"
  teq "C: 1-й снимок — честный utun-маршрут не кандидат" "no" \
    "$(st_has "$PG_PREV" '212.41.10.102 198.20.0.34 UHS utun7')"
  teq "C: 1-й снимок — маршрут с настоящим шлюзом не кандидат" "no" \
    "$(st_has "$PG_PREV" '212.41.10.103 192.168.31.1 UHS en0')"
  teq "C: 1-й снимок — подтверждения ещё нет" "0" "$(st_cnt "$LOG" 'PHANTOM confirmed')"
  teq "C: 1-й снимок — 2 события new" "2" "$(st_cnt "$LOG" 'PHANTOM new')"

  # 7. Второй снимок: кандидат подтверждён, удаления нет (PHANTOM_DELETE=0)
  clean_phantom_gw
  teq "C: 2-й снимок — route не вызывается (режим аналитики)" "0" "$(st_calls)"
  teq "C: 2-й снимок — p7ru5 подтверждён 2/2" "1" \
    "$(st_cnt "$LOG" 'PHANTOM confirmed 2/2: 212.41.11.239 198.20.0.35 UHS en0')"
  teq "C: 2-й снимок — ppp0-строка подтверждена 2/2" "1" \
    "$(st_cnt "$LOG" 'PHANTOM confirmed 2/2: 10.20.0.9 198.18.7.9 UHS ppp0')"
  teq "C: 2-й снимок — 'new' не повторяется (нет шума каждые 15 с)" "2" \
    "$(st_cnt "$LOG" 'PHANTOM new')"
  teq "C: подтверждение помечено как аналитика" "2" "$(st_cnt "$LOG" 'delete DISABLED')"

  # 8. Кандидат ушёл из таблицы — событие gone, удаления нет
  st_fixture_clean
  clean_phantom_gw
  teq "C: после ухода маршрута route не вызывается" "0" "$(st_calls)"
  teq "C: уход p7ru5 зафиксирован" "1" \
    "$(st_cnt "$LOG" 'PHANTOM gone: 212.41.11.239 198.20.0.35 UHS en0')"
  teq "C: уход ppp0-строки зафиксирован" "1" \
    "$(st_cnt "$LOG" 'PHANTOM gone: 10.20.0.9 198.18.7.9 UHS ppp0')"
  teq "C: после ухода в состоянии пусто" "" "$(cat "$PG_PREV")"
  st_fixture_incident
  clean_phantom_gw
  clean_phantom_gw
  teq "C: возврат маршрута = снова 1/2, а не мгновенное удаление" "0" "$(st_calls)"
  teq "C: возврат маршрута отмечен как new (вместе с первым появлением)" "2" \
    "$(st_cnt "$LOG" 'PHANTOM new: 212.41.11.239 198.20.0.35 UHS en0 (1/2)')"

  # 9. Включённое удаление: 1-й снимок молчит, 2-й сносит обоих кандидатов
  st_reset
  st_fixture_incident
  PHANTOM_DELETE=1
  clean_phantom_gw
  teq "C: удаление включено, 1-й снимок — тишина" "0" "$(st_calls)"
  clean_phantom_gw
  teq "C: удаление включено, 2-й снимок — ровно 2 route" "2" "$(st_calls)"
  teq "C: удаление включено — снесены оба кандидата" \
    "route -n delete -host 212.41.11.239
route -n delete -host 10.20.0.9" "$(cat "$st_tmp/route.calls")"
  teq "C: причина в логе содержит всю строку маршрута" "1" \
    "$(st_cnt "$LOG" 'deleted 212.41.11.239 (phantom gw 212.41.11.239 198.20.0.35 UHS en0)')"
  teq "C: уведомление routes-dead.del ушло на каждый маршрут" "2" \
    "$(st_cnt "$SIGNALS" 'routes-dead.del')"

  # 10. dry-run: решение печатается, таблица не трогается
  st_reset
  st_fixture_incident
  DRY=1
  PHANTOM_DELETE=1
  clean_phantom_gw >/dev/null
  clean_phantom_gw >/dev/null
  teq "C: dry-run — route не вызывается" "0" "$(st_calls)"
  teq "C: dry-run — напечатаны оба решения" "2" \
    "$(st_cnt "$LOG" 'DRY: delete -host')"
  teq "C: dry-run — в логе нет реального удаления" "0" \
    "$(st_cnt "$LOG" 'deleted ')"
  teq "C: dry-run — уведомлений нет" "0" "$(st_cnt "$SIGNALS" 'routes-dead')"

  # 11. Одиночный кандидат: сносится только он
  st_reset
  st_fixture_incident
  ST_NETSTAT=$(printf '%s' "$ST_NETSTAT" | /usr/bin/grep -v '^10\.20\.0\.9')
  PHANTOM_DELETE=1
  clean_phantom_gw
  clean_phantom_gw
  teq "C: одиночный кандидат — ровно один route" "1" "$(st_calls)"
  teq "C: одиночный кандидат — адрес p7ru5" \
    "route -n delete -host 212.41.11.239" "$(cat "$st_tmp/route.calls")"

  # 12. Регрессия сценария A: поведение 09.09.2026 не меняем
  st_reset
  st_fixture_incident
  clean_fakeip
  teq "A: fake-IP /32 через en0 (ip-gw и link#) — оба" \
    "route -n delete -host 198.20.0.11
route -n delete -host 198.20.0.36" "$(cat "$st_tmp/route.calls")"
  st_reset
  st_fixture_clean
  clean_fakeip
  teq "A: fake-IP через en0 на чистой таблице — те же два" \
    "route -n delete -host 198.20.0.11
route -n delete -host 198.20.0.36" "$(cat "$st_tmp/route.calls")"
  st_reset
  ST_NETSTAT="Routing tables
default            10.20.0.1          UGScg           utun7
198.20.0.8         link#14            UHS             utun7
198.20.0.40        10.20.0.1          UHS             utun7
198.18.4.4         link#9             UHS             en0"
  clean_fakeip
  teq "A: fake-IP из второго пула через en0 тоже сносится" \
    "route -n delete -host 198.18.4.4" "$(cat "$st_tmp/route.calls")"

  # 13. Регрессия сценария B: вне on-link — по 2 снимкам, в on-link — не трогаем
  st_reset
  st_fixture_incident
  clean_corp_hosts
  clean_corp_hosts
  teq "B: 192.168.128.123 вне on-link сносится на 2-м снимке" \
    "route -n delete -host 192.168.128.123" "$(cat "$st_tmp/route.calls")"
  st_reset
  st_fixture_incident
  ST_EN0_IP="192.168.128.56"
  clean_corp_hosts
  clean_corp_hosts
  teq "B: 192.168.128.123 в своей on-link /24 — не трогаем" "" \
    "$(cat "$st_tmp/route.calls")"
  st_reset
  st_fixture_incident
  clean_corp_hosts
  teq "B: 1-й снимок — только наполнение состояния" "0" "$(st_calls)"

  # 14. Сценарии A и B не трогают ppp0-кандидат сценария C
  st_reset
  ST_NETSTAT="Routing tables
default            10.20.0.1          UGScg           utun7
10.20.0.1          10.20.0.2          UHS             utun7
10.20.0.9          198.18.7.9         UHS             ppp0"
  clean_fakeip
  clean_corp_hosts
  teq "A/B: ppp0-кандидат сценария C не тронут" "" "$(cat "$st_tmp/route.calls")"
  st_reset
  ST_NETSTAT="Routing tables
default            10.20.0.1          UGScg           utun7
10.20.0.9          198.18.7.9         UHS             ppp0"
  PHANTOM_DELETE=1
  clean_phantom_gw
  clean_phantom_gw
  teq "C: ppp0-кандидат ловится даже без записей fake-IP в таблице" "1" "$(st_calls)"

  # 15. --check не пишет на диск, вывод идёт в stdout
  st_reset
  st_fixture_clean
  CHECK=1
  LOG=$st_tmp/check.log
  st_out=$(clean_phantom_gw 2>/dev/null)
  if [ -e "$st_tmp/check.log" ]; then t "check: лог-файл не создаётся" 1
  else t "check: лог-файл не создаётся" 0; fi
  teq "check: чистая таблица — кандидатов нет" "" "$st_out"
  st_reset
  st_fixture_incident
  CHECK=1
  LOG=$st_tmp/check.log
  st_out=$(clean_phantom_gw 2>/dev/null)
  teq "check: кандидат печатается в stdout" "1" \
    "$(printf '%s' "$st_out" | grep -c 'PHANTOM new: 212.41.11.239')"
  CHECK=0
  LOG=$st_tmp/log

  # 16. --check отдельным процессом: без root, только чтение живой таблицы
  st_out=$(CORP_ROUTES_CLEAN_CONF=$st_tmp/no-such.conf sh "$self_path" --check 2>&1)
  t "check: отдельный процесс завершился успешно (rc=0)" "$?"
  teq "check: вывод содержит штамп проверки" "1" \
    "$(printf '%s' "$st_out" | grep -c 'read-only check')"
  teq "check: --check не требует root" "0" \
    "$(printf '%s' "$st_out" | grep -c 'Требуются права root')"
  teq "check: реальных удалений в выводе нет" "0" \
    "$(printf '%s' "$st_out" | grep -c 'deleted ')"
  teq "check: вывод закрыт подписью о результате" "1" \
    "$(printf '%s' "$st_out" | grep -c 'PHANTOM confirmed выше')"

  # 17. --once завершает один проход (демон не зависает).
  # Снимок живого состояния — по СОДЕРЖИМОМУ: демон каждые 15 с
  # пересоздаёт файлы (mv), поэтому проверка «файла нет в /var/run»
  # ложно краснела при работающем демоне. Ручной прогон идёт с
  # DRY_STATE-изоляцией и живое содержимое менять не должен.
  st_live_before=$(cat /var/run/corp-routes-clean.prev \
    /var/run/corp-routes-clean.phantom.prev 2>/dev/null | cksum)
  st_out=$(CORP_ROUTES_CLEAN_CONF=$st_tmp/no-such.conf \
           CORP_ROUTES_CLEAN_DRY_STATE=$st_tmp/dry-once \
           CORP_ROUTES_CLEAN_DRY_LOG=$st_tmp/dry-once.log \
           sh "$self_path" --dry-run --once 2>&1)
  t "once: --dry-run --once завершился (rc=0)" "$?"
  if [ -f "$st_tmp/dry-once/phantom.prev" ]; then
    t "once: состояние осталось в каталоге dry-run, не в /var/run" 0
  else
    t "once: состояние осталось в каталоге dry-run, не в /var/run" 1
  fi
  st_live_after=$(cat /var/run/corp-routes-clean.prev \
    /var/run/corp-routes-clean.phantom.prev 2>/dev/null | cksum)
  if [ "$st_live_before" = "$st_live_after" ]; then
    t "once: ручной прогон не тронул живое состояние в /var/run" 0
  else
    t "once: ручной прогон не тронул живое состояние в /var/run" 1
  fi

  # 18. Неизвестный аргумент отвергается, а не игнорируется молча
  sh "$self_path" --no-such-flag >/dev/null 2>&1
  teq "cli: неизвестный аргумент -> rc=2" "2" "$?"
  sh "$self_path" --help >/dev/null 2>&1
  teq "cli: --help -> rc=0" "0" "$?"

  rm -rf "$st_tmp"
  printf 'selftest: %s passed, %s failed (rc=%s)\n' "$st_pass" "$st_fail" \
    "$([ "$st_fail" -gt 0 ] && echo 1 || echo 0)"
  [ "$st_fail" -gt 0 ] && return 1
  return 0
}

if [ "$SELFTEST" -eq 1 ]; then
  selftest "$0"
  exit $?
fi

if [ "$CHECK" -eq 1 ]; then
  printf 'corp-routes-clean: read-only check, таблица читается один раз, ничего не меняется\n'
  scan_once
  printf 'corp-routes-clean: PHANTOM confirmed выше = кандидат, ждавший 2 снимка; удаление в --check не выполняется\n'
  [ -n "$ST_TMP" ] && rm -rf "$ST_TMP"
  exit 0
fi

log "Starting corp-routes-clean.sh (dry=${DRY} once=${ONCE} phantom_delete=${PHANTOM_DELETE})"
if [ "$PHANTOM_DELETE" -ne 1 ]; then
  log "scenario C (phantom fakeip gateway): ANALYTICS ONLY, deletion disabled"
fi
rm -f "$PREV" "$CUR" "$PG_PREV" "$PG_CUR"

while true; do
  scan_once
  if [ "$ONCE" -eq 1 ]; then break; fi
  sleep 15
done
