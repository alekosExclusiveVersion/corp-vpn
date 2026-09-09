#!/usr/bin/env python3
"""Автоочистка БД aisql по стадиям заявок Б24.

Критерий удаления: имя БД вида имя_клиента_<id> и сделка в Б24 с этим ID
находится в завершённом статусе (STAGE_SEMANTIC_ID='S' и CLOSED='Y').

Режимы: --dry-run (по умолчанию) показывает кандидатов, --commit удаляет.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

PSA_ROOT = Path(os.environ.get("PSA_REPO", "/Users/aleksei/Work/scripts/parallels-sql-admins"))
B24_ROOT = Path(os.environ.get("B24_REPO", "/Users/aleksei/Work/ts-b24"))
PSA_APP = Path(
    os.environ.get(
        "PSA_APP",
        "/Users/aleksei/Library/Application Support/Parallels SQL Admin",
    )
)
AISQL_HOST = os.environ.get(
    "AISQL_HOST", r"aisql.tradesoft.corp\supportsql"
)
SYSTEM_DBS = frozenset(
    ("master", "tempdb", "model", "msdb",
     "information_schema", "performance_schema", "mysql", "sys")
)
RE_DB = re.compile(r"^[A-Za-z0-9_]+_(\d+)$")
ROTATE_LINES = 500
BANNER_MAX_NAMES = 6


def log_line(path: Path, msg: str) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}\n")
        if path.exists():
            lines = path.read_text(encoding="utf-8").splitlines()
            if len(lines) > ROTATE_LINES:
                path.write_text("\n".join(lines[-ROTATE_LINES // 2:]) + "\n",
                                encoding="utf-8")
    except OSError as ex:
        print(f"log error: {ex}", file=sys.stderr)


def signal(signals: Path, event: str, msg: str) -> None:
    try:
        signals.parent.mkdir(parents=True, exist_ok=True)
        with signals.open("a", encoding="utf-8") as f:
            f.write(f"{datetime.now():%Y-%m-%d %H:%M:%S}|{event}|{msg}\n")
    except OSError as ex:
        print(f"signal error: {ex}", file=sys.stderr)


def banner_list(names: list[str]) -> str:
    if len(names) <= BANNER_MAX_NAMES:
        return ", ".join(names)
    head = names[:BANNER_MAX_NAMES]
    return ", ".join(head) + f", и ещё {len(names) - BANNER_MAX_NAMES}"


def one_line(value) -> str:
    return " ".join(str(value).split())


def load_psa() -> None:
    sys.path.insert(0, str(PSA_ROOT))
    import common.config as C

    cfg = C.load_config(PSA_APP / "config.ini")
    object.__setattr__(cfg.advanced, "servers_file", str(PSA_APP / "servers.json"))
    log_root = Path(os.environ.get("DB_CLEAN_LOG", "/var/log/corp-db-clean.log")).parent
    object.__setattr__(cfg.logging, "directory", log_root / "corp-db-clean")
    C.config = cfg

    from common.server_registry import registry

    registry.ensure_key()


def get_mssql():
    from common.mssql_client import mssql

    return mssql


def list_databases(client, host: str) -> list[str]:
    rows = client.query(host, "SELECT name FROM sys.databases")
    return sorted(r.get("name") for r in rows if r.get("name"))


def parse_candidate(name: str) -> int | None:
    m = RE_DB.fullmatch(name)
    if not m:
        return None
    return int(m.group(1))


def fetch_deals(ids: list[int]):
    sys.path.insert(0, str(B24_ROOT / "scripts"))
    from b24_client import B24Client

    client = B24Client()
    deals: dict[int, dict] = {}
    if ids:
        try:
            rows = client.get_all(
                "crm.deal.list",
                {"filter": {"@ID": ids},
                 "select": ["ID", "TITLE", "STAGE_ID", "CATEGORY_ID",
                            "STAGE_SEMANTIC_ID", "CLOSED"]},
            )
            deals = {int(r.get("ID")): r for r in rows if r.get("ID") is not None}
        except Exception as ex:
            print(f"warning crm.deal.list(@ID): {ex}", file=sys.stderr)
    for deal_id in ids:
        if deal_id in deals:
            continue
        try:
            res = client.call_gentle("crm.deal.get", {"id": deal_id}).get("result")
        except Exception as ex:
            res = None
            print(f"warning crm.deal.get({deal_id}): {ex}", file=sys.stderr)
        if isinstance(res, dict) and res.get("ID"):
            deals[int(res["ID"])] = res
    return deals


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Автоочистка БД aisql по стадиям заявок Б24")
    ap.add_argument("--commit", action="store_true",
                    help="реально удалять БД (по умолчанию dry-run)")
    ap.add_argument("--dry-run", action="store_true", help="только показать")
    ap.add_argument("--host", default=AISQL_HOST, help="хост aisql")
    ap.add_argument("--limit", type=int, default=0,
                    help="максимум БД к обработке (0 = все)")
    ap.add_argument("--log", default=os.environ.get(
        "DB_CLEAN_LOG", "/var/log/corp-db-clean.log"))
    ap.add_argument("--signals", default=os.environ.get(
        "DB_CLEAN_SIGNALS", "/var/run/corp-vpn-signals"))
    args = ap.parse_args()

    commit = args.commit or os.environ.get("DB_CLEAN_COMMIT") == "1"
    if args.dry_run:
        commit = False

    log = Path(args.log)
    signals = Path(args.signals)

    load_psa()
    mssql = get_mssql()

    log_line(log, "=== START commit=%d host=%s ===" % (int(commit), args.host))

    try:
        databases = list_databases(mssql, args.host)
    except Exception as ex:
        msg = one_line(ex)
        signal(signals, "db-clean.fail", f"aisql недоступен: {msg}")
        log_line(log, f"FAIL aisql недоступен: {msg}")
        return 2

    candidates: dict[str, int] = {}
    for name in databases:
        if name in SYSTEM_DBS:
            continue
        deal_id = parse_candidate(name)
        if deal_id is not None:
            candidates[name] = deal_id

    ids = sorted(candidates.values())
    deals = fetch_deals(ids) if ids else {}

    to_drop: list[tuple[str, int]] = []
    skipped: list[tuple[str, int, str]] = []
    for name in sorted(candidates):
        deal_id = candidates[name]
        deal = deals.get(deal_id)
        if deal is None:
            skipped.append((name, deal_id, "нет сделки в Б24"))
            log_line(log, f"SKIPPED {name} deal={deal_id} нет сделки в Б24")
            continue
        sem = deal.get("STAGE_SEMANTIC_ID")
        closed = deal.get("CLOSED")
        if sem == "S" and closed == "Y":
            to_drop.append((name, deal_id))
            log_line(log, f"CANDIDATE {name} deal={deal_id} stage={sem} closed={closed}")
        else:
            skipped.append((name, deal_id, f"stage={sem} closed={closed}"))
            log_line(
                log,
                f"SKIPPED {name} deal={deal_id} stage={sem} closed={closed}",
            )

    if args.limit > 0:
        to_drop = to_drop[:args.limit]

    names = [n for n, _ in to_drop]
    summary = (
        f"SUMMARY candidates={len(candidates)} to_drop={len(to_drop)} "
        f"skipped={len(skipped)} dry_run={int(not commit)}"
    )
    log_line(log, summary)

    if not commit:
        if to_drop:
            signal(signals, "db-clean.dryrun",
                   f"к удалению {len(to_drop)} БД: {banner_list(names)}")
        else:
            signal(signals, "db-clean.dryrun", "к удалению 0 БД")
        print(summary)
        for n, d in to_drop:
            print(f"  would-drop {n} (deal {d})")
        return 0

    removed = 0
    errors = 0
    failed_names: list[str] = []
    for name, deal_id in to_drop:
        try:
            mssql.drop_database(args.host, name)
            removed += 1
            time.sleep(2)
            log_line(log, f"REMOVED {name} deal={deal_id}")
        except Exception as ex:
            errors += 1
            failed_names.append(name)
            log_line(log, f"ERROR {name} deal={deal_id}: {one_line(ex)}")

    log_line(log, f"SUMMARY removed={removed} errors={errors}")

    if errors:
        signal(signals, "db-clean.fail",
               f"удалено {removed}, ошибок {errors}: {banner_list(failed_names)}")
    elif removed:
        signal(signals, "db-clean.ok",
               f"удалено {removed} БД: {banner_list(names)}")
    else:
        signal(signals, "db-clean.ok", "удалено 0 БД")

    try:
        mssql.close_all()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())