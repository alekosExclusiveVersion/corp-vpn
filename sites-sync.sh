#!/bin/bash
# ==========================================================
# sites-sync.sh — автоматическая актуализация списков доменов.
#
# Цикл (LaunchAgent com.tradesoft.corp-sites-sync, 3 раза в день
# 08:00/14:00/20:00 + догон пропущенного прогона при старте):
#   1) тихий выход, если корп. VPN опущен И не корп. Wi-Fi (там MySQL
#      доступны напрямую, проверено 22.10: полный скан 287 доменов без ppp0);
#      3 пропуска подряд = уведомление (VPN лежит весь день);
#   2) полный скан collect-sites.py --from-app с ретраями на хост
#      (флап MySQL-маршрутов доказан: Access denied с домашнего IP);
#      любой неоспрошенный хост после ретраев = пропуск фазы чистки;
#   3) clean-sites.py --apply (dry-run сначала): предохранитель 30%,
#      keep = sites-keep.txt + corp-networks-auto.conf (находки corp-learn
#      сносить нельзя);
#   4) karing-rules.sh --check: при дрейфе quit Karing -> -i -> open;
#   5) уведомления о ФАКТИЧЕСКОМ статусе: события sites-sync.* в сигнальную
#      очередь (баннер macOS через corp-notify: ok/skip×3/fail/rollback
#      с числами, а не молчание);
#   6) лог ~/Library/Logs/corp-sites-sync/corp-sites-sync.log
#      (кольцо 2000 строк), чистка снапшотов/бэкапов старше 30 дней
#      (кроме 3 последних бэкапов каждого конфига).
#
# MySQL только SELECT через collect-sites.py. Удалений баз нет.
# Секреты в лог не пишутся (только домены/счётчики).
#
# Режимы:
#   (без флагов)   цикл, если с последнего успеха прошло >CATCHUP_HOURS.
#                  Порог (5ч) меньше минимального интервала расписания
#                  (6ч: 08:00/14:00/20:00), поэтому плановые прогоны идут
#                  всегда, а пропуск при сне/выключенном Mac догоняется
#                  на ближайшем срабатывании (сон покрывает и сам launchd
#                  coalescing-ом пропущенных StartCalendarInterval).
#   --force        цикл безусловно (для отладки и ручного догона);
#   --dry-run      скан + чистка без --apply + karing --check, без изменений;
#   --rollback     откат обоих конфигов на последний .bak + kickstart демона;
#   --selftest     проверки на фикстурах (без сети, без MySQL, без root).
# ==========================================================
set -uo pipefail

REPO="${SITES_SYNC_REPO:-$HOME/Work/scripts/corp-vpn}"
INSTALLED_CONF="${SITES_SYNC_CONF:-/usr/local/etc/corp-networks.conf}"
REPO_CONF="$REPO/corp-networks.conf"
AUTO_CONF="${SITES_SYNC_AUTO:-/usr/local/etc/corp-networks-auto.conf}"
MANUAL_KEEP="${SITES_SYNC_KEEP:-/usr/local/etc/sites-keep.txt}"
# Живой конфиг Karing (для чистки .bak после -i). Переопределяется через
# SITES_SYNC_KARING_DIR (нужно selftest на фикстурах).
KARING_DIR="${SITES_SYNC_KARING_DIR:-$HOME/Library/Group Containers/group.com.nebula.karing}"
KARING_ROUTING_JSON="$KARING_DIR/karing_routing_group.json"
KARING_SUBSCRIBE_JSON="$KARING_DIR/karing_subscribe_use.json"
SIGNALS="${CORP_SIGNALS:-/var/run/corp-vpn-signals}"
LOGDIR="${SITES_SYNC_LOGDIR:-$HOME/Library/Logs/corp-sites-sync}"
LOG="$LOGDIR/corp-sites-sync.log"
LAST_OK="$LOGDIR/last-ok"
SKIP_COUNT="$LOGDIR/skip-count"
LOG_KEEP_LINES=2000
KEEP_DAYS=30
MAX_TRIES=6
RETRY_SLEEP=8
CATCHUP_HOURS=5
SUDO="$HOME/bin/sudo"

