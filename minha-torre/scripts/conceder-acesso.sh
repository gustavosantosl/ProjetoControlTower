#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Uso: $0 <perfil-databricks> <sql-warehouse-id>" >&2
  exit 2
fi

profile="$1"
warehouse="$2"
app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
client_id="$(databricks apps get minha-torre --profile "$profile" -o json |
  python -c 'import json,sys; print(json.load(sys.stdin)["service_principal_client_id"])')"

if [[ ! "$client_id" =~ ^[a-zA-Z0-9-]+$ ]]; then
  echo "service_principal_client_id inválido" >&2
  exit 1
fi

sql_file="$(mktemp)"
trap 'rm -f "$sql_file"' EXIT
cat > "$sql_file" <<SQL
GRANT USE CATALOG ON CATALOG lakehouse_vertice TO \`$client_id\`;
GRANT USE SCHEMA, SELECT ON SCHEMA lakehouse_vertice.gold TO \`$client_id\`;
GRANT USE SCHEMA, SELECT ON SCHEMA lakehouse_vertice.silver TO \`$client_id\`;
SQL

python "$app_dir/../scripts/run_sql.py" "$sql_file" \
  --profile "$profile" --warehouse "$warehouse" --quiet
