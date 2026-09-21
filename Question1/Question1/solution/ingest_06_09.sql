CREATE OR REPLACE TEMP TABLE dedup_lines AS
WITH source_lines AS (
  SELECT regexp_extract(filename, 'SALES_(S[0-9]{2})_([0-9]{8})', 1) AS store_id,
    strptime(regexp_extract(filename, 'SALES_(S[0-9]{2})_([0-9]{8})', 2), '%Y%m%d')::DATE AS business_date,
    bill_no::VARCHAR AS bill_no, line_no::INTEGER AS line_no, item_code::VARCHAR AS product_code,
    quantity::DECIMAL(18,3) AS qty, rate::DECIMAL(18,2) AS unit_price, type::VARCHAR AS line_type,
    try_strptime(txn_time::VARCHAR, '%d-%m-%Y %H:%M:%S') AS event_ts, filename::VARCHAR AS source_file
  FROM read_csv('/input/sales/SALES_S0[6-9]_*.csv', delim=';', header=true, filename=true, union_by_name=true)
)
SELECT * FROM source_lines
QUALIFY row_number() OVER (PARTITION BY bill_no, line_no ORDER BY source_file) = 1;
COPY (SELECT *, strftime(business_date, '%Y-%m') AS business_month FROM dedup_lines)
TO '/work/object_store/annapurna/sales' (FORMAT PARQUET, PARTITION_BY (store_id, business_month), OVERWRITE_OR_IGNORE TRUE);