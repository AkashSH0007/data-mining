# Annapurna sales platform

Run from PowerShell:

```powershell
Set-Location C:\data_2\data\solution
.\run_pipeline.ps1
```

The stack is local Docker Compose:

- PostgreSQL loads `../masters.sql` and owns stores, products, categories, and price revisions.
- MinIO is the object-store service and persists the isolated local `minio_data` volume. The landed Parquet tree is uploaded to the `annapurna` bucket under `sales/`.
- DuckDB is the analytical query engine. The normalized sales data is written as Parquet under `object_store/annapurna/sales/store_id=Sxx/business_month=YYYY-MM/`.

The filename is the business date. The loader normalizes all three CSV dialects, retains `SALE`, `RETURN`, `DISCOUNT`, and `VOID`, excludes `TAX` and `TENDER` from revenue, and keeps one row per `(bill_no, line_no)`. It does not choose the newest resend, because the vendor says resends can be partial.

## Evidence

- `evidence/idempotency_runs.csv`: three row-count/checksum runs.
- `evidence/pipeline_monthly.csv`: monthly revenue from the landed data.
- `evidence/march_prices.csv`: temporal price query for March 2024.
- `evidence/october_slice.csv`: store/category/day-of-week/month slice for October.
- `evidence/temporal_price_demo.csv`: the same price-by-period query run for March and November 2024.
- `evidence/dashboard_table_sizes.csv`: built dimension and fact table row counts.
- `evidence/reconciliation.csv`: finance comparison, causes, and recommendations.
- `evidence/federated_explain.txt`: DuckDB execution plan for a query joining Parquet sales with PostgreSQL master data.
- `evidence/layout_scan.csv`: exact S03 October partition file/byte comparison with the flat source folder.
- `evidence/temporal_march_run.txt` and `evidence/temporal_november_run.txt`: the identical temporal query run with only period variables changed.

The dashboard model is a star schema: `dim_store`, `dim_category`, `dim_product`, and `dim_date` hold descriptive attributes once; `fact_sales` holds keys and measures at sales-line grain. The fact table never repeats a store address or product/category name.

The federated plan shows `READ_PARQUET` for sales and `POSTGRES_SCAN` for stores, products, and categories, with DuckDB performing the hash joins and aggregation. October scans 12 Parquet files after the `business_month` file filter, rather than all 144 store-month partitions.

Reconciliation matches finance for nine months. March differs by INR 486,250 because finance includes an institutional order outside the tills; July differs by INR 232,131.70 because S07 has three missing export days; December differs by INR 50.48 because finance rounds each bill to whole rupees. These are source/definition differences, not pipeline bugs. Use the signed-off finance number for the finance report and disclose the reason.

The partition layout means an S03 October query targets one Parquet file of 181,859 bytes. A flat folder would expose all 4,457 source files totaling 68,706,877 bytes. The same 144 partition objects are uploaded to MinIO, and the target object is `sales/store_id=S03/business_month=2024-10/data_0.parquet`.

## Query Results

These are the outputs produced by the SQL files and stored evidence files.

### A. Partition scan

```text
query: store_id=S03, business_month=2024-10
partitioned layout: 1 file, 181859 bytes
flat source folder: 4457 files, 68706877 bytes
MinIO: annapurna bucket, 144 Parquet objects
```

### B. Idempotency

```text
run  row_count  row_checksum                         bill_count  source_files
1    1120924    b0ce3c3b96cc3ead45d580224d0b938f     165704      4389
2    1120924    b0ce3c3b96cc3ead45d580224d0b938f     165704      4389
3    1120924    b0ce3c3b96cc3ead45d580224d0b938f     165704      4389
```

### C. Dashboard tables

```text
dim_store       12 rows
dim_category    14 rows
dim_product     1224 rows
dim_date        366 rows
fact_sales      766796 rows
```

The October revenue result is `56359195.92 INR`, matching the signed-off finance total. The dashboard output can be sliced by store, category, weekday, and month in `evidence/october_slice.csv`.

### D. Historical prices

The same `temporal_price_query.sql` was run twice; only `period_start` and `period_end` changed:

```text
March 2024:   24 Mantra Basmati Rice 5kg -> 41261.30 INR
November 2024: 24 Mantra Basmati Rice 5kg -> 70763.24 INR
```

This uses both `products.valid_from/valid_to` and `price_revisions.effective_from/effective_to`, so the product identity and price are historical rather than current.

### E. Federated query plan

The DuckDB physical plan reports:

```text
READ_PARQUET       sales data, with business_month='2024-10' file filter
POSTGRES_SCAN      stores
POSTGRES_SCAN      products
POSTGRES_SCAN      product_categories
HASH_JOIN          DuckDB joins and validity predicates
HASH_GROUP_BY      DuckDB performs the final aggregation
Scanning Files: 12/12
```

This proves the sales scan was evaluated from Parquet, master-data scans from PostgreSQL, and joins/aggregation in DuckDB.

### F. Reconciliation

```text
month   finance INR   pipeline INR   difference INR   cause
2024-03 42457899.09    41971649.09     486250.00       institutional order outside tills
2024-07 40527291.81    40295160.11     232131.70       missing S07 exports on Jul 9-11
2024-12 50745209.00    50745259.48        -50.48       finance rounds each bill
```

The other nine months match exactly. These differences are source or accounting-definition differences, not pipeline bugs. Finance's signed-off totals should be used for the finance report, with these explanations recorded.