VENV_PY=""
for cand in "$HOME/Work/scripts/parallels-sql-admins/.venv/bin/python" \
            /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
  if command -v "$cand" >/dev/null 2>&1; then VENV_PY="$cand"; break; fi
done

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# Защита от параллельных прогонов (flock нет в macOS по умолчанию).
LOCKDIR="${SITES_SYNC_LOCKDIR:-/tmp/corp-sites-sync.lock}"
acquire_lock() {
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    # Если lock старше 2ч — считаем его мёртвым и снимаем.
    if [ -d "$LOCKDIR" ]; then
      local age now mt
      now=$(date +%s)
      mt=$(stat -f %m "$LOCKDIR" 2>/dev/null || echo 0)
      age=$(( now - mt ))
      if [ "$age" -gt 7200 ]; then
        rmdir "$LOCKDIR" 2>/dev/null || true
        mkdir "$LOCKDIR" 2>/dev/null || { log "SKIP: другой прогон уже идёт"; exit 0; }
      else
        log "SKIP: другой прогон уже идёт (lock age ${age}s)"
        exit 0
      fi
    else
      log "SKIP: другой прогон уже идёт"
      exit 0
    fi
  fi
  trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM
}

# Кольцевая обрезка лога (конвенция DIAG_MAX демона маршрутов).
trim_log() {
  local f="$1" max="$2" n
  n=$(wc -l < "$f" 2>/dev/null || echo 0)
  if [ "$n" -gt "$max" ]; then
    tail -n "$max" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  fi
}

# Строка сигнального события: ts|event|message. Через неё corp-notify
# показывает баннер macOS о фактическом статусе прогона.
signal_line() { printf '%s|%s|%s\n' "$(date +%s)" "$1" "$2"; }

emit() {
  # Сигнал передаётся строкой-аргументом через sh -c, а НЕ пайпом в tee:
  # обёртка ~/bin/sudo подаёт пароль в stdin дочернего `sudo -S` и не
  # пробрасывает свой stdin дальше, поэтому `... | $SUDO tee -a`
  # молча теряло данные (tee получал EOF при rc=0, сигналов не было).
  local line
  line=$(signal_line "$1" "$2")
  $SUDO /bin/sh -c 'printf "%s\n" "$1" >> "$0"' "$SIGNALS" "$line" >/dev/null 2>&1 ||
    log "WARN: не записал сигнал $1 (sudo?)"
}

vpn_up() { ifconfig ppp0 2>/dev/null | grep -q 'inet '; }

# Корп. Wi-Fi: приватный MAC en0 (per-network признак, работает даже без IP)
# и/или ARP-MAC шлюза соответствует эталонам из corp-networks.conf. Паттерн —
# is_corp_wifi/gw_mac из vpn-watchdog.sh (см. §3.6.1 CORP-VPN-SETUP.md).
CORP_WIFI_MACS_DEFAULT="b6:be:0c:d5:9a:24"
CORP_WIFI_GW_MACS_DEFAULT="54:b8:a:cf:80:0"

corp_wifi_macs() {
  local v
  v=$(grep -E '^CORP_WIFI_EN0_MACS=' "$INSTALLED_CONF" 2>/dev/null |
      cut -d= -f2- | tr -d '"')
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$CORP_WIFI_MACS_DEFAULT"
}

gw_mac() {
  local lines gw
  lines=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print}')
  [ -n "$lines" ] || return 1
  gw=$(printf '%s\n' "$lines" | awk '$NF!~/^utun/{print $2; exit}')
  [ -n "$gw" ] ||
    gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
  [ -n "$gw" ] && [ "$gw" != "0.0.0.0" ] && [ "$gw" != "default" ] || return 1
  arp -n "$gw" 2>/dev/null | awk '{print $4; exit}'
}

