INSTALL postgres;
LOAD postgres;

CREATE OR REPLACE TEMP VIEW source_lines AS
SELECT
    regexp_extract(filename, 'SALES_(S[0-9]{2})_([0-9]{8})', 1) AS store_id,
    strptime(regexp_extract(filename, 'SALES_(S[0-9]{2})_([0-9]{8})', 2), '%Y%m%d')::DATE AS business_date,
    bill_no::VARCHAR AS bill_no,
    line_no::INTEGER AS line_no,
    product_code::VARCHAR AS product_code,
    qty::DECIMAL(18,3) AS qty,
    unit_price::DECIMAL(18,2) AS unit_price,
    line_type::VARCHAR AS line_type,
    try_cast(ts AS TIMESTAMP) AS event_ts,
    filename::VARCHAR AS source_file
FROM read_csv('/input/sales/SALES_S0[1-5]_*.csv', header=true, filename=true, union_by_name=true)
UNION ALL
SELECT
    regexp_extract(filename, 'SALES_(S[0-9]{2})_([0-9]{8})', 1),
    strptime(regexp_extract(filename, 'SALES_(S[0-9]{2})_([0-9]{8})', 2), '%Y%m%d')::DATE,
    bill_no::VARCHAR,
    line_no::INTEGER,
    item_code::VARCHAR,
    quantity::DECIMAL(18,3),
    rate::DECIMAL(18,2),
    type::VARCHAR,
    try_strptime(txn_time::VARCHAR, '%d-%m-%Y %H:%M:%S'),
    filename::VARCHAR
FROM read_csv('/input/sales/SALES_S0[6-9]_*.csv', delim=';', header=true, filename=true, union_by_name=true)
UNION ALL
SELECT
    regexp_extract(filename, 'SALES_(S[0-9]{2})_([0-9]{8})', 1),
    strptime(regexp_extract(filename, 'SALES_(S[0-9]{2})_([0-9]{8})', 2), '%Y%m%d')::DATE,
    bill_no::VARCHAR,
    line_no::INTEGER,
    product_code::VARCHAR,
    qty::DECIMAL(18,3),
    unit_price::DECIMAL(18,2),
    line_type::VARCHAR,
    to_timestamp(ts::BIGINT)::TIMESTAMP,
    filename::VARCHAR
FROM read_csv('/input/sales/SALES_S1[0-2]_*.csv', header=true, filename=true, union_by_name=true);

CREATE OR REPLACE TEMP TABLE dedup_lines AS
SELECT store_id, business_date, bill_no, line_no, product_code, qty, unit_price,
       line_type, event_ts, source_file
FROM source_lines
QUALIFY row_number() OVER (
    PARTITION BY bill_no, line_no
    ORDER BY source_file
) = 1;

COPY (
    SELECT *, strftime(business_date, '%Y-%m') AS business_month
    FROM dedup_lines
) TO '/work/object_store/annapurna/sales'
(FORMAT PARQUET, PARTITION_BY (store_id, business_month), OVERWRITE_OR_IGNORE TRUE);

COPY (
    SELECT
      count(*) AS row_count,
      md5(string_agg(
        concat_ws('|', bill_no, line_no::VARCHAR, product_code, qty::VARCHAR,
                  unit_price::VARCHAR, line_type), '|'
        ORDER BY bill_no, line_no
      )) AS row_checksum,
      count(DISTINCT bill_no) AS bill_count,
      count(DISTINCT source_file) AS source_file_count
    FROM dedup_lines
) TO '/work/evidence/load_metrics.csv' (HEADER, DELIMITER ',');