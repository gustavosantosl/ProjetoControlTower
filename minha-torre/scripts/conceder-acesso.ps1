param(
    [Parameter(Mandatory = $true)]
    [string]$Profile,
    [Parameter(Mandatory = $true)]
    [string]$Warehouse
)

$ErrorActionPreference = 'Stop'
$appInfo = databricks apps get minha-torre --profile $Profile -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Falha ao obter o app minha-torre' }
$clientId = [string]$appInfo.service_principal_client_id
if ($clientId -notmatch '^[a-zA-Z0-9-]+$') { throw 'service_principal_client_id inválido' }

$sqlFile = New-TemporaryFile
try {
    $sql = @"
GRANT USE CATALOG ON CATALOG lakehouse_vertice TO ``$clientId``;
GRANT USE SCHEMA, SELECT ON SCHEMA lakehouse_vertice.gold TO ``$clientId``;
GRANT USE SCHEMA, SELECT ON SCHEMA lakehouse_vertice.silver TO ``$clientId``;
"@
    [System.IO.File]::WriteAllText($sqlFile.FullName, $sql, [System.Text.UTF8Encoding]::new($false))

    $runner = Join-Path $PSScriptRoot '..\..\scripts\run_sql.py'
    python $runner $sqlFile.FullName --profile $Profile --warehouse $Warehouse --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao conceder acesso ao Unity Catalog' }
} finally {
    Remove-Item -LiteralPath $sqlFile.FullName -ErrorAction SilentlyContinue
}