is_corp_wifi() {
  local mac gm verdict=""
  mac=$(ifconfig en0 2>/dev/null | awk '/ether/{print $2; exit}')
  case " $(corp_wifi_macs) " in
    *" $mac "*) verdict="corp" ;;
  esac
  # Вторичный признак: ARP-шлюза (нужен отзывчивый gw; на хотспоте не резолвится).
  if [ -z "$verdict" ] && [ -n "$mac" ]; then
    gm=$(gw_mac 2>/dev/null) || gm=""
    case " $CORP_WIFI_GW_MACS_DEFAULT " in
      *" $gm "*) verdict="corp" ;;
    esac
  fi
  # Fallback: корп. подсеть по IP en0 (192.168.128.0/24), даже если MAC
  # рандомизирован/ARP шлюза не резолвится.
  if [ -z "$verdict" ]; then
    ip=$(ipconfig getifaddr en0 2>/dev/null || true)
    case "$ip" in
      192.168.128.*) verdict="corp" ;;
    esac
  fi
  [ "$verdict" = "corp" ]
}

# conf_mtime <60с назад менял corp-learn? Не драться с автодетектом.
learn_recent() {
  local f now mt
  now=$(date +%s)
  for f in "$INSTALLED_CONF" "$AUTO_CONF"; do
    [ -f "$f" ] || continue
    mt=$(stat -f %m "$f" 2>/dev/null || echo 0)
    if [ $(( now - mt )) -lt 60 ]; then return 0; fi
  done
  return 1
}

# Сбор keep: ручной файл + auto-конфиг (комментарии/# и пустые мимо).
build_keep() {
  local manual="$1" auto="$2"
  {
    [ -f "$manual" ] && grep -vE '^[[:space:]]*(#|$)' "$manual"
    [ -f "$auto" ] && grep -vE '^[[:space:]]*(#|$)' "$auto"
  } 2>/dev/null | tr 'A-Z' 'a-z' | sort -u
}

collect_once() {
  local hosts="$1" out="$2" err
  if [ -n "$hosts" ]; then
    err=$("$VENV_PY" "$REPO/collect-sites.py" --from-app \
          --hosts "$hosts" --out "$out" 2>&1)
  else
    err=$("$VENV_PY" "$REPO/collect-sites.py" --from-app \
          --out "$out" 2>&1)
  fi
  printf '%s' "$err" | grep -E 'ошибка|error|ERROR' || true
}

# Полный скан с ретраями по каждому упавшему хосту.
# Результат: union-файл в $dir/union.txt; неуспешные хосты — в $dir/failhosts.
do_collect() {
  local dir="$1" err hosts h i ok
  : > "$dir/union.txt"; : > "$dir/failhosts"
  err=$(collect_once "" "$dir/full.txt")
  if [ -n "$err" ]; then
    log "collect: stderr: $(printf '%s' "$err" | head -1 | cut -c1-200)"
  fi
  cat "$dir/full.txt" 2>/dev/null >> "$dir/union.txt"
  hosts=$(printf '%s' "$err" | grep -oE '^[a-z0-9][a-z0-9.-]*\.ru' | sort -u)
  for h in $hosts; do
    ok=0
    for i in $(seq 1 $MAX_TRIES); do
      sleep "$RETRY_SLEEP"
      err=$(collect_once "$h" "$dir/host-$h.txt")
      if [ -n "$err" ]; then
        log "collect retry $h: $(printf '%s' "$err" | head -1 | cut -c1-120)"
      fi
      if [ -z "$err" ]; then ok=1; break; fi
    done
    if [ "$ok" -eq 1 ]; then
      cat "$dir/host-$h.txt" 2>/dev/null >> "$dir/union.txt"
    else
      printf '%s\n' "$h" >> "$dir/failhosts"
    fi
  done
  sort -u "$dir/union.txt" -o "$dir/union.txt"
}

