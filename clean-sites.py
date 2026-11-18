#!/usr/bin/env python3
"""Чистка SITE_DOMAINS от доменов, которых больше нет в живых БД.

Работает ТОЛЬКО с текстовыми конфигами corp-networks.conf. MySQL не трогает
никак: ни чтение на запись, ни удаление баз — для мёртвых доменов в том числе.
Источник правды — файл свежего скана `collect-sites.py --from-app --out`.

Протухание с карантином (grace): домен удаляется не после одного промаха,
а после N подряд сканов, где его нет (по умолчанию 3). Состояние —
JSON-файл (first_seen/last_seen/miss) рядом с логами, не в git.

Использование:
  ./clean-sites.py --fresh sites.txt              # отчёт: удалить/карантин
  ./clean-sites.py --fresh sites.txt --apply      # удалить с бэкапом
  ./clean-sites.py --fresh sites.txt --grace 1    # старое поведение
  ./clean-sites.py --selftest                     # проверки без сети и MySQL

Коды возврата: 0 — чисто / применено, 1 — есть протухшие (dry-run)
или отказ предохранителя, 2 — ошибка чтения/записи.
"""
import argparse
import json
import os
import re
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFS = [
    os.path.join(HERE, "corp-networks.conf"),
    "/usr/local/etc/corp-networks.conf",
]
DEFAULT_STATE = os.path.join(
    os.path.expanduser("~/Library/Application Support/corp-vpn"),
    "sites-state.json",
)
VAR_RE = re.compile(r'^([A-Z_]+)="((?:[^"\\]|\\.)*)"', re.M | re.S)


def parse_vars(text):
    """Все VAR=\"...\" в dict (многострочные значения поддерживаются)."""
    return {m.group(1): m.group(2) for m in VAR_RE.finditer(text)}


def split_list(value):
    return value.split()


def load_fresh(path):
    with open(path, encoding="utf-8") as f:
        return {ln.strip().lower() for ln in f if ln.strip()}


def compute_stale(site_domains, fresh, protected, suffixes):
    """Протухшие: есть в SITE_DOMAINS, нет в свежем скане, не защищены
    и не покрыты DOMAIN_SUFFIX (такие маршрутизируются суффиксом)."""
    stale = []
    for d in site_domains:
        dl = d.lower()
        if dl in fresh:
            continue
        if dl in protected:
            continue
        # www-вариант считается живым, если жив базовый домен
        if dl.startswith("www.") and dl[4:] in fresh:
            continue
        if any(dl.endswith(s.lower()) for s in suffixes):
            continue
        stale.append(d)
    return stale


def over_cap(stale, total, threshold):
    """Предохранитель от частичного скана: слишком большая доля
    протухших означает битый fresh-файл, а не массовое вымирание."""
    if total == 0:
        return False
    return len(stale) / total > threshold


def remove_from_text(text, stale_set):
    """Выкидывает протухшие из строки SITE_DOMAINS, порядок остальных хранит."""
    def sub(m):
        kept = [d for d in m.group(1).split() if d not in stale_set]
        return 'SITE_DOMAINS="%s"' % " ".join(kept)
    new, n = re.subn(r'^SITE_DOMAINS="(.*?)"', sub, text,
                     flags=re.M | re.S)
    return new, n


def load_keep(args):
    keep = {k.strip().lower() for k in (args.keep or "").split(",") if k.strip()}
    if args.keep_file:
        with open(args.keep_file, encoding="utf-8") as f:
            keep |= {ln.strip().lower() for ln in f
                     if ln.strip() and not ln.startswith("#")}
    return keep


