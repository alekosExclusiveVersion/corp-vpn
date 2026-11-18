#!/bin/bash
# ==========================================================
# karing-watch.sh — вотчер дрейфа Karing относительно корп. конфигов.
#
# Проблема: на корп. Wi-Fi (L2TP не поднимается, vpn=down) корп. путь —
# Karing-группа ts-network (direct_out). Новые домены (ручные правки
# SITE_DOMAINS, находки corp-learn в corp-networks-auto.conf) попадают
# в Karing только через `karing-rules.sh -i` с перезапуском приложения,
# а делает это только sites-sync (3 раза в день И при поднятом VPN).
# Целый день на корп. Wi-Fi без VPN = ни одного ресинка.
#
# Цикл (LaunchAgent com.tradesoft.corp-karing-watch, каждые 10 мин
# + при логине):
#   1) karing-rules.sh --check (только чтение, VPN не нужен);
#   2) дрейфа нет — тихо в лог, выход 0;
#   3) дрейф есть — проверка кулдауна (не чаще раза в COOLDOWN, по
#      умолчанию 30 мин): quit Karing -> -i -> open -> перепроверка;
#   4) события karing-watch.ok/fail в сигнальную очередь (только баннер
#      macOS через corp-notify, без B24+Telegram — см. corp-notify.sh).
#
# Karing — юзерское приложение, root не нужен: sudo используется только
# для записи в сигнальную очередь (как в sites-sync.sh). При недоступном
# sudo событие только логируется.
#
# Режимы:
#   (без флагов)   цикл проверки (для LaunchAgent, кулдаун действует);
#   --check        только сверка дрейфа, без изменений;
#   --sync         синк по дрейфу немедленно, без кулдауна (для sites-sync
#                  и агента WatchPaths на изменение конфига);
#   --force        ресинк безусловно (отладка; кулдаун и guard запущенного
#                  Karing игнорируются);
#   --selftest     проверки на фикстурах (без Karing, без сети, без root).
#
# Не зависит от корп. VPN/Wi-Fi: правится только live-конфиг Karing
# (direct_out), MySQL и скан доменов не нужны. Если Karing закрыт
# (VPN лежит, приложение не запущено), -i применяется без запуска
# приложения; если был запущен — quit -> -i -> open.
#
# Параллельные ресинки (sites-sync, WatchPaths-агент, вотчер) исключены
# общим локом /tmp/corp-karing-resync.lock.
# ==========================================================
set -uo pipefail

REPO="${KWATCH_REPO:-$HOME/Work/scripts/corp-vpn}"
INSTALLED_CONF="${KWATCH_CONF:-/usr/local/etc/corp-networks.conf}"
AUTO_CONF="${KWATCH_AUTO:-/usr/local/etc/corp-networks-auto.conf}"
RULES="${KWATCH_RULES:-$REPO/karing-rules.sh}"
LOGDIR="${KWATCH_LOGDIR:-$HOME/Library/Logs/corp-karing-watch}"
LOG="$LOGDIR/karing-watch.log"
LAST_RESYNC="$LOGDIR/last-resync"
SIGNALS="${CORP_SIGNALS:-/var/run/corp-vpn-signals}"
SUDO="${KWATCH_SUDO:-$HOME/bin/sudo}"
COOLDOWN="${KWATCH_COOLDOWN:-1800}"
QUIT_SLEEP="${KWATCH_QUIT_SLEEP:-6}"
OPEN_SLEEP="${KWATCH_OPEN_SLEEP:-15}"
# Общий лок ресинка: sites-sync, WatchPaths-агент и этот вотчер могут
# сработать одновременно (правка конфига + плановый прогон) — рестарт
# Karing должен быть один.
LOCKDIR="${KWATCH_LOCK:-/tmp/corp-karing-resync.lock}"
# Напоминание о незакоммиченных изменениях репо (баннер, без B24/TG):
# DIRTY_AFTER — возраст грязи для первого напоминания (48ч),
# REMIND_EVERY — пауза между повторами (24ч).
DIRTY_AFTER="${KWATCH_DIRTY_AFTER:-172800}"
REMIND_EVERY="${KWATCH_REMIND_EVERY:-86400}"
DIRTY_SINCE="$LOGDIR/repo-dirty-since"
DIRTY_REMINDED="$LOGDIR/repo-dirty-reminded"
LOG_KEEP_LINES=2000

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

trim_log() {
  local f="$1" max="$2" n
  n=$(wc -l < "$f" 2>/dev/null || echo 0)
  if [ "$n" -gt "$max" ]; then
    tail -n "$max" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  fi
}

