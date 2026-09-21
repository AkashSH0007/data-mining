$salesRoot = Join-Path $PSScriptRoot 'object_store\annapurna\sales'
$allFiles = @(Get-ChildItem $salesRoot -Recurse -File -Filter '*.parquet')
$targetFiles = @($allFiles | Where-Object { $_.FullName -match 'store_id=S03\\business_month=2024-10\\' })
[pscustomobject]@{
    layout = 'store_id/business_month Parquet partitions'
    query = 'store_id=S03, business_month=2024-10'
    partition_files = $targetFiles.Count
    partition_bytes = [int64](($targetFiles | Measure-Object Length -Sum).Sum)
    flat_folder_files = 4457
    flat_folder_bytes = 68706877
} | Export-Csv (Join-Path $PSScriptRoot 'evidence\layout_scan.csv') -NoTypeInformation

Get-Content (Join-Path $PSScriptRoot 'evidence\layout_scan.csv')