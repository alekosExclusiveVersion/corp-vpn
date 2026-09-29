#!/usr/bin/env python3
"""
collect-sites.py — сбор доменов сайтов, размещённых на корпоративных
MySQL-серверах. Собранный список подставляется в SITE_DOMAINS
файла corp-networks.conf и маршрутизируется через корп. VPN.

Стратегии поиска домена в каждой БД (в порядке приоритета):
  1. _objects_structure: строка с str_domain='domain', домен в str_title.
  2. cfg_settings (Plesk/Parallels): значение настройки похоже на домен.
  3. psa.domains (панель Plesk) — если пользователю доступна БД psa.

Примеры:
  ./collect-sites.py                          # пароль запросит интерактивно
   ./collect-sites.py --password '***' --out sites.txt
   ./collect-sites.py --password-keychain --hosts p7ru4.tradesoft.ru --out sites-p7ru4.txt
  ./collect-sites.py --clean sites.txt        # локальная фильтрация, без MySQL
  ./collect-sites.py --probe p7ru1.tradesoft.ru           # список БД и таблиц с доменами
  ./collect-sites.py --probe p7ru1.tradesoft.ru ar_example  # разбор одной БД
"""

from __future__ import annotations

import argparse
import getpass
import json
import re
import subprocess
import sys
from pathlib import Path

try:
    import pymysql
except ImportError:
    sys.exit("Нужен pymysql. Запускайте через venv приложения "
             "(../parallels-sql-admins/.venv/bin/python) или pip install pymysql")

SYSTEM_DBS = {
    "information_schema", "performance_schema", "mysql", "sys",
    "master", "tempdb", "model", "msdb",
}

SETTINGS_TABLE = "cfg_settings"

# Имена настроек, намекающие на домен/адрес сайта
NAME_HINTS = ("url", "site", "domain", "domen", "www", "host", "link")

# Значение считается доменом: [protocol]www[.]домен[.tld][/путь][:порт]
DOMAIN_RE = re.compile(
    r"(?i)^(?:https?://)?(?:www\.)?"
    r"([a-z0-9][a-z0-9\-]*(\.[a-z0-9][a-z0-9\-]*)+)"
    r"(?:[:/].*)?$"
)

# Домены, которые не являются сайтами клиентов: почта, платёжные шлюзы,
# платформа (auto-vision.ru, tradesoft.pro), тестовые/демо-инстансы.
JUNK_PREFIXES = (
    "smtp.", "smtppro.", "smtpout.", "imap.", "pop3.", "mx.",
    "mail.", "cloudmail.", "demo", "test", "war", "debug",
)
JUNK_SUFFIXES = (
    ".tradesoft.pro", ".tradesoft.hk.com", ".auto-vision.ru",
    ".ext.tradesoft.ru", ".azure-api.net", ".hosting.reg.ru",
    ".netangels.ru", ".systest.php7",
)
JUNK_EXACT = {
    "3dsec.sberbank.ru", "securepayments.sberbank.ru",
    "pay169.paysec.by", "drive.google.com",
    "avto-intellekt.rf.ext.tradesoft.ru", "asus1.tradesoft.ru",
    "auto-tron.ru.ru", "automarket.rayber.ru", "parts.nemdom.ru",
    "relay.lankraft.ru", "update.euro-asia.ru", "update.unipart24.ru",
    "autotitan24.bitrix24.ru",
}
# тестовые домены вида .t171, .t120 (инстансы разработчиков)
JUNK_RE = re.compile(r"\.t\d+$|\.php7$")

# Серверы, исключённые из сбора по умолчанию (нет доступа пользователю koshkin)
EXCLUDED_SERVERS = {"p5g25.tradesoft.ru"}


def is_junk_domain(domain: str) -> bool:
    d = domain.lower()
    if d in JUNK_EXACT:
        return True
    if any(d.startswith(p) for p in JUNK_PREFIXES):
        return True
    if any(d.endswith(s) for s in JUNK_SUFFIXES):
        return True
    if JUNK_RE.search(d):
        return True
    return False


def extract_domain(value: str) -> str | None:
    m = DOMAIN_RE.match(value.strip().strip('"').strip("'"))
    return m.group(1).lower() if m else None


def settings_tables(cursor, db: str) -> bool:
    cursor.execute(
        "SELECT 1 FROM information_schema.tables "
        "WHERE table_schema=%s AND table_name=%s LIMIT 1",
        (db, SETTINGS_TABLE),
    )
    return cursor.fetchone() is not None


