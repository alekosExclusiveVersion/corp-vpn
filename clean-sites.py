#!/usr/bin/env python3
"""Чистка SITE_DOMAINS от доменов, которых больше нет в живых БД.

Работает ТОЛЬКО с текстовыми конфигами corp-networks.conf. MySQL не трогает
никак: ни чтение на запись, ни удаление баз — для мёртвых доменов в том числе.
Источник правды — файл свежего скана `collect-sites.py --from-app --out`.

Использование:
  ./clean-sites.py --fresh sites.txt            # dry-run: показать протухшие
  ./clean-sites.py --fresh sites.txt --apply    # удалить с бэкапом
  ./clean-sites.py --selftest                    # проверки без сети и MySQL

Коды возврата: 0 — чисто / применено, 1 — есть протухшие (dry-run)
или отказ предохранителя, 2 — ошибка чтения/записи.
"""
import argparse
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
    rc = 0
    for path in confs:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        var = parse_vars(text)
        if "SITE_DOMAINS" not in var:
            print(f"{path}: нет SITE_DOMAINS — пропуск", file=sys.stderr)
            continue
        domains = split_list(var["SITE_DOMAINS"])
        protected = keep | {d.lower() for d in
                            split_list(var.get("SITE_CRITICAL", "")) +
                            split_list(var.get("DOMAINS", "")) +
                            split_list(var.get("MYSQL_HOSTS", ""))}
        suffixes = split_list(var.get("DOMAIN_SUFFIX", ""))
        stale = compute_stale(domains, fresh, protected, suffixes)
        if not stale:
            print(f"{path}: чисто ({len(domains)} доменов)")
            continue
        print(f"{path}: протухших {len(stale)} из {len(domains)}:")
        for d in stale:
            print(f"  - {d}")
        if over_cap(stale, len(domains), args.threshold) and not args.force:
            print(f"  ОТКАЗ: доля {len(stale)/len(domains):.0%} > порога "
                  f"{args.threshold:.0%} — похоже на частичный скан, "
                  "нужен --force", file=sys.stderr)
            rc = 1
            continue
        if not args.apply:
            rc = 1
            continue
        bak = path + ".bak." + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy(path, bak)
        new_text, n = remove_from_text(text, set(stale))
        if n != 1:
            print(f"{path}: строка SITE_DOMAINS не найдена/не одна "
                  f"(n={n}) — откат", file=sys.stderr)
            shutil.copy(bak, path)
            rc = 2
            continue
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_text)
        print(f"  применено, бэкап {bak}")
    if rc == 1 and not args.apply:
        print("dry-run: изменений нет, для применения нужен --apply")
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

    print(f"selftest: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