run_cycle() {
  local dry="$1" dir union failhosts stale removed
  mkdir -p "$LOGDIR"
  dir=$(mktemp -d "${TMPDIR:-/tmp}/sites-sync.XXXXXX")
  log "===== START dry=$dry ====="

  if ! vpn_up && ! is_corp_wifi; then
    skip_tick "vpn=down"
    return 0
  fi
  if [ -z "$VENV_PY" ]; then
    log "FAIL: нет python"
    emit sites-sync.fail "нет интерпретатора python"
    return 1
  fi
  if learn_recent; then
    log "SKIP: corp-learn только что писал конфиг, перенос на след. прогон"
    return 0
  fi

  do_collect "$dir"
  union="$dir/union.txt"
  failhosts=$(tr '\n' ' ' < "$dir/failhosts")
  log "collect: union=$(wc -l < "$union" | tr -d ' ') доменов"
  if [ ! -s "$union" ]; then
    log "SKIP: скан пустой (0 доменов), чистка пропущена"
    emit sites-sync.skip "скан пустой — чистка пропущена"
    return 0
  fi
  if [ -n "$failhosts" ]; then
    log "WARN: неоспрошены: $failhosts"
    emit sites-sync.warn "частичный скан: $failhosts"
  fi

  cp "$union" "$LOGDIR/fresh-$(date +%Y%m%d-%H%M).txt"
  build_keep "$MANUAL_KEEP" "$AUTO_CONF" > "$dir/keep.txt"

  stale=$("$VENV_PY" "$REPO/clean-sites.py" --fresh "$union" \
    --keep-file "$dir/keep.txt" 2>&1)
  removed=$(printf '%s' "$stale" | grep -c '^  - ' || true)
  log "clean dry-run: протухших $removed"
  if [ "$dry" -eq 1 ]; then
    log "dry-run: изменений нет"
    kar_check
    return 0
  fi

  if [ "$removed" -gt 0 ]; then
    if $SUDO "$VENV_PY" "$REPO/clean-sites.py" --fresh "$union" \
        --keep-file "$dir/keep.txt" --apply >> "$LOG" 2>&1; then
      log "clean --apply ok, удалено $removed"
      $SUDO launchctl kickstart -k system/com.tradesoft.corp-vpn-routes \
        >/dev/null 2>&1 || log "WARN: kickstart демона"
    else
      log "FAIL: clean --apply (предохранитель?)"
      emit sites-sync.fail "clean-sites отказался применяться — конфиги не тронуты"
      return 1
    fi
  else
    log "clean: протухших нет"
  fi

  kar_check || return 1
  mark_ok
  prune_artifacts
  trim_log "$LOG" "$LOG_KEEP_LINES"
  log "===== FINISH ok ====="
  emit sites-sync.ok "удалено доменов: $removed, Karing в норме"
  return 0
}

# Пропуск прогона: тихо в лог; каждый 3-й подряд пропуск (VPN лежит весь
# день) — уведомление о фактическом статусе.
skip_tick() {
  local reason="$1" n
  n=$(cat "$SKIP_COUNT" 2>/dev/null || echo 0)
  n=$(( n + 1 ))
  printf '%s' "$n" > "$SKIP_COUNT"
  log "SKIP ($n подряд): $reason"
  if [ "$n" -ge 3 ]; then
    emit sites-sync.skip "3 прогона подряд пропущены ($reason) — проверь VPN"
    printf '0' > "$SKIP_COUNT"
  fi
}

mark_ok() {
  date +%s > "$LAST_OK"
  printf '0' > "$SKIP_COUNT"
}

# Догон: с последнего успеха прошло больше CATCHUP_HOURS — прогон нужен.
catchup_due() {
  local last now
  [ -f "$LAST_OK" ] || return 0
  last=$(cat "$LAST_OK" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $(( now - last )) -gt $(( CATCHUP_HOURS * 3600 )) ]
}