signal_line() { printf '%s|%s|%s\n' "$(date +%s)" "$1" "$2"; }

emit() {
  # Строка уходит через sh -c аргументом, а не пайпом: обёртка ~/bin/sudo
  # не пробрасывает свой stdin дочернему процессу (см. sites-sync.sh).
  local line
  line=$(signal_line "$1" "$2")
  if [ -x "$SUDO" ]; then
    $SUDO /bin/sh -c 'printf "%s\n" "$1" >> "$0"' "$SIGNALS" "$line" >/dev/null 2>&1 ||
      log "WARN: не записал сигнал $1 (sudo?)"
  else
    log "WARN: нет $SUDO, сигнал $1 только в логе"
  fi
}

# Обёртки внешних эффектов — в selftest подменяются переопределением
# (живое приложение и конфиги не трогаются). Настоящие do_resync и
# drift_lines при этом исполняются как есть.
karing_running() { pgrep -f "Karing.app/Contents/MacOS/Karing" >/dev/null 2>&1; }
karing_quit() {
  /usr/bin/osascript -e 'tell application "Karing" to quit' >/dev/null 2>&1 || true
  sleep "$QUIT_SLEEP"
}
karing_open() {
  open -a Karing >/dev/null 2>&1 || true
  sleep "$OPEN_SLEEP"
}
karing_apply() { sh "$RULES" -i; }
karing_check() { sh "$RULES" --check; }

# Строки дрейфа из --check (пусто = чисто).
drift_lines() {
  karing_check 2>&1 | grep -E 'ОТСУТСТВУЮТ|ДРЕЙФ' || true
}

# Кулдаун ресинка: не чаще раза в COOLDOWN секунд.
cooldown_ok() {
  local last now
  [ -f "$LAST_RESYNC" ] || return 0
  last=$(cat "$LAST_RESYNC" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $(( now - last )) -ge "$COOLDOWN" ]
}

mark_resync() { date +%s > "$LAST_RESYNC"; }

# Лок на время ресинка (flock в macOS нет по умолчанию — mkdir).
# Старше 10 минут считаем мёртвым: рестарт Karing столько не живёт.
acquire_resync_lock() {
  local now mt age
  if mkdir "$LOCKDIR" 2>/dev/null; then
    trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM
    return 0
  fi
  now=$(date +%s)
  mt=$(stat -f %m "$LOCKDIR" 2>/dev/null || echo 0)
  age=$(( now - mt ))
  if [ "$age" -gt 600 ]; then
    rmdir "$LOCKDIR" 2>/dev/null || true
    if mkdir "$LOCKDIR" 2>/dev/null; then
      trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM
      return 0
    fi
  fi
  log "SKIP: ресинк уже идёт другим процессом (lock ${age}s)"
  return 1
}

do_resync() {
  local rc
  if ! acquire_resync_lock; then
    return 0
  fi
  _resync_locked
  rc=$?
  rmdir "$LOCKDIR" 2>/dev/null || true
  trap - EXIT INT TERM
  return $rc
}

_resync_locked() {
  local drift out was_running=0
  if karing_running; then was_running=1; fi
  if [ "$was_running" -eq 1 ]; then
    log "дрейф, рестарт Karing для -i"
    karing_quit
    if karing_running; then
      log "FAIL: Karing не закрылся, -i пропускается"
      emit karing-watch.fail "Karing не закрылся для синхронизации"
      return 1
    fi
  else
    log "дрейф, Karing не запущен — -i без рестарта приложения"
  fi
  if out=$(karing_apply 2>&1); then
    log "karing: -i применён"
  else
    log "FAIL: karing -i: $out"
    emit karing-watch.fail "karing -i: ошибка записи конфига"
    return 1
  fi
  if [ "$was_running" -eq 1 ]; then
    karing_open
  fi
  if drift=$(drift_lines); [ -z "$drift" ]; then
    log "karing: после применения чисто"
    mark_resync
    emit karing-watch.ok "ts-network синхронизирован с корп. конфигами"
    return 0
  else
    log "FAIL: дрейф остался после синхронизации: $drift"
    mark_resync
    emit karing-watch.fail "дрейф Karing остался после синхронизации"
    return 1
  fi
}