def scan_cfg_settings(cursor, db: str) -> set[str]:
    found: set[str] = set()
    try:
        if not settings_tables(cursor, db):
            return found
        cursor.execute(f"SELECT stg_name, stg_value FROM `{db}`.`{SETTINGS_TABLE}` LIMIT 10000")
        for name, value in cursor.fetchall():
            if value is None:
                continue
            low_name = str(name).lower()
            if any(h in low_name for h in NAME_HINTS):
                d = extract_domain(str(value))
                if d:
                    found.add(d)
                    continue
            if re.search(r"(?i)\.(ru|рф|com|net|org|pro|info|biz|su|eu|de|dev)$",
                         str(value)) and "." in str(value):
                d = extract_domain(str(value))
                if d:
                    found.add(d)
    except Exception:
        pass
    return found


def scan_site_structure(cursor, db: str) -> set[str]:
    """Домен сайта из дерева структуры (_objects_structure, str_domain='domain')."""
    found: set[str] = set()
    try:
        cursor.execute(
            "SELECT 1 FROM information_schema.tables "
            "WHERE table_schema=%s AND table_name='_objects_structure' LIMIT 1",
            (db,),
        )
        if cursor.fetchone() is None:
            return found
        cursor.execute(
            f"SELECT str_title FROM {qident(db, '_objects_structure')} "
            "WHERE str_domain='domain' AND str_title IS NOT NULL AND str_title<>'' "
            "LIMIT 200"
        )
        for (title,) in cursor.fetchall():
            d = extract_domain(str(title))
            if d:
                found.add(d)
    except Exception:
        pass
    return found


def scan_psa_domains(cursor) -> set[str]:
    found: set[str] = set()
    try:
        cursor.execute("SHOW TABLES FROM `psa` LIKE 'domains'")
        if cursor.fetchone() is None:
            return found
        cursor.execute("SELECT name FROM `psa`.`domains`")
        for row in cursor.fetchall():
            d = extract_domain(str(row[0]))
            if d:
                found.add(d)
    except Exception:
        pass
    return found


def list_databases(cursor) -> list[str]:
    cursor.execute("SHOW DATABASES")
    return [r[0] for r in cursor.fetchall() if r[0] not in SYSTEM_DBS]


DOMAIN_TABLE_HINTS = ("domain", "site", "www", "vhost", "virtual", "host", "url", "link", "addr")


def qident(db: str, table: str = "") -> str:
    db = db.replace("`", "``")
    if table:
        return f"`{db}`.`{table.replace('`', '``')}`"
    return f"`{db}`"


def probe_host(conn) -> None:
    """Список БД и таблиц-кандидатов на домены (host без указания БД)."""
    with conn.cursor() as cur:
        dbs = list_databases(cur)
        print(f"БД без системных ({len(dbs)}):")
        for d in dbs[:80]:
            print("  ", d)
        if "psa" in dbs:
            cur.execute("SHOW TABLES FROM psa LIKE 'domains'")
            if cur.fetchone():
                cur.execute("SELECT COUNT(*) FROM psa.domains")
                print(f"psa.domains: {cur.fetchone()[0]} записей")
        for db in dbs[:30]:
            try:
                cur.execute(f"SHOW TABLES FROM {qident(db)}")
                tables = [r[0] for r in cur.fetchall()]
            except Exception:
                continue
            hits = [t for t in tables
                    if any(h in t.lower() for h in DOMAIN_TABLE_HINTS)]
            if hits:
                print(f"== {db}: таблицы-кандидаты: {hits}")
                for t in hits[:5]:
                    try:
                        cur.execute(f"SELECT COUNT(*) FROM {qident(db, t)}")
                        print(f"   {db}.{t}: {cur.fetchone()[0]} строк")
                    except Exception:
                        pass


def probe_db(conn, db: str) -> None:
    """Разбор одной БД: таблицы-кандидаты, колонки-подсказки и примеры строк."""
    with conn.cursor() as cur:
        try:
            cur.execute(f"SHOW TABLES FROM {qident(db)}")
            tables = [r[0] for r in cur.fetchall()]
        except Exception as ex:
            print(f"БД {db}: ошибка: {ex}")
            return
        print(f"БД {db}: всего таблиц {len(tables)}")
        name_hits = [t for t in tables
                     if any(h in t.lower() for h in DOMAIN_TABLE_HINTS)]
        if name_hits:
            print("  по имени таблицы:", ", ".join(name_hits))
        col_hits: dict[str, list[str]] = {}
        for t in tables:
            try:
                cur.execute(f"SHOW COLUMNS FROM {qident(db, t)}")
                cols = [r[0] for r in cur.fetchall()]
            except Exception:
                continue
            hits = [c for c in cols if any(h in c.lower() for h in DOMAIN_TABLE_HINTS)]
            if hits:
                col_hits[t] = hits
        if col_hits:
            print("  по имени колонки:")
            for t, hits in col_hits.items():
                print(f"    {t}: {', '.join(hits)}")
        targets = list(dict.fromkeys(list(col_hits)[:8] + name_hits[:4]))
        for t in targets:
            print(f"  -- {t}:")
            try:
                cur.execute(f"SHOW COLUMNS FROM {qident(db, t)}")
                cols = [r[0] for r in cur.fetchall()]
                print("     колонки:", ", ".join(cols))
                cur.execute(f"SELECT * FROM {qident(db, t)} LIMIT 5")
                for row in cur.fetchall():
                    print("     ", row)
            except Exception as ex:
                print("     ошибка:", ex)


