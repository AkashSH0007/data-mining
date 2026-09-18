CREATE OR REPLACE TEMP VIEW sales AS
SELECT * FROM read_parquet('/work/object_store/annapurna/sales/**/*.parquet', hive_partitioning=true);
COPY (
  SELECT count(*) AS row_count,
    md5(string_agg(concat_ws('|', bill_no, line_no::VARCHAR, product_code, qty::VARCHAR,
      unit_price::VARCHAR, line_type), '|' ORDER BY bill_no, line_no)) AS row_checksum,
    count(DISTINCT bill_no) AS bill_count,
    count(DISTINCT source_file) AS source_file_count
  FROM sales
) TO '/work/evidence/load_metrics.csv' (HEADER, DELIMITER ',');