# Karing: дрейф -> quit -> -i -> open -> перепроверка.
kar_check() {
  local drift
  drift=$(sh "$REPO/karing-rules.sh" --check 2>&1 | grep -E 'ОТСУТСТВУЮТ|ДРЕЙФ' || true)
  if [ -z "$drift" ]; then log "karing: дрейфа нет"; return 0; fi
  log "karing: дрейф, рестарт для -i"
  /usr/bin/osascript -e 'tell application "Karing" to quit' >/dev/null 2>&1 || true
  sleep 6
  if pgrep -f "Karing.app/Contents/MacOS/Karing" >/dev/null 2>&1; then
    log "FAIL: Karing не закрылся, -i пропускается"
    emit sites-sync.fail "Karing не закрылся для синхронизации"
    return 1
  fi
  if sh "$REPO/karing-rules.sh" -i >> "$LOG" 2>&1; then
    log "karing: -i применён"
  else
    log "FAIL: karing -i"
  fi
  open -a Karing >/dev/null 2>&1 || true
  sleep 15
  if sh "$REPO/karing-rules.sh" --check >/dev/null 2>&1; then
    log "karing: после рестарта чисто"
  else
    log "FAIL: дрейф остался после рестарта"
    emit sites-sync.fail "дрейф Karing остался после рестарта"
    return 1
  fi
}

# Автоудаление артефактов старше KEEP_DAYS (3 последних бэкапа каждого
# конфига не трогаем — часть страховки). Бэкапы Karing (*.bak.* после -i,
# в т.ч. ручные вроде *-pinval) чистятся теми же правилами.
prune_artifacts() {
  local b f
  find "$LOGDIR" -name 'fresh-*.txt' -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
  for f in "$INSTALLED_CONF" "$REPO_CONF" "$KARING_ROUTING_JSON" "$KARING_SUBSCRIBE_JSON"; do
    ls -t "$f".bak.* 2>/dev/null | tail -n +4 | while IFS= read -r b; do
      [ -n "$b" ] && find "$b" -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
    done
  done
}

do_rollback() {
  local f b
  for f in "$INSTALLED_CONF" "$REPO_CONF"; do
    b=$(ls -t "$f".bak.* 2>/dev/null | head -1)
    if [ -z "$b" ]; then echo "нет бэкапа для $f"; continue; fi
    if [ "$f" = "$INSTALLED_CONF" ]; then
      $SUDO cp "$b" "$f" && echo "откат $f <- $b"
    else
      cp "$b" "$f" && echo "откат $f <- $b"
    fi
  done
  $SUDO launchctl kickstart -k system/com.tradesoft.corp-vpn-routes 2>&1
  emit sites-sync.rollback "откат конфигов на последний бэкап"
}