def clean_list(domains: set[str]) -> list[str]:
    """Отфильтровать служебные/тестовые домены, отсортировать."""
    return sorted(d for d in domains if not is_junk_domain(d))


def clean_file(path: Path) -> None:
    raw = sorted({
        line.strip() for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    })
    keep = clean_list(set(raw))
    junk = sorted(set(raw) - set(keep))
    print(f"Всего: {len(raw)}, удалено мусора: {len(junk)}, осталось: {len(keep)}")
    if junk:
        print("Удалено:")
        for d in junk:
            print("  -", d)
    print("Осталось:")
    for d in keep:
        print("  +", d)


def make_conn(host: str, port: int, user: str, password: str,
              read_timeout: int):
    return pymysql.connect(host=host, port=port, user=user,
                           password=password, connect_timeout=5,
                           read_timeout=read_timeout, autocommit=True,
                           charset="utf8mb4")


def keychain_password(service: str, user: str) -> str | None:
    """Пароль из macOS Keychain (generic password). Пароль не печатается."""
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-a", user, "-s", service, "-w"],
            capture_output=True, text=True, check=False,
        )
    except OSError:
        return None
    if r.returncode != 0:
        return None
    password = r.stdout.strip()
    return password or None


def app_servers(app_path: str) -> list[dict]:
    """Хосты и учётки из реестра приложения Parallels SQL Admin.

    Путь тот же, что у GUI: config.ini и servers.json из каталога данных
    приложения, расшифровка паролей — Fernet-ключом из Keychain. Репошные
    servers.json/config.ini содержат пустые пароли, поэтому читать их нельзя
    (получим "Access denied ... using password: NO"). Пароль наружу не
    выводится и не попадает в argv.
    """
    sys.path.insert(0, app_path)
    import common.config as C
    from common.paths import app_data_dir

    data = app_data_dir()
    cfg = C.load_config(data / "config.ini")
    object.__setattr__(cfg.advanced, "servers_file", str(data / "servers.json"))
    C.config = cfg

    from common.server_registry import ServerRegistry

    sr = ServerRegistry()
    sr.ensure_key()

    out: list[dict] = []
    for spec in sr.load():
        if spec.engine != "mysql":
            continue
        user, password, host, port = sr.credentials_for(spec.host_key())
        if not password:
            continue
        out.append({"host": host, "port": port, "user": user,
                    "password": password})
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Сбор доменов сайтов с MySQL-серверов")
    ap.add_argument("--servers", default="",
                    help="JSON с серверами (формат servers.json приложения). "
                         "Внимание: репошный servers.json содержит пустые пароли — "
                         "нужен внешний --password. Проще --from-app")
    ap.add_argument("--from-app", action="store_true",
                    help="хосты и пароли из реестра Parallels SQL Admin "
                         "(обход Keychain и интерактивного ввода)")
    ap.add_argument("--app-path", default="",
                    help="репозиторий parallels-sql-admins для импорта common "
                         "(по умолчанию ../parallels-sql-admins)")
    ap.add_argument("--user", default="koshkin")
    ap.add_argument("--password", default="", help="пусто — из Keychain или интерактивно")
    ap.add_argument("--password-keychain", nargs="?", const="collect-sites",
                    metavar="SERVICE",
                    help="брать пароль из macOS Keychain "
                         "(generic password; service, по умолчанию collect-sites)")
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--timeout", type=int, default=60,
                    help="read_timeout на запрос, сек (по умолчанию 60)")
    ap.add_argument("--out", default="sites.txt",
                    help="файл со списком доменов (по одному на строку)")
    ap.add_argument("--hosts", default="",
                    help="только указанные серверы (через запятую); "
                         "пусто — все, кроме исключённых")
    ap.add_argument("--clean", metavar="FILE",
                    help="отфильтровать служебные/тестовые домены в файле (без MySQL)")
    ap.add_argument("--probe", nargs="*", metavar="HOST [DB]",
                    help="показать настройки одной БД (исследование схемы)")
    args = ap.parse_args()

    if args.clean:
        clean_file(Path(args.clean))
        return

    if args.from_app and args.servers:
        sys.exit("Нельзя совмещать --from-app и --servers")

    password = args.password
    servers: list[dict] = []

    if args.from_app:
        app_path = args.app_path or str(
            Path(__file__).resolve().parent.parent / "parallels-sql-admins")
        try:
            servers = app_servers(app_path)
        except Exception as ex:
            sys.exit(f"Не удалось прочитать реестр приложения ({app_path}): "
                     f"{type(ex).__name__}: {ex}")
        print(f"Из реестра приложения: {len(servers)} MySQL-сервер(ов) с паролем")
    else:
        if not password and args.password_keychain:
            password = keychain_password(args.password_keychain, args.user)
            if not password:
                sys.exit(
                    f"Пароль не найден в Keychain (service={args.password_keychain!r}, "
                    f"account={args.user!r}). Настрой: "
                    f"security add-generic-password -a {args.user} -s {args.password_keychain} -w"
                )
        password = password or getpass.getpass(f"Пароль MySQL ({args.user}): ")

        servers_path = Path(args.servers) if args.servers else (
            Path(__file__).resolve().parent.parent
            / "parallels-sql-admins" / "servers.json"
        )
        try:
            with open(servers_path, encoding="utf-8") as f:
                servers = json.load(f)
        except OSError:
            sys.exit(f"Не удалось прочитать {servers_path}")

    if args.probe:
        host = args.probe[0]
        db = args.probe[1] if len(args.probe) > 1 else None
        # При --from-app берём учётку сервера из реестра, иначе — общие значения
        spec = next((s for s in servers if s.get("host") == host), None)
        p_port = int(spec.get("port") or args.port) if spec else args.port
        p_user = (spec.get("user") or args.user) if spec else args.user
        p_pass = (spec.get("password") or password) if spec else password
        if not p_pass:
            sys.exit(f"Нет пароля для {host}")
        conn = make_conn(host, p_port, p_user, p_pass, args.timeout)
        try:
            if db:
                probe_db(conn, db)
            else:
                probe_host(conn)
        finally:
            conn.close()
        return

    hosts = {h.strip() for h in args.hosts.split(",") if h.strip()}

    all_domains: set[str] = set()
    by_server: dict[str, set[str]] = {}

    for spec in servers:
        host = spec.get("host")
        if not host:
            continue
        if host in EXCLUDED_SERVERS:
            print(f"{host}: пропущен (в EXCLUDED_SERVERS)")
            continue
        if hosts and host not in hosts:
            continue
        # При --from-app у каждого сервера своя учётка, иначе — общий пароль
        s_port = int(spec.get("port") or args.port)
        s_user = spec.get("user") or args.user
        s_pass = spec.get("password") or password
        if not s_pass:
            print(f"{host}: нет пароля, пропущен", file=sys.stderr)
            continue
        server_domains: set[str] = set()
        no_domain_dbs: list[str] = []
        try:
            conn = make_conn(host, s_port, s_user, s_pass, args.timeout)
        except Exception as ex:
            print(f"{host}: ошибка: {ex}", file=sys.stderr)
            continue
        try:
            cur = conn.cursor()
            try:
                server_domains |= scan_psa_domains(cur)
                dbs = list_databases(cur)
            except Exception as ex:
                print(f"{host}: ошибка: {ex}", file=sys.stderr)
                conn.close()
                continue
            for db in dbs:
                try:
                    found = scan_site_structure(cur, db)
                    if not found:
                        found = scan_cfg_settings(cur, db)
                except Exception as ex:
                    print(f"  {db}: ошибка: {ex}", file=sys.stderr)
                    cur.close()
                    conn.close()
                    try:
                        conn = make_conn(host, s_port, s_user, s_pass,
                                         args.timeout)
                        cur = conn.cursor()
                    except Exception as rex:
                        print(f"{host}: ошибка переподключения: {rex}",
                              file=sys.stderr)
                        break
                    continue
                if found:
                    server_domains |= found
                    print(f"  {db}: {', '.join(sorted(found))}")
                else:
                    no_domain_dbs.append(db)
        finally:
            conn.close()
        if no_domain_dbs:
            print(f"  без домена: {', '.join(no_domain_dbs)}")
        print(f"{host}: {len(server_domains)} домен(ов)")
        by_server[host] = server_domains
        all_domains |= server_domains

    ordered = clean_list(all_domains)
    print()
    print(f"Итого уникальных доменов (после фильтрации): {len(ordered)}")

    if args.out:
        Path(args.out).write_text("\n".join(ordered) + ("\n" if ordered else ""),
                                  encoding="utf-8")
        print(f"Список сохранён: {args.out}")

    for d in ordered:
        print("  ", d)


if __name__ == "__main__":
    main()