def load_state(path):
    """Состояние протухания. Нет файла/битый JSON — начинаем с чистого."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return {"version": 1, "domains": {}}
    except (OSError, ValueError):
        return {"version": 1, "domains": {}}
    if not isinstance(data, dict) or not isinstance(data.get("domains"), dict):
        return {"version": 1, "domains": {}}
    return data


def save_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def ordered_unique(seq):
    seen, out = set(), []
    for x in seq:
        xl = x.lower()
        if xl not in seen:
            seen.add(xl)
            out.append(xl)
    return out


def update_state(state, domains, fresh, protected, suffixes, grace, today):
    """Обновляет счётчики промахов и возвращает (удалить, карантин).

    Удалить — miss >= grace; карантин — 1 <= miss < grace.
    Защищённые (keep/SITE_CRITICAL/MYSQL_HOSTS/суффиксы) и живые домены
    счётчик сбрасывают; www-вариант жив, если жив базовый домен.
    """
    entries = state.setdefault("domains", {})
    for d in domains:
        e = entries.setdefault(
            d, {"first_seen": today, "last_seen": today, "miss": 0})
        if d in fresh:
            e["miss"] = 0
            e["last_seen"] = today
        elif d in protected or any(d.endswith(s.lower()) for s in suffixes):
            # Ручные/инфраструктурные/суффиксные не «протухают».
            e["miss"] = 0
        elif d.startswith("www.") and d[4:] in fresh:
            e["miss"] = 0
            e["last_seen"] = today
        else:
            e["miss"] = int(e.get("miss", 0)) + 1
    to_remove, quarantine = [], []
    for d in domains:
        miss = int(entries[d].get("miss", 0))
        if miss <= 0:
            continue
        (to_remove if miss >= grace else quarantine).append((d, miss))
    return to_remove, quarantine


def format_list(items, grace, show_miss):
    if not items:
        return ""
    if show_miss:
        return ", ".join(f"{d} ({m}/{grace})" for d, m in items)
    return ", ".join(d for d, _ in items)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--fresh", required=False,
                    help="файл свежего скана (collect-sites.py --out), "
                         "полного --from-app, не --hosts")
    ap.add_argument("--conf", action="append", default=None,
                    help="конфиг для чистки (можно несколько раз); "
                         "по умолчанию репо + установленный")
    ap.add_argument("--keep", default="",
                    help="домены-исключения через запятую")
    ap.add_argument("--keep-file", default=None,
                    help="файл с доменами-исключениями")
    ap.add_argument("--state", default=os.environ.get(
        "CORP_SITES_STATE", DEFAULT_STATE),
        help="JSON состояния протухания (first_seen/last_seen/miss)")
    ap.add_argument("--grace", type=int, default=3,
                    help="сколько сканов подряд без домена до удаления "
                         "(по умолч. 3; 1 — удалять сразу)")
    ap.add_argument("--threshold", type=float, default=0.50,
                    help="макс. доля протухших без --force (по умолч. 0.50)")
    ap.add_argument("--force", action="store_true",
                    help="применить даже при превышении порога")
    ap.add_argument("--apply", action="store_true",
                    help="удалить с бэкапом .bak.YYYYMMDD-HHMMSS")
    ap.add_argument("--selftest", action="store_true",
                    help="встроенные проверки, без сети и MySQL")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    if not args.fresh:
        ap.error("--fresh обязателен (кроме --selftest)")

    confs = args.conf or [p for p in DEFAULT_CONFS if os.path.exists(p)]
    if not confs:
        print("нет конфигов для чистки", file=sys.stderr)
        return 2
    fresh = load_fresh(args.fresh)
    keep = load_keep(args)
    grace = max(1, int(args.grace))
    today = time.strftime("%Y-%m-%d")

    # Собираем домены и защиту из всех конфигов: решения о протухании
    # принимаются один раз, иначе два одина��овых conf дадут двойной
    # инкремент miss.
    texts, domains, protected, suffixes = {}, [], set(), set()
    for path in confs:
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        except OSError as ex:
            print(f"{path}: не читается ({ex}) — пропуск", file=sys.stderr)
            continue
        var = parse_vars(text)
        if "SITE_DOMAINS" not in var:
            print(f"{path}: нет SITE_DOMAINS — пропуск", file=sys.stderr)
            continue
        texts[path] = text
        domains += split_list(var["SITE_DOMAINS"])
        protected |= keep
        protected |= {d.lower() for d in split_list(var.get("SITE_CRITICAL", ""))}
        protected |= {d.lower() for d in split_list(var.get("DOMAINS", ""))}
        protected |= {d.lower() for d in split_list(var.get("MYSQL_HOSTS", ""))}
        suffixes |= set(split_list(var.get("DOMAIN_SUFFIX", "")))
    if not texts:
        return 2

    domains = ordered_unique(domains)
    state = load_state(args.state)
    to_remove, quarantine = update_state(
        state, domains, fresh, protected, suffixes, grace, today)

    total = len(domains)
    print(f"протухшие: удалить {len(to_remove)}, карантин {len(quarantine)}, "
          f"всего доменов {total} (grace={grace}, порог {args.threshold:.0%})")
    print(f"  удалить: {format_list(to_remove, grace, False) or '—'}")
    print(f"  карантин: {format_list(quarantine, grace, True) or '—'}")

    if over_cap(to_remove, total, args.threshold) and not args.force:
        print(f"  ОТКАЗ: доля {len(to_remove)/max(total,1):.0%} > порога "
              f"{args.threshold:.0%} — похоже на частичный скан, "
              "нужен --force", file=sys.stderr)
        return 1

    remove_set = {d for d, _ in to_remove}
    rc = 0
    if not args.apply:
        rc = 1 if (to_remove or quarantine) else 0
        print("dry-run: без --apply изменения не вносятся")
        return rc

    for path, text in texts.items():
        conf_domains = set(d.lower() for d in
                           split_list(parse_vars(text)["SITE_DOMAINS"]))
        in_conf = remove_set & conf_domains
        if not in_conf:
            print(f"{path}: удалять нечего")
            continue
        bak = path + ".bak." + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy(path, bak)
        new_text, n = remove_from_text(text, in_conf)
        if n != 1:
            print(f"{path}: строка SITE_DOMAINS не найдена/не одна "
                  f"(n={n}) — откат", file=sys.stderr)
            shutil.copy(bak, path)
            rc = 2
            continue
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_text)
        print(f"{path}: удалено {len(in_conf)} (бэкап {bak})")

    if rc == 0:
        state["updated"] = today
        save_state(args.state, state)
        print(f"состояние: {args.state}")
    return rc


def selftest():
    passed = failed = 0

    def ck(name, cond):
        nonlocal passed, failed
        if cond:
            passed += 1
        else:
            failed += 1
            print(f"  FAIL {name}")

    ck("parse: одна строка",
       parse_vars('SITE_DOMAINS="a.ru b.ru"') == {"SITE_DOMAINS": "a.ru b.ru"})
    ck("parse: многострочная",
       split_list(parse_vars('SITE_DOMAINS="a.ru\n b.ru"')["SITE_DOMAINS"])
       == ["a.ru", "b.ru"])
    ck("stale: базовый",
       compute_stale(["a.ru", "old.ru"], {"a.ru"}, set(), []) == ["old.ru"])
    ck("stale: регистр",
       compute_stale(["A.RU"], {"a.ru"}, set(), []) == [])
    ck("stale: keep",
       compute_stale(["k.ru"], set(), {"k.ru"}, []) == [])
    ck("stale: SITE_CRITICAL защищён",
       compute_stale(["parts-opt.com"], set(), {"parts-opt.com"}, []) == [])
    ck("stale: суффикс покрывает",
       compute_stale(["x.parts-catalogs.ru"], set(), set(),
                      [".parts-catalogs.ru"]) == [])
    ck("stale: порядок",
       compute_stale(["b.ru", "old1.ru", "a.ru", "old2.ru"], {"a.ru", "b.ru"},
                      set(), []) == ["old1.ru", "old2.ru"])
    ck("cap: норма проходит", not over_cap(["o.ru"], 100, 0.30))
    ck("cap: частичный скан ловится", over_cap(list("x" * 40), 100, 0.30))
    ck("cap: пустой список", not over_cap([], 0, 0.30))
    ck("remove: порядок и формат",
       remove_from_text('SITE_DOMAINS="b.ru old.ru a.ru"', {"old.ru"}) ==
       ('SITE_DOMAINS="b.ru a.ru"', 1))
    ck("remove: нет строки",
       remove_from_text('DOMAINS="a.ru"', {"a.ru"})[1] == 0)

    # --- grace-карантин ---------------------------------------------------
    st = {"version": 1, "domains": {}}
    rm, q = update_state(st, ["old.ru", "live.ru"], {"live.ru"},
                         set(), set(), 3, "2026-11-18")
    ck("grace: первый промах — карантин", rm == [] and q == [("old.ru", 1)])
    ck("grace: живой не в карантине", all(d != "live.ru" for d, _ in q))
    rm, q = update_state(st, ["old.ru", "live.ru"], {"live.ru"},
                         set(), set(), 3, "2026-11-19")
    ck("grace: второй промах — карантин", q == [("old.ru", 2)] and rm == [])
    rm, q = update_state(st, ["old.ru", "live.ru"], {"live.ru"},
                         set(), set(), 3, "2026-11-20")
    ck("grace: третий промах — удаление", rm == [("old.ru", 3)] and q == [])
    rm, q = update_state(st, ["old.ru", "live.ru"], {"live.ru", "old.ru"},
                         set(), set(), 3, "2026-11-21")
    ck("grace: возврат домена сбрасывает счётчик",
       rm == [] and q == [] and st["domains"]["old.ru"]["miss"] == 0)

    st2 = {"version": 1, "domains": {}}
    rm, q = update_state(st2, ["keep.ru", "x.parts.ru"], set(),
                         {"keep.ru"}, [".parts.ru"], 3, "2026-11-18")
    ck("grace: защищённые и суффиксные не протухают", rm == [] and q == [])

    st3 = {"version": 1, "domains": {}}
    rm, q = update_state(st3, ["www.a.ru"], {"a.ru"},
                         set(), set(), 3, "2026-11-18")
    ck("grace: www жив при живом базовом", rm == [] and q == [])
    ck("grace: first_seen ставится",
       st3["domains"]["www.a.ru"]["first_seen"] == "2026-11-18")

    st4 = {"version": 1, "domains": {}}
    rm, q = update_state(st4, ["old.ru"], set(), set(), set(), 1, "2026-11-18")
    ck("grace=1: удаление сразу", rm == [("old.ru", 1)] and q == [])

    print(f"selftest: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
