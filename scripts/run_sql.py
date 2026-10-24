#!/usr/bin/env python3
"""Execute SQL statements sequentially through the Databricks Statements API."""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def statements(sql: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    quote = False
    dollar = False
    i = 0
    while i < len(sql):
        if not quote and sql.startswith("$$", i):
            dollar = not dollar
            current.append("$$")
            i += 2
            continue
        if not quote and not dollar and sql.startswith("--", i):
            end = sql.find("\n", i)
            end = len(sql) if end < 0 else end
            current.append(sql[i:end])
            i = end
            continue
        ch = sql[i]
        if ch == "'" and not dollar:
            quote = not quote
        if ch == ";" and not quote and not dollar:
            parts.append("".join(current))
            current = []
        else:
            current.append(ch)
        i += 1
    parts.append("".join(current))
    return [
        part.strip()
        for part in parts
        if any(line.strip() and not line.lstrip().startswith("--") for line in part.splitlines())
    ]


def cli(args: list[str], profile: str):
    result = subprocess.run(
        ["databricks", *args, "--profile", profile, "-o", "json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return json.loads(result.stdout or "{}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("arquivo", type=Path)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--warehouse")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--continuar", action="store_true")
    args = parser.parse_args()

    warehouse = args.warehouse
    if not warehouse:
        listing = cli(["warehouses", "list"], args.profile)
        warehouses = listing if isinstance(listing, list) else listing.get("warehouses", [])
        if not warehouses:
            raise RuntimeError("nenhum SQL warehouse encontrado")
        warehouse = warehouses[0]["id"]

    sql = args.arquivo.read_text(encoding="utf-8")
    queries = statements(sql)
    print(f"{args.arquivo}: {len(queries)} statement(s) · warehouse {warehouse}")
    failures = 0
    for number, query in enumerate(queries, 1):
        title = next((line.strip() for line in query.splitlines() if line.strip() and not line.lstrip().startswith("--")), "")
        print(f"[{number}/{len(queries)}] {title[:70]}")
        try:
            payload = json.dumps({
                "warehouse_id": warehouse,
                "statement": query,
                "wait_timeout": "50s",
                "on_wait_timeout": "CONTINUE",
            })
            response = cli(["api", "post", "/api/2.0/sql/statements", "--json", payload], args.profile)
            while response["status"]["state"] in ("PENDING", "RUNNING"):
                time.sleep(3)
                response = cli(["api", "get", f"/api/2.0/sql/statements/{response['statement_id']}"], args.profile)
            if response["status"]["state"] != "SUCCEEDED":
                raise RuntimeError(response["status"].get("error", {}).get("message", str(response["status"])))
            if not args.quiet:
                columns = [col["name"] for col in response.get("manifest", {}).get("schema", {}).get("columns", [])]
                rows = response.get("result", {}).get("data_array") or []
                if columns and rows:
                    print("  " + " | ".join(columns))
                    for row in rows[:30]:
                        print("  " + " | ".join("" if value is None else str(value) for value in row))
            print("  ok")
        except RuntimeError as exc:
            failures += 1
            print(f"  FALHOU: {exc}", file=sys.stderr)
            if not args.continuar:
                return 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
