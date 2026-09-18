$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

New-Item -ItemType Directory -Force object_store, evidence | Out-Null
New-Item -ItemType Directory -Force mc-config | Out-Null
docker compose up -d postgres minio | Out-Host
Remove-Item evidence\idempotency_runs.csv -Force -ErrorAction SilentlyContinue

for ($run = 1; $run -le 3; $run++) {
    Remove-Item object_store\annapurna -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force object_store\annapurna\sales | Out-Null
    Remove-Item evidence\load_metrics.csv -Force -ErrorAction SilentlyContinue
    foreach ($sql in @('ingest_01_05.sql', 'ingest_06_09.sql', 'ingest_10_12.sql')) {
        docker run --rm --network solution_default `
          -v "${PWD}\..:/input:ro" `
          -v "${PWD}:/work" `
          duckdb/duckdb:latest /duckdb /work/annapurna.duckdb -f "/work/$sql" | Out-Host
    }
    docker run --rm --network solution_default `
      -v "${PWD}:/work" `
      duckdb/duckdb:latest /duckdb /work/annapurna.duckdb -f /work/metrics.sql | Out-Host
    $metrics = Import-Csv evidence\load_metrics.csv
    [pscustomobject]@{ run = $run; row_count = $metrics.row_count; row_checksum = $metrics.row_checksum; bill_count = $metrics.bill_count; source_file_count = $metrics.source_file_count } |
      Export-Csv evidence\idempotency_runs.csv -NoTypeInformation -Append
}

docker run --rm --network solution_default `
  -v "${PWD}:/work" `
  duckdb/duckdb:latest /duckdb /work/annapurna.duckdb -f /work/report_queries.sql 2>&1 |
  ForEach-Object { $_.ToString() } | Set-Content evidence\federated_explain.txt -Encoding utf8

docker run --rm --network solution_default `
  -v "${PWD}\..:/input:ro" -v "${PWD}:/work" `
  duckdb/duckdb:latest /duckdb /work/annapurna.duckdb -f /work/dashboard_schema.sql | Out-Host
docker run --rm --network solution_default `
  -v "${PWD}:/work" `
  duckdb/duckdb:latest /duckdb /work/annapurna.duckdb -f /work/temporal_price_demo.sql | Out-Host
docker run --rm --network solution_default `
  -v "${PWD}\..:/input:ro" -v "${PWD}:/work" `
  duckdb/duckdb:latest /duckdb /work/annapurna.duckdb -f /work/reconcile.sql | Out-Host

docker run --rm --network solution_default `
  -v "${PWD}\mc-config:/root/.mc" `
  quay.io/minio/mc:latest alias set local http://minio:9000 minioadmin minioadmin
docker run --rm --network solution_default `
  -v "${PWD}\mc-config:/root/.mc" `
  quay.io/minio/mc:latest mb --ignore-existing local/annapurna
docker run --rm --network solution_default `
  -v "${PWD}\mc-config:/root/.mc" -v "${PWD}\object_store\annapurna:/source:ro" `
  quay.io/minio/mc:latest cp --recursive /source/sales local/annapurna

powershell -ExecutionPolicy Bypass -File .\layout_scan.ps1 | Out-Host

Write-Host 'Pipeline complete. Evidence is in .\evidence and partitioned data is in .\object_store.'