# Репо давно грязное — напомнить баннером (без B24/TG). Чистое репо
# снимает отсчёт. Первый прогон с грязью только ставит метку.
repo_remind() {
  local files now since reminded
  command -v git >/dev/null 2>&1 || return 0
  [ -d "$REPO/.git" ] || return 0
  files=$(git -C "$REPO" status --porcelain 2>/dev/null | awk '{print $2}' | tr '\n' ' ' | cut -c1-200)
  if [ -z "$files" ]; then
    rm -f "$DIRTY_SINCE" "$DIRTY_REMINDED"
    return 0
  fi
  now=$(date +%s)
  if [ ! -f "$DIRTY_SINCE" ]; then
    printf '%s' "$now" > "$DIRTY_SINCE"
    log "repo: незакоммиченные изменения, отсчёт напоминания"
    return 0
  fi
  since=$(cat "$DIRTY_SINCE" 2>/dev/null || echo "$now")
  [ $(( now - since )) -ge "$DIRTY_AFTER" ] || return 0
  reminded=$(cat "$DIRTY_REMINDED" 2>/dev/null || echo 0)
  [ $(( now - reminded )) -ge "$REMIND_EVERY" ] || return 0
  printf '%s' "$now" > "$DIRTY_REMINDED"
  log "repo: напоминание о незакоммиченных изменениях"
  emit repo-dirty.remind "в corp-vpn незакоммиченные изменения: $files"
}

run_cycle() {
  local drift rc
  mkdir -p "$LOGDIR"
  if [ ! -x "$RULES" ]; then
    log "FAIL: нет генератора $RULES"
    emit karing-watch.fail "нет генератора karing-rules.sh"
    return 1
  fi
  if drift=$(drift_lines); [ -z "$drift" ]; then
    log "karing: дрейфа нет"
    repo_remind
    return 0
  fi
  log "karing: дрейф: $drift"
  if ! cooldown_ok; then
    log "SKIP: кулдаун ресинка (не чаще раза в ${COOLDOWN}с)"
    repo_remind
    return 0
  fi
  do_resync
  rc=$?
  repo_remind
  return $rc
}

# Немедленный синк по дрейфу (кулдаун не действует). Вызывают sites-sync
# перед VPN-гейтом и WatchPaths-агент после правки corp-networks.conf.
sync_now() {
  local drift
  mkdir -p "$LOGDIR"
  if [ ! -x "$RULES" ]; then
    log "FAIL: нет генератора $RULES"
    emit karing-watch.fail "нет генератора karing-rules.sh"
    return 1
  fi
  if drift=$(drift_lines); [ -z "$drift" ]; then
    log "sync: дрейфа нет"
    return 0
  fi
  log "sync: дрейф: $drift"
  do_resync
}