selftest() {
  local pass=0 fail=0 tmp
  tmp=$(mktemp -d)
  ck() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
      fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; fi
  }
  printf '# коммент\nKeep.RU\n\nauto.ru\n' > "$tmp/manual"
  printf 'learn1.ru\n# x\nLEARN2.RU\n' > "$tmp/auto"
  ck "keep: мердж+lower+дедуп+комменты мимо" \
    "auto.ru keep.ru learn1.ru learn2.ru" \
    "$(build_keep "$tmp/manual" "$tmp/auto" | tr '\n' ' ' | sed 's/ $//')"
  ck "keep: нет файлов" "" "$(build_keep "$tmp/no" "$tmp/no2")"
  ck "signal: формат" "1|sites-sync.ok|msg" \
    "$(signal_line() { printf '%s|%s|%s\n' "1" "sites-sync.ok" "msg"; }; signal_line)"
  # emit: строка уходит в файл целиком через sh -c с аргументом.
  # Регрессия: пайп `signal_line | $SUDO tee -a` терял данные, т.к.
  # обёртка sudo не пробрасывает свой stdin дочернему процессу.
  # Подменяем SUDO заглушкой `exec "$@"` (как настоящий sudo с аргументами).
  printf '#!/bin/sh\nexec "$@"\n' > "$tmp/fake-sudo"
  chmod +x "$tmp/fake-sudo"
  ( SUDO="$tmp/fake-sudo" SIGNALS="$tmp/signals" emit "sites-sync.ok" "тест 123" )
  ck "emit: событие и текст дописаны в файл" "1" \
    "$(grep -c '|sites-sync.ok|тест 123$' "$tmp/signals" || true)"
  printf 'a\nb\nc\nd\ne\n' > "$tmp/log"
  trim_log "$tmp/log" 3
  ck "trim: кольцо" "c d e" "$(tr '\n' ' ' < "$tmp/log" | sed 's/ $//')"
  printf 'a\nb\n' > "$tmp/log2"
  trim_log "$tmp/log2" 10
  ck "trim: короткий цел" "a b" "$(tr '\n' ' ' < "$tmp/log2" | sed 's/ $//')"
  # prune: свежие артефакты целы, старые за пределами 3 newest — удалены.
  mkdir -p "$tmp/prune/logs" "$tmp/prune/karing"
  LOGDIR="$tmp/prune/logs" INSTALLED_CONF="$tmp/prune/noexist.conf"
  REPO_CONF="$tmp/prune/corp.conf"
  KARING_ROUTING_JSON="$tmp/prune/karing/routing.json"
  KARING_SUBSCRIBE_JSON="$tmp/prune/karing/noexist.json"
  KEEP_DAYS=30
  printf 'x' > "$tmp/prune/logs/fresh-old.txt"
  touch -t 202001010000 "$tmp/prune/logs/fresh-old.txt"
  printf 'x' > "$tmp/prune/logs/fresh-new.txt"
  : > "$tmp/prune/corp.conf"
  printf 'x' > "$tmp/prune/corp.conf.bak.new1"
  printf 'x' > "$tmp/prune/corp.conf.bak.new2"
  : > "$tmp/prune/karing/routing.json"
  for i in 1 2 3; do printf 'x' > "$tmp/prune/karing/routing.json.bak.new$i"; done
  for i in 4 5; do printf 'x' > "$tmp/prune/karing/routing.json.bak.old$i"
    touch -t 202001010000 "$tmp/prune/karing/routing.json.bak.old$i"; done
  prune_artifacts
  ck "prune: старый fresh удалён" "1" "$([ -f "$tmp/prune/logs/fresh-old.txt" ] && echo 0 || echo 1)"
  ck "prune: свежий fresh цел" "0" "$([ -f "$tmp/prune/logs/fresh-new.txt" ]; echo $?)"
  ck "prune: мало бэкапов — всё цело" "0" \
    "$([ -f "$tmp/prune/corp.conf.bak.new1" ] && [ -f "$tmp/prune/corp.conf.bak.new2" ]; echo $?)"
  ck "prune: старые karing-бэкапы за 3 newest удалены" "1" \
    "$([ -f "$tmp/prune/karing/routing.json.bak.old4" ] || [ -f "$tmp/prune/karing/routing.json.bak.old5" ]; echo $?)"
  ck "prune: свежие karing-бэкапы целы" "0" \
    "$([ -f "$tmp/prune/karing/routing.json.bak.new1" ] && [ -f "$tmp/prune/karing/routing.json.bak.new2" ] && [ -f "$tmp/prune/karing/routing.json.bak.new3" ]; echo $?)"
  rm -rf "$tmp"
  printf 'selftest: %d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --dry-run) mkdir -p "$LOGDIR"; acquire_lock; run_cycle 1 ;;
  --force) mkdir -p "$LOGDIR"; acquire_lock; run_cycle 0 ;;
  --rollback) do_rollback ;;
  --selftest) selftest ;;
  *)
    mkdir -p "$LOGDIR"
    if catchup_due; then
      log "catchup: последний успех >${CATCHUP_HOURS}ч назад, догоняю"
      acquire_lock
      run_cycle 0
    else
      log "расписание: догон не нужен (успех был недавно)"
    fi
    ;;
esac