selftest() {
  local pass=0 fail=0 tmp
  tmp=$(mktemp -d)
  ck() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
      fail=$((fail + 1)); printf '  FAIL %s [%s]: ожидалось [%s], получено [%s]\n' \
        "$1" "$4" "$2" "$3"; fi
  }
  printf '#!/bin/sh\nexec "$@"\n' > "$tmp/fake-sudo"
  chmod +x "$tmp/fake-sudo"

  # Всё состояние — во временном каталоге (динамический скоуп bash:
  # переопределённые ниже обёртки видят локальный tmp).
  LOGDIR="$tmp/logs" LOG="$tmp/logs/karing-watch.log"
  LAST_RESYNC="$tmp/logs/last-resync"
  LOCKDIR="$tmp/lock"
  SIGNALS="$tmp/signals" SUDO="$tmp/fake-sudo" COOLDOWN=100
  mkdir -p "$tmp/logs"

  # Подмены внешних эффектов. karing_check отвечает по сценарию:
  # первый вызов — CHECK_FIRST, остальные — CHECK_REST (счётчик в файле,
  # чтобы пережить подшеллы в $(...)).
  karing_running() { [ -f "$tmp/still-running" ]; }
  karing_quit() { [ -f "$tmp/quit-works" ] && rm -f "$tmp/still-running"; return 0; }
  karing_open() { printf 'opened\n' >> "$tmp/opened"; }
  karing_apply() { printf 'applied\n' >> "$tmp/applied"; return 0; }
  karing_check() {
    local n
    n=$(cat "$tmp/checks" 2>/dev/null || echo 0)
    printf '%s' "$(( n + 1 ))" > "$tmp/checks"
    if [ "$n" -eq 0 ]; then printf '%s\n' "$CHECK_FIRST"; else printf '%s\n' "$CHECK_REST"; fi
    return 0
  }
  CHECK_FIRST='Дрейфа нет' CHECK_REST='Дрейфа нет'
  clean_state() { rm -f "$tmp/applied" "$tmp/checks" "$tmp/still-running" "$tmp/logs/last-resync"; }

  ck "signal: формат" "1" \
    "$(signal_line karing-watch.ok msg | grep -cE '^[0-9]+\|karing-watch.ok\|msg$' || true)" "fmt"
  ( emit "karing-watch.ok" "тест 123" )
  ck "emit: событие и текст дописаны в файл" "1" \
    "$(grep -c '|karing-watch.ok|тест 123$' "$tmp/signals" || true)" "emit"

  rm -f "$tmp/logs/last-resync"
  cooldown_ok; ck "cooldown: без файла разрешает" "0" "$?" "cd1"
  date +%s > "$tmp/logs/last-resync"
  cooldown_ok; ck "cooldown: свежий запрещает" "1" "$?" "cd2"
  printf '%s' "$(( $(date +%s) - 200 ))" > "$tmp/logs/last-resync"
  cooldown_ok; ck "cooldown: старый разрешает" "0" "$?" "cd3"

  CHECK_FIRST='  domain ОТСУТСТВУЮТ (1): x.ru' CHECK_REST='Дрейфа нет'
  printf '0' > "$tmp/checks"
  ck "drift: маркер находится" "1" "$(drift_lines | grep -c x.ru || true)" "dr1"
  CHECK_FIRST='Дрейфа нет'
  printf '0' > "$tmp/checks"
  ck "drift: чистый вывод пуст" "" "$(drift_lines)" "dr2"

  # Цикл без дрейфа: тихо, без -i, без метки.
  CHECK_FIRST='Дрейфа нет' CHECK_REST='Дрейфа нет'
  clean_state
  run_cycle >/dev/null 2>&1
  ck "cycle: чистый код 0" "0" "$?" "cy1"
  ck "cycle: чистый без -i" "1" "$([ -f "$tmp/applied" ] && echo 0 || echo 1)" "cy2"
  ck "cycle: чистый без метки" "1" "$([ -f "$tmp/logs/last-resync" ]; echo $?)" "cy3"

  # Дрейф + свежий кулдаун: пропуск без -i.
  CHECK_FIRST='ДРЕЙФ: 2 расхождения' CHECK_REST='ДРЕЙФ: 2 расхождения'
  clean_state; date +%s > "$tmp/logs/last-resync"
  run_cycle >/dev/null 2>&1
  ck "cycle: кулдаун код 0" "0" "$?" "cy4"
  ck "cycle: кулдаун без -i" "1" "$([ -f "$tmp/applied" ] && echo 0 || echo 1)" "cy5"

  # Дрейф без кулдауна, рестарт чистый: счастливый путь.
  CHECK_FIRST='ДРЕЙФ: 2 расхождения' CHECK_REST='Дрейфа нет'
  clean_state
  printf '%s' "$(( $(date +%s) - 200 ))" > "$tmp/logs/last-resync"
  run_cycle >/dev/null 2>&1
  ck "cycle: ресинк код 0" "0" "$?" "cy6"
  ck "cycle: ресинк вызвал -i" "0" "$([ -f "$tmp/applied" ]; echo $?)" "cy7"
  ck "cycle: ресинк ставит метку" "0" "$([ -f "$tmp/logs/last-resync" ]; echo $?)" "cy8"
  ck "cycle: ресинк шлёт ok" "1" "$(grep -c '|karing-watch.ok|ts-network синхронизирован' "$tmp/signals" || true)" "cy9"

  # Karing не закрылся: -i блокируется, код 1.
  CHECK_FIRST='ДРЕЙФ: 1 расхождение' CHECK_REST='Дрейфа нет'
  clean_state
  printf '%s' "$(( $(date +%s) - 200 ))" > "$tmp/logs/last-resync"
  : > "$tmp/still-running"
  run_cycle >/dev/null 2>&1
  ck "cycle: живой Karing код 1" "1" "$?" "cy10"
  ck "cycle: живой Karing без -i" "1" "$([ -f "$tmp/applied" ] && echo 0 || echo 1)" "cy11"
  ck "cycle: живой Karing шлёт fail" "1" \
    "$(grep -c '|karing-watch.fail|Karing не закрылся' "$tmp/signals" || true)" "cy12"

  # Дрейф остался после рестарта: код 1, но метка ставится (кулдаун).
  CHECK_FIRST='ДРЕЙФ: 1 расхождение' CHECK_REST='ДРЕЙФ: 1 расхождение'
  clean_state
  printf '%s' "$(( $(date +%s) - 200 ))" > "$tmp/logs/last-resync"
  run_cycle >/dev/null 2>&1
  ck "cycle: остаточный дрейф код 1" "1" "$?" "cy13"
  ck "cycle: остаточный дрейф ставит метку" "0" "$([ -f "$tmp/logs/last-resync" ]; echo $?)" "cy14"

  # Нет генератора: fail без падений.
  RULES="$tmp/no-such-rules.sh"
  clean_state
  run_cycle >/dev/null 2>&1
  ck "cycle: без генератора код 1" "1" "$?" "cy15"

  # --sync: кулдаун не действует; запущенный Karing переоткрывается.
  RULES="$tmp/rules.sh"
  printf '#!/bin/sh\nexit 0\n' > "$RULES"; chmod +x "$RULES"
  CHECK_FIRST='ДРЕЙФ: 2 расхождения' CHECK_REST='Дрейфа нет'
  clean_state; rm -f "$tmp/opened" "$tmp/quit-works"
  : > "$tmp/still-running"; : > "$tmp/quit-works"
  date +%s > "$tmp/logs/last-resync"
  sync_now >/dev/null 2>&1
  ck "sync: кулдаун игнорируется" "0" "$([ -f "$tmp/applied" ]; echo $?)" "sy1"
  ck "sync: запущенный Karing переоткрыт" "1" "$(grep -c . "$tmp/opened" 2>/dev/null || true)" "sy2"

  # --sync: Karing не запущен — -i применяется без старта приложения.
  clean_state; rm -f "$tmp/opened" "$tmp/quit-works"
  sync_now >/dev/null 2>&1
  ck "sync: без Karing -i применён" "0" "$([ -f "$tmp/applied" ]; echo $?)" "sy3"
  ck "sync: без Karing приложение не стартует" "0" "$([ -f "$tmp/opened" ] && echo 1 || echo 0)" "sy4"

  printf 'a\nb\nc\nd\ne\n' > "$tmp/log"
  trim_log "$tmp/log" 3
  ck "trim: кольцо" "c d e" "$(tr '\n' ' ' < "$tmp/log" | sed 's/ $//')" "tr"

  # repo_remind: напоминание о долгой грязи (фиктивный git-репо).
  REPO="$tmp/repo" DIRTY_AFTER=100 REMIND_EVERY=100
  DIRTY_SINCE="$tmp/logs/repo-dirty-since" DIRTY_REMINDED="$tmp/logs/repo-dirty-reminded"
  git init -q "$tmp/repo"
  git -C "$tmp/repo" config user.email "t@t.t"
  git -C "$tmp/repo" config user.name "t"
  printf 'x' > "$tmp/repo/f"
  git -C "$tmp/repo" add f; git -C "$tmp/repo" commit -qm init
  : > "$tmp/signals2"; SIGNALS="$tmp/signals2"
  repo_remind
  ck "remind: чистое репо молчит" "0" "$(grep -c 'repo-dirty' "$tmp/signals2" || true)" "rr1"
  ck "remind: чистое репо без метки" "1" "$([ -f "$tmp/logs/repo-dirty-since" ]; echo $?)" "rr2"
  printf 'y' >> "$tmp/repo/f"
  repo_remind
  ck "remind: свежая грязь ставит метку" "0" "$([ -f "$tmp/logs/repo-dirty-since" ]; echo $?)" "rr3"
  ck "remind: свежая грязь молчит" "0" "$(grep -c 'repo-dirty' "$tmp/signals2" || true)" "rr4"
  printf '%s' "$(( $(date +%s) - 200 ))" > "$tmp/logs/repo-dirty-since"
  repo_remind
  ck "remind: старая грязь шлёт сигнал" "1" "$(grep -c '|repo-dirty.remind|' "$tmp/signals2" || true)" "rr5"
  ck "remind: сигнал называет файл" "1" "$(grep -c 'repo-dirty.remind|.*f' "$tmp/signals2" || true)" "rr6"
  repo_remind
  ck "remind: повтор в паузе молчит" "1" "$(grep -c '|repo-dirty.remind|' "$tmp/signals2" || true)" "rr7"
  git -C "$tmp/repo" commit -qam fix
  repo_remind
  ck "remind: коммит снимает метки" "1" "$([ -f "$tmp/logs/repo-dirty-since" ] || [ -f "$tmp/logs/repo-dirty-reminded" ]; echo $?)" "rr8"

  rm -rf "$tmp"
  printf 'selftest: %d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --check)
    mkdir -p "$LOGDIR"
    if drift=$(drift_lines); [ -z "$drift" ]; then
      echo "Дрейфа нет: live-конфиг совпадает с корп. конфигами"
    else
      echo "$drift"
      exit 1
    fi
    ;;
  --force) mkdir -p "$LOGDIR"; do_resync ;;
  --sync) sync_now ;;
  --selftest) selftest ;;
  *) mkdir -p "$LOGDIR"; run_cycle ;;
esac
